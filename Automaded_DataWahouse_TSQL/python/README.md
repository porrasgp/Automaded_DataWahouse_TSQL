# Carpeta `python/` — el "cartero" del proyecto

Aquí vive el código Python. Su trabajo es **mover y limpiar datos** antes de que
SQL Server haga el resto. Python no calcula la mora ni arma el Data Warehouse:
eso lo hacen los scripts de `sql/`.

## ¿Qué hace en una frase?

1. Lee los 6 archivos CSV y los copia a la base de **origen** (`load_src.py`).
2. Lee los pagos de la **API externa**, los limpia, y deja los buenos en una
   tabla temporal del Data Warehouse (`extractor_pagos.py`).

## Mapa de archivos

| Archivo | Para qué sirve | Analogía |
|---|---|---|
| `config.py` | Lee la configuración (servidor, usuario, rutas) desde `.env` o variables de entorno. | La hoja de ajustes del programa. |
| `db.py` | Abre la conexión a SQL Server y contiene las consultas (insertar, actualizar, bitácora, rechazos). | El teléfono para hablar con la base de datos. |
| `validators.py` | Limpia y revisa cada pago de la API: fechas, montos, créditos, canales, estados. | El inspector de calidad de la aduana. |
| `load_src.py` | Carga los CSV del paquete en las tablas `src.*`. | El montacargas que descarga el camión. |
| `extractor_pagos.py` | Orquesta todo: lee la API (por páginas), valida, guarda y escribe la bitácora. | El jefe de turno que coordina a todos. |
| `requirements.txt` | Lista de librerías que hay que instalar. | La lista de compras. |
| `tests/` | Pruebas automáticas del validador (ver `tests/README.md`). | El simulacro antes del día real. |
| `rechazos_api.json` | **Generado** en cada corrida: los registros que se rechazaron y por qué. | El cuaderno de "devueltos". |
| `extractor.log` | **Generado**: diario de lo que hizo el extractor. | La bitácora del jefe de turno. |

## Cómo se conectan las piezas

```text
                 config.py  (de dónde saco los datos y a qué base me conecto)
                     │
     ┌───────────────┴────────────────┐
     ▼                                ▼
 load_src.py                   extractor_pagos.py
 (CSV → src.*)                 (API → dw.stg_pagos_externos)
     │                           │            │
     │                           ▼            ▼
     │                     validators.py     db.py
     │                     (limpia/valida)   (habla con SQL Server)
     └──────────────► db.py ◄────┘
```

---

## Explicación sencilla de cada archivo

### `config.py` — la configuración

Define una clase `Config` con todos los ajustes. Cada ajuste se busca así:

1. En el archivo `python/.env` (si existe).
2. En las variables de entorno del sistema.
3. Si no está, usa un valor por defecto (por ejemplo, `ODBC Driver 18 for SQL Server`).

Solo **`DB_PASSWORD` es obligatoria**: si falta, el programa se detiene con un
mensaje claro. Las rutas relativas se calculan desde la raíz del proyecto, no
desde la carpeta donde ejecutes el comando; así funciona igual desde cualquier
lugar.

> **Ojo con las rutas por defecto.** `config.py` busca los datos en
> `Instacredit/Paquete_datos_prueba_tecnica`, pero en este repositorio están en
> `data/Paquete_datos_prueba_tecnica`. Define en tu `.env`:
>
> ```dotenv
> DATA_DIR=data/Paquete_datos_prueba_tecnica
> INPUT_JSON_PATH=data/Paquete_datos_prueba_tecnica/api_pagos_externos.json
> ```

### `db.py` — hablar con SQL Server

Funciones pequeñas, cada una con un solo trabajo:

| Función | Qué hace |
|---|---|
| `connect` | Abre la conexión con `pyodbc` (cifrada por defecto). |
| `start_bitacora` / `finish_bitacora` | Anota en `dw.bitacora_ejecucion` cuándo empezó y terminó una corrida y cuántas filas procesó. |
| `get_credit_ids` | Trae la lista de créditos válidos del DW, para comprobar que un pago apunta a un crédito real. |
| `upsert_pagos` | Inserta un pago nuevo, actualiza uno cambiado u omite uno idéntico. |
| `clear_rechazos` / `insert_rechazos` | Borra y vuelve a escribir los rechazos de la corrida. |

Dos ideas importantes:

- **Consultas parametrizadas** (los `?` del código). Los valores nunca se pegan
  dentro del texto SQL, lo que evita la inyección SQL.
- **`autocommit=False`**: los cambios se guardan juntos con `commit()`. Si algo
  falla, `rollback()` los deshace y no queda nada a medias.

### `validators.py` — el inspector de calidad

La API trae datos "sucios" a propósito. Este módulo los arregla cuando puede y
los rechaza cuando no, **sin detener el lote**.

