# Carpeta `data/` — los datos de entrada

Aquí están los datos con los que trabaja todo el proyecto. Son **100 % ficticios**:
se generaron para una prueba técnica de ingeniería de datos y no pertenecen a
ninguna persona ni empresa real.

Todo está dentro de la subcarpeta `Paquete_datos_prueba_tecnica/`.

## El negocio en un párrafo

Una financiera ficticia (**Instacredit**) tiene **sucursales** donde atiende a
**clientes**. A cada cliente le da uno o más **créditos**. Cada crédito se paga en
**cuotas** mensuales. Cuando el cliente paga, queda registrado un **pago**.
Además, un proveedor externo envía por una API más pagos hechos en bancos.

```text
sucursales (10) ──┐
                  ├──► creditos (480) ──► cuotas (13,485)
clientes (300) ───┘          │
                             └──────────► pagos (7,518) + pagos_incremental (53)

api_pagos_externos.json  (122 pagos de un proveedor externo, con datos "sucios")
```

## Los archivos

| Archivo | Filas | Qué contiene |
|---|---|---|
| `sucursales.csv` | 10 | Id, nombre y provincia de cada sucursal. |
| `clientes.csv` | 300 | Nombre, fecha de nacimiento, provincia, teléfono, fecha de alta, segmento e ingreso mensual. |
| `creditos.csv` | 480 | Cliente, sucursal, producto, monto prestado, tasa anual, plazo en meses, fecha de desembolso, cuota mensual y estado (`Vigente`, `Cancelado`, `Castigado`). |
| `cuotas.csv` | 13,485 | El plan de pagos: número de cuota, fecha de vencimiento, y cuánto de la cuota es capital y cuánto interés. |
| `pagos.csv` | 7,518 | Pagos registrados **hasta el 25-oct-2026** (carga inicial). |
| `pagos_incremental.csv` | 53 | Pagos registrados el **26 y 27-oct-2026** (carga incremental). |
| `api_pagos_externos.json` | 122 | Respuesta simulada de la API del proveedor "Conectividad Bancaria S.A.". |
| `01_crear_tablas_origen.sql` | — | Script original del paquete para crear las tablas de origen (ver nota abajo). |
| `LEAME.txt` | — | Descripción original del paquete que acompañaba la prueba. |

### Formato de los CSV

Separador coma, punto decimal, fechas `AAAA-MM-DD`, codificación UTF-8, con
encabezado en la primera fila.

Ejemplo (`creditos.csv`):

```csv
id_credito,id_cliente,id_sucursal,producto,monto_desembolsado,tasa_anual,plazo_meses,fecha_desembolso,cuota_mensual,estado
CR-00001,CL-00024,3,Microempresa,5230000,0.3236,24,2024-12-31,298814.95,Vigente
```

Se lee así: el crédito `CR-00001` es del cliente `CL-00024`, en la sucursal 3, por
5,230,000 a 24 meses con una tasa anual de 32.36 %, y se paga con cuotas de
298,814.95.

## Los "problemas" que traen los datos (a propósito)

Los datos incluyen errores reales de calidad para probar que el proceso los maneja.

### En `pagos.csv`
- **5 pagos duplicados**: hay 7,518 filas pero solo 7,513 `id_pago` distintos.
- **91 pagos sin cuota**: son abonos directos al crédito (`id_cuota` vacío).
- **Pagos parciales**: el monto es menor que la cuota.
- **Sobrepagos**: el monto es mayor que lo que se debía.
- `fecha_registro` puede ser **posterior** a `fecha_pago`.

### En `pagos_incremental.csv`
- Pagos **nuevos**.
- Pagos **tardíos**: fecha de pago anterior al corte, pero registrados después.
- **Correcciones**: mismo `id_pago` con monto distinto.
- **Duplicados**.

### En `api_pagos_externos.json`
De 122 registros, **113 son válidos y 9 se rechazan**. Los problemas son:
campos faltantes, fechas inválidas (por ejemplo `2026-13-01`), montos escritos
como texto con separador de miles (`"58,000.00"`), montos negativos o nulos,
créditos inexistentes, referencias repetidas y estados distintos de `APLICADO`.

Ejemplo de registro:

```json
{
  "referencia": "EXT-260001",
  "credito": "CR-00093",
  "fecha_pago": "2026-10-27",
  "monto": "58,000.00",
  "moneda": "CRC",
  "canal": "BancoA",
  "estado": "APLICADO",
  "detalle": { "comercio": "Ventanilla", "hora": "20:12" }
}
```

## Cómo se usan estos archivos

| Archivo | Quién lo lee |
|---|---|
| Los 6 CSV | `python/load_src.py` los carga en las tablas `src.*`. |
| `api_pagos_externos.json` | `python/extractor_pagos.py` lo limpia y lo deja en staging. |
| `01_crear_tablas_origen.sql` | **No lo usa el flujo automático.** |

> **Nota sobre `01_crear_tablas_origen.sql`.** Es el script que venía con el
> enunciado original. Crea una base llamada `PruebaDatos` y carga los CSV con
> `BULK INSERT` desde una ruta fija de Windows (`C:\Users\Admin\Downloads\...`),
> así que hay que editar la ruta. Esta solución usa su propia versión:
> `sql/00_cargar_origen.sql` (crea las tablas en `DatosPrueba`) más
> `python/load_src.py` (carga los datos).

## Dónde están configuradas estas rutas

Por defecto, `python/config.py` y `run_all.ps1` buscan los datos en
`Instacredit/Paquete_datos_prueba_tecnica`, no en `data/...`. Para usar esta
carpeta, define en `python/.env`:

```dotenv
DATA_DIR=data/Paquete_datos_prueba_tecnica
INPUT_JSON_PATH=data/Paquete_datos_prueba_tecnica/api_pagos_externos.json
```

## Cuidado

No modifiques estos archivos. Los resultados esperados del proyecto (7,513 pagos
únicos, 113 pagos válidos de la API, etc.) dependen de que estén **tal como vienen**.
