# Automaded_DataWahouse_TSQL

Data Warehouse de cartera de créditos, construido con **SQL Server (T-SQL)** y
**Python**, con carga inicial, carga incremental y extractor de una API externa.
Todo el flujo se puede ejecutar con un solo comando y es **idempotente** (se puede
repetir sin duplicar datos).

> Proyecto de una prueba técnica de Ingeniería de Datos. Los datos son ficticios.

## ¿Qué hace?

Una financiera ficticia presta dinero que se paga en cuotas. Este proyecto:

1. **Carga** clientes, créditos, cuotas y pagos desde archivos CSV.
2. **Construye un Data Warehouse** (modelo estrella) en SQL Server.
3. **Aplica cada pago** a la cuota que corresponde (la más antigua primero).
4. **Calcula la mora** por tramos (1-30, 31-60, 61-90, más de 90 días).
5. **Agrega pagos nuevos** cada día sin duplicar nada y deja historial de las correcciones.
6. **Extrae pagos de una API externa**, rechaza los datos malos y deja registro del motivo.
7. **Se autoverifica** con 37 validaciones automáticas.

```text
 CSV + API ──► Python (limpia y valida) ──► SQL Server ──► Cartera · Mora · Recuperación
```

## Estructura del repositorio

```text
Automaded_DataWahouse_TSQL/
├── README.md                          ← estás aquí
├── LICENSE                            Licencia MIT
└── Automaded_DataWahouse_TSQL/
    ├── LEAME.md                       Guía completa de instalación y ejecución
    ├── run_all.ps1 / run_all.cmd      Ejecutan todo el flujo en orden
    ├── sql/                           Scripts T-SQL: el modelo y la lógica
    ├── python/                        Cargador de CSV y extractor de la API
    │   └── tests/                     Pruebas automáticas del validador
    ├── data/                          Datos de entrada (CSV y JSON)
    └── docs/                          Documento de diseño
```

## Guías por carpeta

Cada carpeta tiene un `README.md` con explicaciones sencillas de su código:

| Carpeta | Qué encontrarás |
|---|---|
| [`LEAME.md`](Automaded_DataWahouse_TSQL/LEAME.md) | Instalación, configuración y ejecución paso a paso. |
| [`sql/`](Automaded_DataWahouse_TSQL/sql/README.md) | Modelo de datos, cada script, reglas de mora y de aplicación de pagos. |
| [`python/`](Automaded_DataWahouse_TSQL/python/README.md) | Cómo funcionan el cargador y el extractor. |
| [`python/tests/`](Automaded_DataWahouse_TSQL/python/tests/README.md) | Qué verifica cada prueba. |
| [`data/`](Automaded_DataWahouse_TSQL/data/README.md) | Qué contiene cada archivo y qué errores traen a propósito. |
| [`docs/`](Automaded_DataWahouse_TSQL/docs/README.md) | Resumen del documento de diseño. |

## Inicio rápido

Necesitas Windows, SQL Server 2019, Python 3.10+, ODBC Driver 18 y `sqlcmd`.

```powershell
cd Automaded_DataWahouse_TSQL\python
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
notepad .env            # configura la conexión (ver LEAME.md, sección 6)
cd ..
.\run_all.cmd
```

Al terminar, `05_validaciones.sql` debe mostrar **37 validaciones, 37 OK, 0 fallos**.

## Tecnologías

| Para qué | Qué se usa |
|---|---|
| Base de datos | SQL Server 2019 (T-SQL, procedimientos almacenados, `MERGE`) |
| Extracción y carga | Python 3.10+ con `pyodbc`, `requests`, `python-dotenv` |
| Pruebas | `unittest` |
| Automatización | PowerShell (`run_all.ps1`) |

## Limitaciones conocidas

- **No funciona en Azure SQL Database**: algunos scripts leen entre bases de datos, algo que Azure no permite.
- La llamada HTTP real del extractor **no se ha probado** contra un proveedor real; hoy se simula con el JSON del paquete.
- No incluye programación automática (SQL Server Agent, Airflow); solo se propone en el documento de diseño.

## Licencia

MIT. Consulta [`LICENSE`](LICENSE).
