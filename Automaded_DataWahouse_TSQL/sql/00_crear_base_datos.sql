/* =====================================================================
   Prueba tecnica Instacredit - Ingeniero de Datos
   Variante Windows / SQL Server local
   00_crear_base_datos.sql

   Crea DOS bases de datos (no crea esquemas ni tablas):
     - DatosPrueba     : base ORIGEN. 00_cargar_origen.sql crea src.*.
     - dw.DatosPrueba  : base del DATA WAREHOUSE. 01_dw_ddl.sql crea dw.*.

   Ejecutar conectado a master:
       sqlcmd -S localhost -U sa -P *** -C -f 65001 -i 00_crear_base_datos.sql

   En Azure SQL Database las bases deben existir previamente; el runner
   omite este script cuando se usa -Azure.
   ===================================================================== */
SET NOCOUNT ON;
GO

IF DB_ID(N'DatosPrueba') IS NULL
BEGIN
    IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 15
        EXEC('CREATE DATABASE [DatosPrueba] COLLATE Latin1_General_100_CI_AS_SC_UTF8');
    ELSE
        EXEC('CREATE DATABASE [DatosPrueba]');
    PRINT 'Base DatosPrueba creada.';
END
ELSE
    PRINT 'Base DatosPrueba ya existe.';
GO

IF DB_ID(N'dw.DatosPrueba') IS NULL
BEGIN
    IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 15
        EXEC('CREATE DATABASE [dw.DatosPrueba] COLLATE Latin1_General_100_CI_AS_SC_UTF8');
    ELSE
        EXEC('CREATE DATABASE [dw.DatosPrueba]');
    PRINT 'Base dw.DatosPrueba creada.';
END
ELSE
    PRINT 'Base dw.DatosPrueba ya existe.';
GO

IF EXISTS (SELECT 1 FROM sys.databases
           WHERE name IN (N'DatosPrueba', N'dw.DatosPrueba')
             AND collation_name <> N'Latin1_General_100_CI_AS_SC_UTF8')
    PRINT 'ADVERTENCIA: alguna base no usa Latin1_General_100_CI_AS_SC_UTF8. Los acentos pueden perderse.';
GO