| Campo | Lo que acepta / arregla | Lo que rechaza |
|---|---|---|
| `referencia` | Quita espacios y pasa a mayúsculas (` ext-260001 ` → `EXT-260001`). | Vacía o con formato raro. |
| `credito` | Igual, y exige el formato `CR-00000`. | Falta, formato malo, o no existe en el DW. |
| `fecha_pago` | `2026-10-27`, `27/10/2026`, `2026/10/27`, `27-10-2026` y fechas con hora. | Fechas imposibles como `2026-13-01`. |
| `monto` | `"58,000.00"`, `₡58000`, `$100`, `(500)`; redondea a 2 decimales. | Vacío, texto, **cero o negativo**. |
| `moneda` | `CRC` o `USD`. Si falta, **asume `CRC`** y deja una advertencia. | Cualquier otra moneda. |
| `canal` | Unifica nombres (`bancoa` → `BancoA`, `sinpe` → `Pago Móvil`). | Vacío o de más de 30 caracteres. |
| `estado` | Solo `APLICADO`. | Cualquier otro estado. |

**Deduplicación:** si la misma `referencia` aparece dos veces en el lote, se
queda la primera y la repetida se rechaza como `DUPLICADO_REFERENCIA`.

**Hash del registro:** cada pago válido genera una "huella" (SHA-256) con todos
sus datos. Si en la próxima corrida la huella es igual, el pago no cambió y se
omite. Así el extractor es **idempotente**: puedes correrlo 10 veces y el
resultado es el mismo.

### `load_src.py` — cargar los CSV

1. Borra el contenido de las tablas `src.*` (en orden: primero las que dependen de otras).
2. Lee cada CSV con `csv.DictReader`, convierte textos a fecha, número o `NULL`.
3. Inserta en bloque (`fast_executemany`, mucho más rápido que fila por fila).
4. Confirma todo con un solo `commit`; si algo falla, `rollback`.
5. Compara los conteos con lo esperado y muestra `OK` o `REVISAR`.

| Tabla | Filas esperadas |
|---|---|
| sucursales | 10 |
| clientes | 300 |
| creditos | 480 |
| cuotas | 13,485 |
| pagos | 7,518 |
| pagos_incremental | 53 |

Es **idempotente**: lo puedes ejecutar de nuevo y deja el mismo resultado.
Código de salida: `0` todo bien, `1` error, `2` conteos distintos a los esperados.

### `extractor_pagos.py` — el jefe de turno

Sigue este camino:

```text
1. Abrir conexión y anotar "EN_PROCESO" en la bitácora
2. Leer la fuente por páginas  (JSON local o HTTP, según config)
3. Pedir al DW la lista de créditos válidos
4. Validar y deduplicar cada registro   (validators.py)
5. Guardar válidos en dw.stg_pagos_externos  (insertar / actualizar / omitir)
6. Guardar rechazados en dw.rechazos y en rechazos_api.json
7. Cerrar la bitácora con EXITOSO (o FALLIDO si algo explotó)
```

La **fuente** está separada del resto con una "interfaz" (`PageSource`). Hay dos
implementaciones:

- `JsonFilePageSource`: lee el JSON del paquete y simula páginas de 50 registros.
- `HttpPageSource`: llama a una API real con `page` y `page_size`, y acepta token
  `Bearer`. **No se ha probado contra un proveedor real.**

Si defines `API_URL`, usa HTTP; si no, usa el archivo JSON. El resto del flujo no
cambia.

Si ocurre un error: hace `rollback`, marca la bitácora como `FALLIDO` con el
mensaje del error y termina con código `1`.

## Cómo ejecutarlo

```bash
cd python
python -m venv .venv
.venv\Scripts\activate          # Windows (PowerShell: .\.venv\Scripts\Activate.ps1)
pip install -r requirements.txt

python load_src.py              # 1) CSV → src.*
python extractor_pagos.py       # 2) API → staging
python extractor_pagos.py       #    (segunda vez: 0 insertados, 113 omitidos)
```

Normalmente no se ejecutan a mano: lo hace `run_all.ps1` en el orden correcto
(ver el `LEAME.md` principal).

## Resultado esperado del extractor

| Corrida | Leídos | Válidos | Insertados | Omitidos | Rechazados |
|---|---|---|---|---|---|
| 1.ª | 122 | 113 | 113 | 0 | 9 (7 inválidos + 2 duplicados) |
| 2.ª | 122 | 113 | 0 | 113 | 9 |

Los 9 rechazados (en `rechazos_api.json`) tienen motivos como: crédito faltante,
crédito inexistente, fecha inválida, monto faltante, monto cero o negativo,
estado distinto de `APLICADO` y referencia repetida.

## Seguridad

- No hay contraseñas en el código; todo viene de `.env` o del entorno.
- `.env` **no debe subirse a Git** (contiene credenciales).
- Las consultas usan parámetros, nunca texto pegado.
