# Prueba Técnica Instacredit — Variante Windows / Azure SQL Database

Solución de Data Warehouse de cartera, carga incremental idempotente y
extractor Python para la API de pagos externos.

Esta solución está preparada para ejecutarse desde **Windows** contra
**SQL Server 2019** (instancia local). Usa dos bases: `DatosPrueba` (origen,
esquema `src`) y `dw.DatosPrueba` (Data Warehouse, esquema `dw`). La carga de
los CSV se hace con `python/load_src.py`, porque no se usa `OPENROWSET/BULK`.
**Azure SQL Database no es compatible** con la lectura entre bases que usa
`02`, `03` y `05` (ver sección 10).

## 0. El proyecto en palabras simples

**¿Qué problema resuelve?** Una financiera ficticia (Instacredit) presta dinero que
se paga en cuotas. Necesita saber cuánto le deben, qué créditos están atrasados
(mora) y cuánto recupera cada mes. Los datos llegan sucios y repartidos: archivos
CSV, un lote nuevo cada día y una API externa con errores.

**¿Cómo lo resuelve?** En tres movimientos, como una cadena de montaje:

```text
  CSV + API externa            LIMPIAR Y CARGAR               RESPONDER
 ┌───────────────┐        ┌────────────────────────┐     ┌─────────────────┐
 │ sucursales    │        │ Python: lee, valida y  │     │ Cartera por     │
 │ clientes      │ ─────► │ rechaza lo malo        │     │ sucursal        │
 │ créditos      │        │ SQL: arma el Data      │ ──► │ Mora por tramo  │
 │ cuotas        │        │ Warehouse y aplica     │     │ Recuperación    │
 │ pagos (+API)  │        │ cada pago a su cuota   │     │ mensual         │
 └───────────────┘        └────────────────────────┘     └─────────────────┘
```

**Conceptos que verás en todo el proyecto:**

| Palabra | Qué significa |
|---|---|
| **Data Warehouse (DW)** | Una base de datos ordenada para analizar, no para operar. |
| **Origen (`src`)** | Los datos tal como llegan, sin tocar. |
| **Dimensión / Hecho** | Dimensión = etiqueta (cliente, fecha). Hecho = número que se suma (pago, saldo). |
| **Carga incremental** | Agregar solo lo nuevo en vez de cargar todo otra vez. |
| **Idempotente** | Puedes ejecutarlo 2, 3 o 10 veces y el resultado es el mismo: no duplica nada. |
| **FIFO** | "Primero en entrar, primero en salir": un pago cubre primero la cuota más antigua. |
| **Mora** | Dinero de cuotas ya vencidas y sin pagar; se clasifica por días de atraso. |
| **Staging** | Zona de espera donde quedan los datos ya limpios antes de entrar al DW. |
| **Bitácora** | Diario de cada proceso: cuándo corrió, cuántas filas y si salió bien. |

**¿Dónde leer más?** Cada carpeta tiene su propia guía:

| Carpeta | Guía | Qué explica |
|---|---|---|
| `sql/` | [`sql/README.md`](sql/README.md) | El modelo de datos, cada script y las reglas de mora y de aplicación de pagos. |
| `python/` | [`python/README.md`](python/README.md) | Cómo funcionan el cargador y el extractor de la API. |
| `python/tests/` | [`python/tests/README.md`](python/tests/README.md) | Qué comprueban las pruebas automáticas. |
| `data/` | [`data/README.md`](data/README.md) | Qué contiene cada archivo y qué errores traen a propósito. |
| `docs/` | [`docs/README.md`](docs/README.md) | Resumen del documento de diseño. |

> **Avisos importantes de este repositorio**
>
> - Los datos están en `data/Paquete_datos_prueba_tecnica/`, pero `config.py` y
>   `run_all.ps1` buscan por defecto en `Instacredit/Paquete_datos_prueba_tecnica`.
>   Define `DATA_DIR` e `INPUT_JSON_PATH` en `python/.env` (ver sección 6).
> - El archivo `python/.env.example` que se menciona más abajo **no está incluido**;
>   crea `python/.env` a mano con las variables de la sección 6.
> - Los documentos `Manual_Ejecucion_Windows_AzureSQL.pdf`,
>   `Evidencias_Ejecucion.txt` y `Checklist_Caso02.md` no están en `docs/`.

