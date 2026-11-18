# Carpeta `docs/` — documentación del diseño

Esta carpeta guarda los documentos que explican **por qué** se construyó la
solución de esta manera. El `LEAME.md` de la carpeta principal explica *cómo
ejecutarla*; los documentos de aquí explican *cómo está pensada*.

## Contenido actual

| Archivo | Qué es |
|---|---|
| `Documento_Diseno.pdf` | Documento de diseño del Data Warehouse de cartera (2 páginas). |

> El `LEAME.md` principal menciona otros documentos (`Manual_Ejecucion_Windows_AzureSQL.pdf`,
> `Evidencias_Ejecucion.txt` y `Checklist_Caso02.md`). **No están incluidos en este
> repositorio.** Para ejecutar la solución, la guía paso a paso está en el `LEAME.md`.

## Resumen de `Documento_Diseno.pdf`

El PDF tiene cinco secciones. Esta es la versión corta y sin tecnicismos.

### 1. Modelo dimensional y carga inicial
Se organiza la información en un **esquema estrella**: tablas de *hechos* (cuotas,
pagos, aplicaciones y cartera) rodeadas de tablas de *dimensiones* (fecha, cliente,
sucursal, producto, canal y crédito). Las dimensiones sobrescriben los valores
cambiados (**SCD tipo 1**) en lugar de guardar historial.

Decisiones sobre los datos de origen:

| Situación | Decisión |
|---|---|
| Pago duplicado | Se queda una fila por `id_pago`; las demás van a `rechazos`. Resultado: 7,518 filas, 7,513 únicas, 5 rechazadas. |
| Pago sin cuota (91) | Se carga como `DIRECTO` y se aplica a las cuotas pendientes más antiguas (FIFO). |
| Pago parcial | Deja saldo en la cuota; ese saldo cuenta para la mora. |
| Sobrepago | El excedente queda en `monto_no_aplicado`. No se crean cuotas. |

La **mora** se calcula al corte: cuotas vencidas antes de esa fecha y todavía
con saldo, clasificadas en tramos (`AL_DIA`, `1-30`, `31-60`, `61-90`, `>90`) según
el mayor atraso del crédito.

### 2. Proceso incremental
Un procedimiento almacenado aplica los 53 pagos nuevos dentro de **una sola
transacción**: nuevos, tardíos, correcciones, duplicados e inválidos, cada uno con
su tratamiento. Es **idempotente**: la segunda corrida no cambia nada.

| Corrida | Leídas | Insertadas | Actualizadas | Rechazadas | Omitidas |
|---|---|---|---|---|---|
| 1.ª | 53 | 46 | 4 | 0 | 3 |
| 2.ª | 53 | 0 | 0 | 0 | 53 |

Limitación reconocida: no hay reproceso por día; siempre se procesa todo el lote.

### 3. Extractor de la API
El extractor limpia 122 registros de la API y obtiene 113 válidos y 9 rechazados
(7 inválidos y 2 duplicados). Los válidos se pasan a `fact_pago` con un `MERGE`
(113 en la primera ejecución, 0 en la segunda), y el total de `fact_pago` sube de
7,559 a 7,672.

Se aclara que la lectura HTTP real **no se ha probado contra un proveedor
real**: hoy se lee el JSON del paquete simulando páginas.

### 4. Mora al corte: estado final

| Corte | Créditos en mora | Monto vencido |
|---|---|---|
| 2026-10-25 (carga inicial) | 60 | 22,310,553.92 |
| 2026-10-27 (tras incremental y API) | 55 | 16,990,957.95 |

### 5. Orquestación y monitoreo (propuesta, **no implementada**)
- Programar con **SQL Server Agent** (o Airflow / Control-M si existe).
- Detectar fallas por el estado `EXITOSO` / `FALLIDO` de la bitácora y por los `THROW` de las validaciones.
- Alertas sugeridas: procesos fallidos, rechazos sobre un umbral y caídas de filas frente al día anterior.
- Reprocesar volviendo a ejecutar el flujo (es idempotente).

## ¿Por dónde empezar?

1. Lee esta página para ubicarte.
2. Abre `Documento_Diseno.pdf` para ver el razonamiento completo.
3. Ve a `../sql/README.md` para ver el modelo y los scripts en detalle.
4. Ve a `../python/README.md` para ver cómo funciona el extractor.
