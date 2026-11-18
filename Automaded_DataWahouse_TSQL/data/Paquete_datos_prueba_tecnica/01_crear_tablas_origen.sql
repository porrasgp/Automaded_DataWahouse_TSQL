/* =====================================================================
   Prueba técnica - Ingeniero de Datos
   Script de creación de la base de datos y tablas ORIGEN (esquema src)
   Probado en SQL Server 2019+ (Developer / Express / Docker)
   ---------------------------------------------------------------------
   1. Ejecute este script completo.
   2. Cargue los CSV en las tablas src.* (al final hay un ejemplo con
      BULK INSERT; ajuste la ruta a la carpeta donde descomprimió el paquete.
      También puede usar el asistente de importación de SSMS o Python).
   3. Los datos son 100% ficticios.
   ===================================================================== */

IF DB_ID('PruebaDatos') IS NULL
    CREATE DATABASE PruebaDatos;
GO
USE PruebaDatos;
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
    estado              NVARCHAR(20)  NOT NULL   -- Vigente / Cancelado / Castigado
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

/* Tabla de pagos tal como la entrega el sistema transaccional.
   Observaciones: id_cuota puede venir vacío (abono directo al crédito);
   pueden existir filas duplicadas; fecha_registro es la fecha en que el
   pago quedó registrado en el sistema (puede ser posterior a fecha_pago). */

CREATE TABLE src.pagos (
    id_pago         VARCHAR(10)   NOT NULL,
    id_credito      VARCHAR(10)   NOT NULL,
    id_cuota        VARCHAR(10)   NULL,
    fecha_pago      DATE          NOT NULL,
    monto           DECIMAL(14,2) NOT NULL,
    canal           NVARCHAR(20)  NOT NULL,
    fecha_registro  DATE          NOT NULL
);

/* Lote incremental: pagos registrados los días 26 y 27 de octubre de 2026,
   que llegan DESPUÉS de la primera carga. Misma estructura que src.pagos.
   Incluye pagos nuevos, pagos con fecha_pago anterior al corte que se
   registraron tarde, correcciones (mismo id_pago con monto distinto) y duplicados. */
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

/* ---------------------------------------------------------------------
   Ejemplo de carga con BULK INSERT (ajuste la ruta). En Linux/Docker use
   rutas tipo '/var/opt/mssql/data/paquete/clientes.csv'.
   Los CSV usan coma como separador, punto decimal, codificación UTF-8 y
   tienen encabezado en la primera fila.
   --------------------------------------------------------------------- */

DECLARE @ruta NVARCHAR(260) = N'C:\Users\Admin\Downloads\empresa\Paquete_datos_prueba_tecnica\';
DECLARE @sql NVARCHAR(MAX);
DECLARE @t TABLE (tabla SYSNAME, archivo NVARCHAR(100));
INSERT @t VALUES ('src.sucursales','sucursales.csv'),('src.clientes','clientes.csv'),
                 ('src.creditos','creditos.csv'),('src.cuotas','cuotas.csv'),
                 ('src.pagos','pagos.csv'),('src.pagos_incremental','pagos_incremental.csv');
DECLARE cur CURSOR FOR SELECT tabla, archivo FROM @t;
DECLARE @tabla SYSNAME, @archivo NVARCHAR(100);
OPEN cur; FETCH NEXT FROM cur INTO @tabla, @archivo;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT ' + @tabla + N' FROM ''' + @ruta + @archivo + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, CODEPAGE=''65001'', FIELDTERMINATOR='','', ROWTERMINATOR=''0x0a'', KEEPNULLS);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM cur INTO @tabla, @archivo;
END
CLOSE cur; DEALLOCATE cur;


/* Verificación rápida después de cargar */

SELECT 'sucursales', COUNT(*) FROM src.sucursales UNION ALL
SELECT 'clientes',   COUNT(*) FROM src.clientes   UNION ALL
SELECT 'creditos',   COUNT(*) FROM src.creditos   UNION ALL
SELECT 'cuotas',     COUNT(*) FROM src.cuotas     UNION ALL
SELECT 'pagos',      COUNT(*) FROM src.pagos      UNION ALL
SELECT 'pagos_incremental', COUNT(*) FROM src.pagos_incremental;

/* Esperado: 10 / 300 / 480 / 13485 / 7518 / 53 */