## 1. Versiones utilizadas

| Componente | Versión |
|---|---|
| Base de datos | **SQL Server 2019** (Windows). Scripts probados de extremo a extremo en esta versión. |
| Cliente SQL | `sqlcmd` o SQL Server Management Studio (SSMS) |
| Sistema operativo | Windows 10/11 x64 |
| Python | 3.10 o superior (probado con 3.12) |
| Driver SQL Server | `pyodbc 5.3.0` + ODBC Driver 18 for SQL Server |
| Otras librerías | `python-dotenv 1.0.1`, `requests 2.32.3` |

## 2. Estructura de la entrega

```text
run_all.ps1 / run_all.cmd    Runner único del flujo completo
sql/
  00_crear_base_datos.sql    Crea las bases DatosPrueba (origen) y dw.DatosPrueba (DW); se omite en Azure
  00_cargar_origen.sql       Crea el esquema src y sus tablas (no carga CSV)
  01_dw_ddl.sql              Dimensiones, hechos, auditoría, staging, índices, vistas y procs
  02_carga_inicial.sql       Carga inicial al corte 2026-10-25
  03_carga_incremental.sql   Procedimiento incremental + ejecución del lote
  04_consultas.sql           Consultas de negocio (cartera, mora, recuperación)
  05_validaciones.sql        Validaciones automáticas con THROW ante fallo
  06_integrar_pagos_externos.sql  Integra staging API -> fact_pago (idempotente)
python/                      (ver python/README.md)
  config.py                  Configuración por entorno/.env
  validators.py              Normalización, validación y deduplicación
  db.py                      Acceso parametrizado con pyodbc
  load_src.py                Carga los seis CSV del paquete en src.*
  extractor_pagos.py         Fuente paginada (JSON/HTTP), staging, rechazos y bitácora
  requirements.txt
  tests/test_validators.py   Pruebas del validador (ver python/tests/README.md)
data/                        (ver data/README.md)
  Paquete_datos_prueba_tecnica/   CSV, JSON de la API y script original de tablas
docs/                        (ver docs/README.md)
  Documento_Diseno.pdf
```

Archivos que genera el propio proceso (no son código): `python/extractor.log` y
`python/rechazos_api.json`. Los archivos `__pycache__/` son temporales de Python.

## 3. Requisitos previos

1. SQL Server 2019 (Windows) con permiso para crear bases de datos.
2. Windows 10/11 y Python 3.10+.
3. **ODBC Driver 18 for SQL Server** instalado.
4. `sqlcmd` o SSMS instalado.
5. La carpeta `Paquete_datos_prueba_tecnica` sin modificar.

## 4. Azure SQL Database (no compatible con esta versión)

Las instrucciones de esta sección se conservan solo como referencia. Con la
lectura entre bases de `02`, `03` y `05`, el flujo no funciona en Azure SQL
Database (ver sección 10). Use SQL Server 2019 local.

### 4.1 Crear el servidor y la base

En Azure Portal:

1. Cree un **SQL server** (Logical server) con autenticación SQL.
2. Cree dos bases de datos: `DatosPrueba` (origen) y `dw.DatosPrueba` (DW).
3. En **Additional settings > Collation** seleccione
   `Latin1_General_100_CI_AS_SC_UTF8`.
4. En **Networking** agregue la IP pública de su equipo al firewall.
5. Guarde el servidor, usuario administrador y contraseña.

También puede crear la base por T-SQL, conectado a `master` con un usuario
administrador del servidor:

```sql
CREATE DATABASE [DatosPrueba]    COLLATE Latin1_General_100_CI_AS_SC_UTF8;
CREATE DATABASE [dw.DatosPrueba] COLLATE Latin1_General_100_CI_AS_SC_UTF8;
```

No ejecute `00_cargar_origen.sql` en `master`: conéctese a `DatosPrueba` con
`sqlcmd -d DatosPrueba`. `01_dw_ddl.sql` se ejecuta con `sqlcmd -d "dw.DatosPrueba"`.

