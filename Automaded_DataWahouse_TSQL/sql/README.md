# Carpeta `sql/` — el "cerebro" del Data Warehouse

Los scripts T-SQL de esta carpeta construyen el Data Warehouse (DW), cargan los
datos y calculan la **cartera y la mora** de los créditos.

## Idea general en 1 minuto

Piensa en una financiera que presta dinero y cobra en cuotas. Queremos responder
preguntas como:

- ¿Cuánto dinero nos deben por sucursal y por producto?
- ¿Cuántos créditos están atrasados y cuánto llevan de atraso?
- ¿Cuánto recuperamos cada mes y por qué canal (app, banco, sucursal)?

Para eso se usan **dos bases de datos**:

| Base | Esquema | Qué contiene | Analogía |
|---|---|---|---|
| `DatosPrueba` | `src` | Los datos tal como llegan (CSV). | La bodega de recibo. |
| `dw.DatosPrueba` | `dw` | Los datos ordenados para analizar. | La tienda con todo etiquetado. |

## Orden de ejecución

El orden importa; cada script depende del anterior. `run_all.ps1` los corre solo.

| # | Script | Se ejecuta en | Qué hace (en simple) |
|---|---|---|---|
| 1 | `00_crear_base_datos.sql` | `master` | Crea las dos bases de datos con soporte para tildes (UTF-8). |
| 2 | `00_cargar_origen.sql` | `DatosPrueba` | Crea las 6 tablas vacías de origen (`src.*`). **No** carga datos; eso lo hace `python/load_src.py`. |
| 3 | `01_dw_ddl.sql` | `dw.DatosPrueba` | Construye el DW: tablas, índices, vistas y procedimientos. |
| 4 | `02_carga_inicial.sql` | `dw.DatosPrueba` | Primera carga completa, con corte al **2026-10-25**. |
| 5 | `03_carga_incremental.sql` | `dw.DatosPrueba` | Agrega el lote nuevo de pagos (26 y 27 de octubre). |
| 6 | `06_integrar_pagos_externos.sql` | `dw.DatosPrueba` | Pasa los pagos de la API (ya limpios por Python) al hecho `fact_pago`. |
| 7 | `04_consultas.sql` | `dw.DatosPrueba` | Consultas de negocio: cartera, mora, recuperación. |
| 8 | `05_validaciones.sql` | `dw.DatosPrueba` | Verificaciones automáticas; falla con error si algo no cuadra. |

Entre el paso 5 y el 6 se ejecuta `python/extractor_pagos.py` para llenar la tabla
de staging de la API.

> Los scripts `01`, `02`, `03` y `06` son **idempotentes**: puedes correrlos más
> de una vez sin duplicar datos.

---

## El modelo de datos (esquema estrella)

Un Data Warehouse separa los datos en dos tipos de tabla:

- **Dimensiones** (`dim_*`): *quién, qué, dónde, cuándo*. Son las "etiquetas".
- **Hechos** (`fact_*`): *qué pasó y cuánto*. Son los números que se suman.

```text
                       dim_fecha
                           │
 dim_cliente ─┐            │
 dim_sucursal ┼─► dim_credito ──► fact_cuota (una fila por cuota del plan)
 dim_producto ┘        │
                       ├────────► fact_pago ◄── dim_canal
                       │              │
                       │              ▼
                       │        fact_aplicacion (a qué cuota fue cada pago)
                       │
                       └────────► fact_cartera (foto del crédito en una fecha de corte)
```

### Dimensiones

| Tabla | Contenido |
|---|---|
| `dim_fecha` | Un renglón por día de 2015 a 2035 (año, mes, trimestre, día de semana, fin de semana). Su clave es el número `AAAAMMDD`, por ejemplo `20261025`. |
| `dim_sucursal` | Las 10 sucursales y su provincia. |
| `dim_cliente` | Los 300 clientes. |
| `dim_producto` | Tipos de crédito (Personal, Microempresa, etc.). |
| `dim_canal` | Por dónde se paga, agrupado: Físico, Digital, Bancario, Externo. |
| `dim_credito` | Los 480 créditos, enlazados a cliente, sucursal y producto. |

