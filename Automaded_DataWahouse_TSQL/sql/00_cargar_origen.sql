/* =====================================================================
   Prueba tecnica Instacredit - Ingeniero de Datos
   00_cargar_origen.sql - Variante Windows / Azure SQL Database
   Crea UNICAMENTE el esquema src y las tablas ORIGEN en DatosPrueba (base origen).

   Ejecutar seleccionando la base destino (NO en master):
       sqlcmd -S localhost -d DatosPrueba -U sa -P *** -C -f 65001 -i 00_cargar_origen.sql

   La base se crea aparte con 00_crear_base_datos.sql. El Data Warehouse
   (dw.DatosPrueba) se crea aparte con 01_dw_ddl.sql.

   Es idempotente: recrea las tablas src. Ejecute python/load_src.py despues.
   ===================================================================== */
SET NOCOUNT ON;
GO

IF DB_NAME() IN ('master','model','msdb','tempdb')
    THROW 50000, 'Conectese a DatosPrueba con -d DatosPrueba antes de ejecutar este script.', 1;
GO

IF SCHEMA_ID('src') IS NULL EXEC('CREATE SCHEMA src');
GO

DROP TABLE IF EXISTS src.pagos_incremental;
DROP TABLE IF EXISTS src.pagos;
DROP TABLE IF EXISTS src.cuotas;
DROP TABLE IF EXISTS src.creditos;
DROP TABLE IF EXISTS src.clientes;
DROP TABLE IF EXISTS src.sucursales;
GO

CREATE TABLE src.sucursales (
    id_sucursal   INT           NOT NULL PRIMARY KEY,
    nombre        NVARCHAR(60)  NOT NULL,
    provincia     NVARCHAR(30)  NOT NULL
);

CREATE TABLE src.clientes (
    id_cliente        VARCHAR(10)   NOT NULL PRIMARY KEY,
    nombre_completo   NVARCHAR(120) NOT NULL,
    fecha_nacimiento  DATE          NOT NULL,
    provincia         NVARCHAR(30)  NOT NULL,
    telefono          VARCHAR(12)   NULL,
    fecha_alta        DATE          NOT NULL,
    segmento          NVARCHAR(30)  NOT NULL,
    ingreso_mensual   DECIMAL(14,2) NULL
);

CREATE TABLE src.creditos (
    id_credito          VARCHAR(10)   NOT NULL PRIMARY KEY,
    id_cliente          VARCHAR(10)   NOT NULL REFERENCES src.clientes(id_cliente),
    id_sucursal         INT           NOT NULL REFERENCES src.sucursales(id_sucursal),
    producto            NVARCHAR(40)  NOT NULL,
    monto_desembolsado  DECIMAL(14,2) NOT NULL,
    tasa_anual          DECIMAL(6,4)  NOT NULL,
    plazo_meses         INT           NOT NULL,
    fecha_desembolso    DATE          NOT NULL,
    cuota_mensual       DECIMAL(14,2) NOT NULL,
    estado              NVARCHAR(20)  NOT NULL
);

CREATE TABLE src.cuotas (
    id_cuota           VARCHAR(10)   NOT NULL PRIMARY KEY,
    id_credito         VARCHAR(10)   NOT NULL REFERENCES src.creditos(id_credito),
    numero_cuota       INT           NOT NULL,
    fecha_vencimiento  DATE          NOT NULL,
    monto_cuota        DECIMAL(14,2) NOT NULL,
    monto_principal    DECIMAL(14,2) NOT NULL,
    monto_interes      DECIMAL(14,2) NOT NULL
);

CREATE TABLE src.pagos (
    id_pago         VARCHAR(10)   NOT NULL,
    id_credito      VARCHAR(10)   NOT NULL,
    id_cuota        VARCHAR(10)   NULL,
    fecha_pago      DATE          NOT NULL,
    monto           DECIMAL(14,2) NOT NULL,
    canal           NVARCHAR(20)  NOT NULL,
    fecha_registro  DATE          NOT NULL
);

CREATE TABLE src.pagos_incremental (
    id_pago         VARCHAR(10)   NOT NULL,
    id_credito      VARCHAR(10)   NOT NULL,
    id_cuota        VARCHAR(10)   NULL,
    fecha_pago      DATE          NOT NULL,
    monto           DECIMAL(14,2) NOT NULL,
    canal           NVARCHAR(20)  NOT NULL,
    fecha_registro  DATE          NOT NULL
);
GO

PRINT 'Esquema src creado. Ejecute python/load_src.py para cargar los CSV.';
GO