### 4.2 Instalar herramientas en Windows

1. Instale **ODBC Driver 18 for SQL Server** desde el sitio oficial de Microsoft.
2. Instale `sqlcmd` (paquete de Microsoft) o SSMS.
3. Verifique Python y el driver:

```powershell
python --version
python -c "import pyodbc; print(pyodbc.version)"
```

## 5. Instalar dependencias Python

Abra PowerShell en la carpeta de la entrega:

```powershell
cd .\python
python -m venv .venv
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Si PowerShell bloquea la activación del entorno, ejecute una vez:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 6. Configurar el entorno

```powershell
cd .\python
notepad .env      # crea el archivo; no existe un .env.example en este repositorio
```

Ajuste como mínimo:

```dotenv
DB_SERVER=tu-servidor.database.windows.net
DB_PORT=1433
DB_NAME=dw.DatosPrueba
SRC_DB_NAME=DatosPrueba
DB_USER=sqladmin
DB_PASSWORD='TuClave#Segura2026'
DB_DRIVER=ODBC Driver 18 for SQL Server
DB_ENCRYPT=yes
DB_TRUST_CERT=no
DATA_DIR=data/Paquete_datos_prueba_tecnica
INPUT_JSON_PATH=data/Paquete_datos_prueba_tecnica/api_pagos_externos.json
```

Qué significa cada variable:

| Variable | Para qué sirve |
|---|---|
| `DB_SERVER`, `DB_PORT` | Dónde está SQL Server. |
| `DB_NAME` | Base del Data Warehouse (`dw.DatosPrueba`). |
| `SRC_DB_NAME` | Base de origen (`DatosPrueba`). |
| `DB_USER`, `DB_PASSWORD` | Usuario y contraseña (la contraseña es obligatoria). |
| `DB_DRIVER` | Driver ODBC instalado en tu equipo. |
| `DB_ENCRYPT`, `DB_TRUST_CERT` | Cifrado de la conexión y confianza en el certificado. |
| `DATA_DIR` | Carpeta con los CSV. |
| `INPUT_JSON_PATH` | Archivo JSON que simula la API. |
| `API_URL`, `API_TOKEN` | (Opcional) Si defines `API_URL`, se usa una API HTTP real en vez del JSON. |

Notas:

- Para Azure SQL Database mantenga `DB_ENCRYPT=yes` y `DB_TRUST_CERT=no`.
- Para un SQL Server local con certificado autofirmado use
  `DB_ENCRYPT=no` o `DB_TRUST_CERT=yes` solo en pruebas.
- Si la contraseña contiene `#`, espacios o caracteres especiales, enciérrela
  entre comillas simples en `.env`.
- Las rutas relativas de `DATA_DIR`, `INPUT_JSON_PATH`, `LOG_FILE` y
  `REJECTS_FILE` se resuelven contra la raíz de la entrega. También puede usar
  rutas absolutas.
- `.env` contiene credenciales y **no** debe incluirse en el ZIP final.

## 7. Ejecutar la solución en orden

### 7.1 Runner recomendado

El runner lee `python/.env` (o variables de entorno) y ejecuta todo el flujo
(equivale a pulsar un solo botón en lugar de correr los 8 pasos uno por uno):

```powershell
cd .
.\run_all.cmd
```

Solo como referencia, para Azure SQL Database (no compatible con esta versión):

```powershell
.\run_all.ps1 -Azure -Server "tu-servidor.database.windows.net" `
    -Database "dw.DatosPrueba" -SrcDatabase DatosPrueba -User sqladmin -Password 'TuClave#Segura2026'