### Hechos

| Tabla | "Una fila es..." |
|---|---|
| `fact_cuota` | una cuota del plan de pagos de un crédito. |
| `fact_pago` | un pago único (`id_pago`). |
| `fact_aplicacion` | la parte de un pago que se usó para pagar una cuota concreta. Un pago puede cubrir varias cuotas. |
| `fact_cartera` | un crédito en una fecha de corte (saldo, monto vencido, días de mora, tramo). |

### Tablas de control

| Tabla | Para qué |
|---|---|
| `bitacora_ejecucion` | Diario: qué proceso corrió, cuándo, cuántas filas, si terminó bien. |
| `rechazos` | Registros que no se cargaron y **el motivo** (`DUPLICADO_EXACTO`, `CREDITO_INEXISTENTE`, ...). |
| `historial_correcciones` | Pagos corregidos: monto y fecha antes y después. |
| `stg_pagos_externos` | Zona de espera de los pagos de la API, ya limpios. |

### Vistas

- `vw_mora_tramo_sucursal`: mora agrupada por sucursal y tramo.
- `vw_bitacora_resumen`: la bitácora con la duración en segundos.

---

## Explicación de cada script

### `00_crear_base_datos.sql`
Crea `DatosPrueba` y `dw.DatosPrueba` solo si no existen. Si el servidor es SQL
Server 2019 o superior, usa la collation `Latin1_General_100_CI_AS_SC_UTF8` para no
perder tildes ni la "ñ". Avisa con una advertencia si una base ya existente usa otra
collation.

### `00_cargar_origen.sql`
Borra y recrea las tablas `src.sucursales`, `clientes`, `creditos`, `cuotas`,
`pagos` y `pagos_incremental`. Tiene un candado: si lo ejecutas por error en `master`
o `tempdb`, se detiene con un mensaje.

### `01_dw_ddl.sql`
Es el plano del edificio. Elimina y recrea todos los objetos del DW, y define:

- **Restricciones** (`CHECK`, `FOREIGN KEY`, `UNIQUE`) que impiden datos absurdos: montos negativos, un pago sin crédito, un `id_pago` repetido.
- **Índices** para que las consultas sean rápidas.
- **Los procedimientos almacenados** (la lógica central):

| Procedimiento | Qué hace |
|---|---|
| `usp_RecalcularAplicaciones` | Decide con qué cuota se paga cada pago. |
| `usp_GenerarCorte` | Toma la "foto" de la cartera y la mora en una fecha. |
| `usp_CargaIncrementalPagos` | Procesa el lote nuevo de pagos (lo crea el script `03`). |
| `usp_IntegrarPagosExternos` | Promueve los pagos de la API al hecho. |

### `02_carga_inicial.sql`
Todo dentro de **una transacción**: si algo falla, no queda nada a medias.

1. Anota el inicio en la bitácora.
2. Vacía y llena las dimensiones (incluye el calendario 2015–2035).
3. Carga `fact_cuota`.
4. Quita pagos duplicados (queda uno por `id_pago`) y manda los repetidos a `rechazos`.
5. Rechaza también pagos con crédito, cuota, canal, fecha o monto inválidos.
6. Llama a `usp_RecalcularAplicaciones` y `usp_GenerarCorte`.
7. Cierra la bitácora.

### `03_carga_incremental.sql`
Procesa el lote nuevo (`src.pagos_incremental`, 53 filas), clasificando cada pago:

| Caso | Qué se hace |
|---|---|
| Pago **nuevo** | Se inserta. |
| Pago **tardío** (fecha anterior al corte, registrado después) | Se inserta con su fecha real; las aplicaciones se reordenan. |
| **Corrección** (mismo `id_pago`, datos distintos) | Se actualiza y se guarda el antes/después en `historial_correcciones`. |
| **Duplicado** o ya cargado | Se omite y se cuenta. |
| **Inválido** | Se rechaza con su motivo. |