```

Para SQL Server local, `00_crear_base_datos.sql` se ejecuta contra `master`:

```powershell
.\run_all.ps1 -Server "localhost,1433" -User sa -Password 'Instacredit#2026'
```

El runner ejecuta, en este orden:

1. `00_crear_base_datos.sql` (solo local; omitido con `-Azure`).
2. `00_cargar_origen.sql`.
3. `python/load_src.py`.
4. `01_dw_ddl.sql` y `02_carga_inicial.sql`.
5. `03_carga_incremental.sql` dos veces.
6. `python/extractor_pagos.py` dos veces.
7. `06_integrar_pagos_externos.sql` dos veces.
8. `04_consultas.sql` y `05_validaciones.sql`.

### 7.2 Ejecución manual

Defina las variables para `sqlcmd` en PowerShell. Use comillas simples si la
contraseña contiene `$` para evitar la interpolación de PowerShell:

```powershell
$SqlServer = "localhost,1433"       # o tu-servidor.database.windows.net
$Db        = "dw.DatosPrueba"
$SrcDb     = "DatosPrueba"
$SqlUser   = "sa"
$SqlPass   = 'Instacredit#2026'     # comillas simples si contiene $
$SqlArgs   = @("-S",$SqlServer,"-d",$Db,"-U",$SqlUser,"-P",$SqlPass,"-b","-f","65001")
```

SQL Server local (si la base aún no existe):

```powershell
sqlcmd -S $SqlServer -d master -U $SqlUser -P $SqlPass -b -f 65001 -i .\sql\00_crear_base_datos.sql
```

Carga de origen y CSV:

```powershell
sqlcmd @SqlArgs -i .\sql\00_cargar_origen.sql
cd .\python
python load_src.py
cd ..
```

`load_src.py` debe mostrar 10 / 300 / 480 / 13,485 / 7,518 / 53 filas.

Data Warehouse, cargas e integración API:

```powershell
sqlcmd @SqlArgs -i .\sql\01_dw_ddl.sql
sqlcmd @SqlArgs -i .\sql\02_carga_inicial.sql

# Primera corrida: 46 insertadas, 4 actualizadas, 3 omitidas
sqlcmd @SqlArgs -i .\sql\03_carga_incremental.sql
# Segunda corrida: 0 insertadas, 0 actualizadas, 53 omitidas
sqlcmd @SqlArgs -i .\sql\03_carga_incremental.sql

cd .\python
python extractor_pagos.py   # 113 válidos, 9 rechazados
python extractor_pagos.py   # 0 insertados, 113 omitidos, sin duplicar
cd ..

# Primera integración: 113 insertadas en fact_pago
sqlcmd @SqlArgs -i .\sql\06_integrar_pagos_externos.sql
# Segunda integración: 0 insertadas, 113 omitidas
sqlcmd @SqlArgs -i .\sql\06_integrar_pagos_externos.sql