Después recalcula las aplicaciones y genera un nuevo corte. Al final muestra la
mora **antes y después** del lote.

### `06_integrar_pagos_externos.sql`
Llama a `usp_IntegrarPagosExternos`, que usa un `MERGE` para insertar en `fact_pago`
los pagos de `stg_pagos_externos` (origen `API`, tipo `DIRECTO`). Si un pago ya
existe sin cambios, no hace nada. Si cambió, lo actualiza y deja historial.
Muestra controles de conciliación al final.

### `04_consultas.sql`
Ocho consultas sobre el último corte disponible:

1. Saldo por sucursal y producto.
2. Mora por tramo y sucursal.
3. Mora total por tramo.
4. Recuperación por mes.
5. Recuperación por canal.
6. Pagos directos y pagos con sobrante.
7. Comparación del corte inicial contra el último.
8. Mora por tramo antes y después del incremental.

### `05_validaciones.sql`
Una lista de comprobaciones: cuántas filas hay en cada tabla, que no haya pagos
duplicados, que ninguna cuota esté pagada de más, que el dinero cuadre
(`pagos = aplicado + no aplicado`), que los acentos se vean bien, que las cargas
repetidas no dupliquen nada. Cada una marca `OK`, `FALLO` o `PENDIENTE`. Si una
crítica falla, lanza un error con `THROW`.

---

## Reglas de negocio clave

### ¿A qué cuota se aplica un pago? (`usp_RecalcularAplicaciones`)

Se procesan los pagos en orden de crédito → fecha → `id_pago`:

1. Si el pago indica una cuota y esa cuota aún debe algo, se paga primero esa.
2. Lo que sobra va a las cuotas pendientes **más antiguas** (regla **FIFO**: la primera en vencer es la primera en pagarse).
3. Si ya no quedan cuotas pendientes, el resto queda en `monto_no_aplicado`. No se inventan cuotas nuevas.

**Ejemplo:** cuota de 100, pago de 150 sin cuota indicada, y dos cuotas pendientes
de 100.

```text
Pago 150 ──► cuota más antigua: paga 100   (queda 50)
         └─► siguiente cuota:   paga  50   (a esa cuota le quedan 50 por pagar)
```

### ¿Cómo se calcula la mora? (`usp_GenerarCorte`)

- Solo cuentan los pagos con `fecha_pago <= fecha de corte`.
- Una cuota está **vencida** si su fecha de vencimiento es anterior al corte y todavía tiene saldo.
- `dias_mora_max` = días desde la cuota vencida más antigua con saldo hasta el corte.
- El **tramo** depende de ese mayor atraso:

| Días de mora | Tramo |
|---|---|
| 0 | `AL_DIA` |
| 1 a 30 | `1-30` |
| 31 a 60 | `31-60` |
| 61 a 90 | `61-90` |
| más de 90 | `>90` |

### Cifras de referencia

| Corte | Créditos en mora | Monto vencido |
|---|---|---|
| 2026-10-25 (carga inicial) | 60 | 22,310,553.92 |
| 2026-10-27 (tras incremental y API) | 55 | 16,990,957.95 |

## Limitaciones conocidas

- Los scripts `02`, `03` y `05` leen `[DatosPrueba].src.*` con un **nombre de tres partes** (consulta entre bases). **Azure SQL Database no lo permite**; el flujo requiere SQL Server local o una instancia con ambas bases.
- `usp_RecalcularAplicaciones` usa un cursor que **recalcula todo desde cero**. Es simple y correcto para este volumen (miles de pagos); con millones habría que hacerlo por lotes.
- El procedimiento incremental procesa todo `src.pagos_incremental`; no hay reproceso por día.
- Las dimensiones usan SCD tipo 1 (se sobrescribe el valor; no se guarda historial de cambios).
- Los valores esperados de `05_validaciones.sql` (7513, 113, 4, ...) están escritos fijos en el código, así que solo valen para este paquete de datos.