sqlcmd @SqlArgs -i .\sql\04_consultas.sql
sqlcmd @SqlArgs -i .\sql\05_validaciones.sql
```

Debe mostrar `37 validaciones, 37 OK, 0 fallos, 0 pendientes`.

> Si usa `sqlcmd` clásico y observa caracteres raros en los comentarios,
> agregue `-f 65001` a los comandos. Los scripts de esta variante están
> guardados en UTF-8 con BOM.

## 8. Resultados esperados (verificados)

| Validación | Esperado |
|---|---|
| `src.sucursales/clientes/creditos/cuotas` | 10 / 300 / 480 / 13,485 |
| `src.pagos` filas / `id_pago` únicos | 7,518 / 7,513 |
| `src.pagos` sin `id_cuota` | 91 |
| `src.pagos_incremental` | 53 |
| Duplicados exactos de `src.pagos` rechazados | 5 |
| `dw.fact_pago` tras incremental | 7,559 |
| `dw.fact_pago` tras integrar API | 7,672 |
| 1ª corrida incremental | 46 insertadas / 4 actualizadas / 3 omitidas |
| 2ª corrida incremental | 0 / 0 / 53 |
| Correcciones en historial | 4 |
| Extractor 1ª corrida | 113 válidos / 9 rechazados (2 duplicados) |
| Extractor 2ª corrida | 0 insertados / 113 omitidos / 9 rechazados |
| Staging externo | 113 filas |
| 1ª integración API | 113 insertadas / 0 rechazadas |
| 2ª integración API | 0 insertadas / 113 omitidas |
| Validación final `05` | 37/37 OK |

## 9. Reglas de negocio aplicadas

- **Duplicados de pagos:** se conserva una sola fila por `id_pago`; el resto se
  registra en `dw.rechazos` como `DUPLICADO_EXACTO` (5 en la carga inicial).
- **Pagos sin `id_cuota`:** se cargan como `tipo_pago = 'DIRECTO'` y se aplican
  FIFO a las cuotas impagas más antiguas del crédito.
- **Pagos parciales:** se aplican por el monto recibido; la cuota queda con
  saldo pendiente y ese saldo alimenta la mora.
- **Sobrepagos:** una vez cubiertas las cuotas, el remanente queda en
  `fact_pago.monto_no_aplicado` (no se inventa una cuota).
- **Pagos con cuota indicada:** primero se abona a esa cuota; si ya está paga o
  sobra monto, el remanente sigue la regla FIFO.
- **Pagos tardíos:** se insertan con su `fecha_pago` real y el recálculo
  completo reordena las aplicaciones cronológicamente.
- **Correcciones:** mismo `id_pago` con datos distintos actualiza el hecho y deja
  rastro en `dw.historial_correcciones`.
- **Pagos de la API externa:** se validan y deduplican por `referencia` en
  `dw.stg_pagos_externos`; los válidos se integran como `origen='API'` y
  `tipo_pago='DIRECTO'`. La segunda integración no duplica.
- **Mora:** saldo de cuotas con `fecha_vencimiento < fecha_corte`; tramos
  1–30, 31–60, 61–90 y >90 según el mayor atraso del crédito. Los pagos se
  consideran al corte por `fecha_pago <= fecha_corte`.

## 10. Supuestos y notas

- La fecha de corte inicial es `2026-10-25`; el incremental genera el corte
  `2026-10-27`.
- El snapshot histórico `2026-10-25` queda congelado; una corrección o pago
  tardío afecta el corte nuevo.
- El paquete original no se modificó. `00_cargar_origen.sql` recrea `src.*` y
  `load_src.py` recarga los CSV.
- Bases separadas: `DatosPrueba` contiene `src.*` (origen) y `dw.DatosPrueba`
  contiene el DW completo (`01_dw_ddl.sql` en adelante). `02`, `03` y `05`
  leen `[DatosPrueba].src.*` con nombre de tres partes.
- **Limitación Azure SQL Database:** las consultas entre bases (nombre de tres
  partes) no están soportadas en Azure SQL Database. El flujo de esta versión
  funciona en SQL Server local (o instancia con ambas bases en el mismo
  servidor). Para Azure hay que cambiar la lectura de `src.*` (por ejemplo,
  cargar el DW desde Python o usar una sola base).
- No se incluyen credenciales ni el archivo `.env` (solo `.env.example`).
- Azure SQL Database no tiene SQL Agent. Para programar en producción use
  Elastic Jobs, Azure Automation, Airflow o un orquestador equivalente.
- El ZIP final se llama `Solano_Giovanni_PruebaDatos.zip` y excluye `.env`,
  `.venv`, `__pycache__`, logs y archivos temporales de rechazos.

## 11. Solución de problemas

| Síntoma | Causa / solución |
|---|---|
| `Cannot open server ...` | Agregue la IP del equipo al firewall del servidor Azure. |
| `SSL Provider: certificate chain` | Deje `DB_TRUST_CERT=no` en Azure; verifique ODBC 18. |
| `ODBC Driver 18 for SQL Server not found` | Instale el driver y confirme con `pyodbc.drivers()`. |
| `Cannot open database ... requested by the login` | La base `DatosPrueba` o `dw.DatosPrueba` no existe; ejecute `00_crear_base_datos.sql` en `master`. |
| `Cannot bulk load ... file` | Azure no ve archivos locales; use `python load_src.py`. |
| `Login failed for user` | Revise usuario, contraseña, base y firewall. |
| Acentos incorrectos | La base debe usar collation UTF-8; los CSV se leen con `utf-8-sig`. |
| `pyodbc.InterfaceError` al conectar | Falta el driver ODBC o el nombre del servidor es incorrecto. |
