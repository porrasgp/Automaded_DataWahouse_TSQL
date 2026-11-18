/* =====================================================================
   Prueba tecnica Instacredit - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   01_dw_ddl.sql
   Modelo dimensional (esquema dw), tablas de auditoria/staging,
   restricciones, indices y procedimientos base.
   Se ejecuta en la base del DW: dw.DatosPrueba (sqlcmd -d "dw.DatosPrueba").
   Idempotente: elimina y recrea los objetos del DW.
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_NAME() <> N'dw.DatosPrueba'
    THROW 50000, 'Conectese a la base del DW con -d "dw.DatosPrueba" antes de ejecutar este script.', 1;
GO

IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO

/* ---------- Limpieza idempotente (dependencias primero) ---------- */
DROP VIEW  IF EXISTS dw.vw_mora_tramo_sucursal;
DROP VIEW  IF EXISTS dw.vw_bitacora_resumen;
DROP PROCEDURE IF EXISTS dw.usp_CargaIncrementalPagos;
DROP PROCEDURE IF EXISTS dw.usp_IntegrarPagosExternos;
DROP PROCEDURE IF EXISTS dw.usp_GenerarCorte;
DROP PROCEDURE IF EXISTS dw.usp_RecalcularAplicaciones;
DROP TABLE IF EXISTS dw.fact_aplicacion;
DROP TABLE IF EXISTS dw.fact_cartera;
DROP TABLE IF EXISTS dw.fact_pago;
DROP TABLE IF EXISTS dw.fact_cuota;
DROP TABLE IF EXISTS dw.dim_credito;
DROP TABLE IF EXISTS dw.dim_cliente;
DROP TABLE IF EXISTS dw.dim_sucursal;
DROP TABLE IF EXISTS dw.dim_producto;
DROP TABLE IF EXISTS dw.dim_canal;
DROP TABLE IF EXISTS dw.dim_fecha;
DROP TABLE IF EXISTS dw.rechazos;
DROP TABLE IF EXISTS dw.historial_correcciones;
DROP TABLE IF EXISTS dw.bitacora_ejecucion;
DROP TABLE IF EXISTS dw.stg_pagos_externos;
GO

/* =====================================================================
   DIMENSIONES
   ===================================================================== */
CREATE TABLE dw.dim_fecha (
    fecha_key       INT          NOT NULL CONSTRAINT pk_dim_fecha PRIMARY KEY,
    fecha           DATE         NOT NULL CONSTRAINT uq_dim_fecha UNIQUE,
    anio            SMALLINT     NOT NULL,
    mes             TINYINT      NOT NULL CHECK (mes BETWEEN 1 AND 12),
    nombre_mes      NVARCHAR(20) NOT NULL,
    trimestre       TINYINT      NOT NULL CHECK (trimestre BETWEEN 1 AND 4),
    dia             TINYINT      NOT NULL,
    dia_semana      TINYINT      NOT NULL,       -- 1 = lunes ... 7 = domingo
    nombre_dia      NVARCHAR(15) NOT NULL,
    es_fin_semana   BIT          NOT NULL,
    anio_mes        CHAR(7)      NOT NULL
);

CREATE TABLE dw.dim_sucursal (
    sucursal_key   INT           NOT NULL IDENTITY(1,1) CONSTRAINT pk_dim_sucursal PRIMARY KEY,
    id_sucursal    INT           NOT NULL CONSTRAINT uq_dim_sucursal UNIQUE,
    nombre         NVARCHAR(60)  NOT NULL,
    provincia      NVARCHAR(30)  NOT NULL
);

CREATE TABLE dw.dim_cliente (
    cliente_key       INT             NOT NULL IDENTITY(1,1) CONSTRAINT pk_dim_cliente PRIMARY KEY,
    id_cliente        VARCHAR(10)     NOT NULL CONSTRAINT uq_dim_cliente UNIQUE,
    nombre_completo   NVARCHAR(120)   NOT NULL,
    fecha_nacimiento  DATE            NOT NULL,
    provincia         NVARCHAR(30)    NOT NULL,
    segmento          NVARCHAR(30)    NOT NULL,
    fecha_alta        DATE            NOT NULL,
    ingreso_mensual   DECIMAL(14,2)   NULL
);

CREATE TABLE dw.dim_producto (
    producto_key   INT           NOT NULL IDENTITY(1,1) CONSTRAINT pk_dim_producto PRIMARY KEY,
    producto       NVARCHAR(40)  NOT NULL CONSTRAINT uq_dim_producto UNIQUE
);

CREATE TABLE dw.dim_canal (
    canal_key   INT           NOT NULL IDENTITY(1,1) CONSTRAINT pk_dim_canal PRIMARY KEY,
    canal       NVARCHAR(30)  NOT NULL CONSTRAINT uq_dim_canal UNIQUE,
    grupo       NVARCHAR(20)  NOT NULL
);

CREATE TABLE dw.dim_credito (
    credito_key           INT            NOT NULL IDENTITY(1,1) CONSTRAINT pk_dim_credito PRIMARY KEY,
    id_credito            VARCHAR(10)    NOT NULL CONSTRAINT uq_dim_credito UNIQUE,
    cliente_key           INT            NOT NULL,
    sucursal_key          INT            NOT NULL,
    producto_key          INT            NOT NULL,
    fecha_desembolso_key  INT            NOT NULL,
    monto_desembolsado    DECIMAL(14,2)  NOT NULL,
    tasa_anual            DECIMAL(6,4)   NOT NULL,
    plazo_meses           INT            NOT NULL,
    cuota_mensual         DECIMAL(14,2)  NOT NULL,
    estado                NVARCHAR(20)   NOT NULL,   -- Vigente / Cancelado / Castigado
    CONSTRAINT fk_dim_credito_cliente   FOREIGN KEY (cliente_key)          REFERENCES dw.dim_cliente(cliente_key),
    CONSTRAINT fk_dim_credito_sucursal  FOREIGN KEY (sucursal_key)         REFERENCES dw.dim_sucursal(sucursal_key),
    CONSTRAINT fk_dim_credito_producto  FOREIGN KEY (producto_key)         REFERENCES dw.dim_producto(producto_key),
    CONSTRAINT fk_dim_credito_fecha     FOREIGN KEY (fecha_desembolso_key) REFERENCES dw.dim_fecha(fecha_key)
);
CREATE INDEX ix_dim_credito_cliente  ON dw.dim_credito(cliente_key);
CREATE INDEX ix_dim_credito_sucursal ON dw.dim_credito(sucursal_key);
CREATE INDEX ix_dim_credito_estado   ON dw.dim_credito(estado);

/* =====================================================================
   HECHOS
   ===================================================================== */

/* Grano: una fila por cuota del plan de pagos. */
CREATE TABLE dw.fact_cuota (
    cuota_key               BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_fact_cuota PRIMARY KEY,
    id_cuota                VARCHAR(10)   NOT NULL CONSTRAINT uq_fact_cuota UNIQUE,
    credito_key             INT           NOT NULL,
    numero_cuota            INT           NOT NULL,
    fecha_vencimiento_key   INT           NOT NULL,
    monto_cuota             DECIMAL(14,2) NOT NULL CHECK (monto_cuota >= 0),
    monto_principal         DECIMAL(14,2) NOT NULL CHECK (monto_principal >= 0),
    monto_interes           DECIMAL(14,2) NOT NULL CHECK (monto_interes >= 0),
    CONSTRAINT fk_fact_cuota_credito FOREIGN KEY (credito_key)           REFERENCES dw.dim_credito(credito_key),
    CONSTRAINT fk_fact_cuota_fecha   FOREIGN KEY (fecha_vencimiento_key) REFERENCES dw.dim_fecha(fecha_key),
    CONSTRAINT uq_fact_cuota_cred_num UNIQUE (credito_key, numero_cuota)
);
CREATE INDEX ix_fact_cuota_credito ON dw.fact_cuota(credito_key);
CREATE INDEX ix_fact_cuota_venc    ON dw.fact_cuota(fecha_vencimiento_key);

/* Grano: una fila por pago unico (id_pago). Los duplicados exactos no entran. */
CREATE TABLE dw.fact_pago (
    pago_key              BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_fact_pago PRIMARY KEY,
    id_pago               VARCHAR(10)   NOT NULL CONSTRAINT uq_fact_pago UNIQUE,
    credito_key           INT           NOT NULL,
    fecha_pago_key        INT           NOT NULL,
    fecha_registro_key    INT           NOT NULL,
    canal_key             INT           NOT NULL,
    monto                 DECIMAL(14,2) NOT NULL CHECK (monto > 0),
    tipo_pago             VARCHAR(10)   NOT NULL CHECK (tipo_pago IN ('CUOTA','DIRECTO')),
    id_cuota_origen       VARCHAR(10)   NULL,   -- cuota indicada por el origen (puede ser NULL)
    monto_aplicado        DECIMAL(14,2) NOT NULL DEFAULT (0) CHECK (monto_aplicado >= 0),
    monto_no_aplicado     DECIMAL(14,2) NOT NULL DEFAULT (0) CHECK (monto_no_aplicado >= 0),
    origen                VARCHAR(15)   NOT NULL DEFAULT ('INICIAL')
                                         CHECK (origen IN ('INICIAL','INCREMENTAL','API')),
    es_correccion         BIT           NOT NULL DEFAULT (0),
    fecha_carga           DATETIME2(3)  NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT fk_fact_pago_credito FOREIGN KEY (credito_key)        REFERENCES dw.dim_credito(credito_key),
    CONSTRAINT fk_fact_pago_fpago   FOREIGN KEY (fecha_pago_key)     REFERENCES dw.dim_fecha(fecha_key),
    CONSTRAINT fk_fact_pago_freg    FOREIGN KEY (fecha_registro_key) REFERENCES dw.dim_fecha(fecha_key),
    CONSTRAINT fk_fact_pago_canal   FOREIGN KEY (canal_key)          REFERENCES dw.dim_canal(canal_key)
);
CREATE INDEX ix_fact_pago_credito ON dw.fact_pago(credito_key);
CREATE INDEX ix_fact_pago_fpago   ON dw.fact_pago(fecha_pago_key);
CREATE INDEX ix_fact_pago_freg    ON dw.fact_pago(fecha_registro_key);
CREATE INDEX ix_fact_pago_canal   ON dw.fact_pago(canal_key);

/* Grano: una fila por aplicacion pago -> cuota (tabla puente). */
CREATE TABLE dw.fact_aplicacion (
    aplicacion_key   BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_fact_aplicacion PRIMARY KEY,
    pago_key         BIGINT        NOT NULL,
    cuota_key        BIGINT        NOT NULL,
    credito_key      INT           NOT NULL,
    fecha_pago_key   INT           NOT NULL,
    monto_aplicado   DECIMAL(14,2) NOT NULL CHECK (monto_aplicado > 0),
    CONSTRAINT fk_fact_apl_pago    FOREIGN KEY (pago_key)       REFERENCES dw.fact_pago(pago_key),
    CONSTRAINT fk_fact_apl_cuota   FOREIGN KEY (cuota_key)      REFERENCES dw.fact_cuota(cuota_key),
    CONSTRAINT fk_fact_apl_credito FOREIGN KEY (credito_key)    REFERENCES dw.dim_credito(credito_key),
    CONSTRAINT fk_fact_apl_fecha   FOREIGN KEY (fecha_pago_key) REFERENCES dw.dim_fecha(fecha_key),
    CONSTRAINT uq_fact_apl_pago_cuota UNIQUE (pago_key, cuota_key)
);
CREATE INDEX ix_fact_apl_cuota   ON dw.fact_aplicacion(cuota_key);
CREATE INDEX ix_fact_aplicacion_credito ON dw.fact_aplicacion(credito_key);

/* Grano: una fila por credito y fecha de corte (snapshot de cartera/mora). */
CREATE TABLE dw.fact_cartera (
    corte_key          INT           NOT NULL,
    credito_key        INT           NOT NULL,
    cliente_key        INT           NOT NULL,
    sucursal_key       INT           NOT NULL,
    producto_key       INT           NOT NULL,
    saldo_total        DECIMAL(14,2) NOT NULL CHECK (saldo_total >= 0),
    saldo_principal    DECIMAL(14,2) NOT NULL CHECK (saldo_principal >= 0),
    monto_vencido      DECIMAL(14,2) NOT NULL CHECK (monto_vencido >= 0),
    monto_no_vencido   DECIMAL(14,2) NOT NULL CHECK (monto_no_vencido >= 0),
    dias_mora_max      INT           NOT NULL DEFAULT (0),
    tramo_mora         VARCHAR(10)   NOT NULL CHECK (tramo_mora IN ('AL_DIA','1-30','31-60','61-90','>90')),
    estado_credito     NVARCHAR(20)  NOT NULL,
    cuotas_total       INT           NOT NULL,
    cuotas_pagadas     INT           NOT NULL,
    cuotas_vencidas    INT           NOT NULL,
    CONSTRAINT pk_fact_cartera PRIMARY KEY (corte_key, credito_key),
    CONSTRAINT fk_fact_cartera_corte    FOREIGN KEY (corte_key)    REFERENCES dw.dim_fecha(fecha_key),
    CONSTRAINT fk_fact_cartera_credito  FOREIGN KEY (credito_key)  REFERENCES dw.dim_credito(credito_key),
    CONSTRAINT fk_fact_cartera_cliente  FOREIGN KEY (cliente_key)  REFERENCES dw.dim_cliente(cliente_key),
    CONSTRAINT fk_fact_cartera_sucursal FOREIGN KEY (sucursal_key) REFERENCES dw.dim_sucursal(sucursal_key),
    CONSTRAINT fk_fact_cartera_producto FOREIGN KEY (producto_key) REFERENCES dw.dim_producto(producto_key)
);
CREATE INDEX ix_fact_cartera_sucursal ON dw.fact_cartera(sucursal_key);
CREATE INDEX ix_fact_cartera_producto ON dw.fact_cartera(producto_key);
CREATE INDEX ix_fact_cartera_tramo    ON dw.fact_cartera(tramo_mora);

/* =====================================================================
   AUDITORIA, RECHAZOS E HISTORIAL
   ===================================================================== */
CREATE TABLE dw.bitacora_ejecucion (
    id_ejecucion       BIGINT         NOT NULL IDENTITY(1,1) CONSTRAINT pk_bitacora PRIMARY KEY,
    proceso            VARCHAR(60)    NOT NULL,
    fecha_inicio       DATETIME2(3)   NOT NULL DEFAULT (SYSUTCDATETIME()),
    fecha_fin          DATETIME2(3)   NULL,
    filas_leidas       INT            NOT NULL DEFAULT (0),
    filas_insertadas   INT            NOT NULL DEFAULT (0),
    filas_actualizadas INT            NOT NULL DEFAULT (0),
    filas_rechazadas   INT            NOT NULL DEFAULT (0),
    filas_duplicadas   INT            NOT NULL DEFAULT (0),
    estado             VARCHAR(15)    NOT NULL DEFAULT ('EN_PROCESO')
                                      CHECK (estado IN ('EN_PROCESO','EXITOSO','FALLIDO')),
    mensaje            NVARCHAR(1000) NULL,
    ejecutado_por      NVARCHAR(100)  NOT NULL DEFAULT (SUSER_SNAME())
);
CREATE INDEX ix_bitacora_proceso ON dw.bitacora_ejecucion(proceso, fecha_inicio);

CREATE TABLE dw.rechazos (
    id_rechazo    BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_rechazos PRIMARY KEY,
    id_ejecucion  BIGINT        NULL,
    proceso       VARCHAR(60)   NOT NULL,
    origen        VARCHAR(60)   NOT NULL,
    referencia    VARCHAR(40)   NULL,
    motivo        VARCHAR(100)  NOT NULL,
    detalle       NVARCHAR(1000) NULL,
    fecha_registro DATETIME2(3) NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT fk_rechazos_bitacora FOREIGN KEY (id_ejecucion) REFERENCES dw.bitacora_ejecucion(id_ejecucion)
);
CREATE INDEX ix_rechazos_proceso ON dw.rechazos(proceso, referencia);

CREATE TABLE dw.historial_correcciones (
    id_correccion       BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_hist_corr PRIMARY KEY,
    id_ejecucion        BIGINT        NULL,
    id_pago             VARCHAR(10)   NOT NULL,
    monto_anterior      DECIMAL(14,2) NULL,
    monto_nuevo         DECIMAL(14,2) NULL,
    fecha_pago_anterior DATE          NULL,
    fecha_pago_nueva    DATE          NULL,
    detalle             NVARCHAR(1000) NULL,
    fecha_cambio        DATETIME2(3)  NOT NULL DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT fk_hist_corr_bitacora FOREIGN KEY (id_ejecucion) REFERENCES dw.bitacora_ejecucion(id_ejecucion)
);
CREATE INDEX ix_hist_corr_pago ON dw.historial_correcciones(id_pago);

/* =====================================================================
   STAGING EXTRACTOR API
   ===================================================================== */
CREATE TABLE dw.stg_pagos_externos (
    id_stg          BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT pk_stg_api PRIMARY KEY,
    referencia      VARCHAR(30)   NOT NULL CONSTRAINT uq_stg_api_ref UNIQUE,
    id_credito      VARCHAR(10)   NOT NULL,
    fecha_pago      DATE          NOT NULL,
    monto           DECIMAL(14,2) NOT NULL CHECK (monto > 0),
    moneda          CHAR(3)       NOT NULL,
    canal           NVARCHAR(30)  NOT NULL,
    estado          VARCHAR(20)   NOT NULL,
    comercio        NVARCHAR(60)  NULL,
    hora            VARCHAR(8)    NULL,
    hash_registro   CHAR(64)      NOT NULL,
    origen          VARCHAR(20)   NOT NULL DEFAULT ('API'),
    fecha_carga     DATETIME2(3)  NOT NULL DEFAULT (SYSUTCDATETIME())
);
CREATE INDEX ix_stg_api_credito ON dw.stg_pagos_externos(id_credito);
CREATE INDEX ix_stg_api_fecha   ON dw.stg_pagos_externos(fecha_pago);

/* =====================================================================
   CARGA DE DATOS
   Este script es solo DDL y codigo (tablas, indices, vistas y procs).
   La carga de dimensiones y hechos se realiza en 02_carga_inicial.sql.
   ===================================================================== */

GO

/* =====================================================================
   PROCEDIMIENTOS BASE
   ===================================================================== */

/* Recalcula TODAS las aplicaciones pago->cuota desde cero.
   Regla: primero se abona a la cuota indicada por el origen (si existe y
   tiene saldo); el remanente se aplica FIFO a las cuotas impagas mas
   antiguas del credito. El sobrante queda como monto_no_aplicado. */
CREATE OR ALTER PROCEDURE dw.usp_RecalcularAplicaciones
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DELETE FROM dw.fact_aplicacion;
    UPDATE dw.fact_pago
       SET monto_aplicado = 0,
           monto_no_aplicado = monto;

    CREATE TABLE #saldo (
        cuota_key          BIGINT        NOT NULL PRIMARY KEY,
        credito_key        INT           NOT NULL,
        numero_cuota       INT           NOT NULL,
        fecha_vencimiento  DATE          NOT NULL,
        saldo              DECIMAL(14,2) NOT NULL
    );
    CREATE INDEX ix_saldo_credito ON #saldo(credito_key, fecha_vencimiento, numero_cuota);

    INSERT #saldo (cuota_key,credito_key,numero_cuota,fecha_vencimiento,saldo)
    SELECT cuota_key, credito_key, numero_cuota, f.fecha, monto_cuota
    FROM dw.fact_cuota c
    JOIN dw.dim_fecha f ON f.fecha_key = c.fecha_vencimiento_key;

    DECLARE @pago_key BIGINT, @credito_key INT, @monto DECIMAL(14,2),
            @id_cuota VARCHAR(10), @fecha_key INT, @id_pago VARCHAR(10);
    DECLARE @restante DECIMAL(14,2), @aplicar DECIMAL(14,2), @saldo DECIMAL(14,2),
            @cuota_key BIGINT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.pago_key, p.credito_key, p.monto, p.id_cuota_origen, p.fecha_pago_key, p.id_pago
        FROM dw.fact_pago p
        ORDER BY p.credito_key, p.fecha_pago_key, p.id_pago;

    OPEN cur;
    FETCH NEXT FROM cur INTO @pago_key,@credito_key,@monto,@id_cuota,@fecha_key,@id_pago;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @restante = @monto;

        /* 1) Cuota indicada por el origen, si aun tiene saldo. */
        IF @id_cuota IS NOT NULL
        BEGIN
            SELECT @cuota_key = cuota_key, @saldo = saldo
            FROM #saldo WHERE cuota_key = (SELECT cuota_key FROM dw.fact_cuota WHERE id_cuota = @id_cuota);

            IF @cuota_key IS NOT NULL AND @saldo > 0
            BEGIN
                SET @aplicar = CASE WHEN @restante < @saldo THEN @restante ELSE @saldo END;
                INSERT dw.fact_aplicacion (pago_key,cuota_key,credito_key,fecha_pago_key,monto_aplicado)
                VALUES (@pago_key,@cuota_key,@credito_key,@fecha_key,@aplicar);
                UPDATE #saldo SET saldo = saldo - @aplicar WHERE cuota_key = @cuota_key;
                SET @restante = @restante - @aplicar;
            END
            SET @cuota_key = NULL;
        END

        /* 2) FIFO al resto de cuotas impagas del credito. */
        WHILE @restante > 0
        BEGIN
            SET @cuota_key = NULL;
            SELECT TOP (1) @cuota_key = cuota_key, @saldo = saldo
            FROM #saldo
            WHERE credito_key = @credito_key AND saldo > 0
            ORDER BY fecha_vencimiento, numero_cuota, cuota_key;

            IF @cuota_key IS NULL BREAK;

            SET @aplicar = CASE WHEN @restante < @saldo THEN @restante ELSE @saldo END;
            INSERT dw.fact_aplicacion (pago_key,cuota_key,credito_key,fecha_pago_key,monto_aplicado)
            VALUES (@pago_key,@cuota_key,@credito_key,@fecha_key,@aplicar);
            UPDATE #saldo SET saldo = saldo - @aplicar WHERE cuota_key = @cuota_key;
            SET @restante = @restante - @aplicar;
        END

        UPDATE dw.fact_pago
           SET monto_aplicado = @monto - @restante,
               monto_no_aplicado = @restante
         WHERE pago_key = @pago_key;

        FETCH NEXT FROM cur INTO @pago_key,@credito_key,@monto,@id_cuota,@fecha_key,@id_pago;
    END
    CLOSE cur;
    DEALLOCATE cur;

    DROP TABLE #saldo;
END
GO

/* Genera (o regenera) el snapshot de cartera/mora para una fecha de corte.
   Solo considera pagos con fecha_pago <= fecha de corte. */
CREATE OR ALTER PROCEDURE dw.usp_GenerarCorte
    @fecha_corte DATE,
    @id_ejecucion BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @corte_key INT = CONVERT(INT,CONVERT(CHAR(8),@fecha_corte,112));

    DELETE FROM dw.fact_cartera WHERE corte_key = @corte_key;

    ;WITH aplicado AS (
        SELECT a.cuota_key, SUM(a.monto_aplicado) AS aplicado
        FROM dw.fact_aplicacion a
        JOIN dw.fact_pago p ON p.pago_key = a.pago_key
        WHERE p.fecha_pago_key <= @corte_key
        GROUP BY a.cuota_key
    ),
    cuota AS (
        SELECT c.cuota_key, c.credito_key, c.numero_cuota, c.monto_cuota, c.monto_principal,
               f.fecha AS fecha_vencimiento,
               saldo = CASE WHEN c.monto_cuota - ISNULL(ap.aplicado,0) < 0 THEN 0
                            ELSE c.monto_cuota - ISNULL(ap.aplicado,0) END
        FROM dw.fact_cuota c
        JOIN dw.dim_fecha f ON f.fecha_key = c.fecha_vencimiento_key
        LEFT JOIN aplicado ap ON ap.cuota_key = c.cuota_key
    ),
    credito AS (
        SELECT cu.credito_key,
               saldo_total      = SUM(cu.saldo),
               saldo_principal  = SUM(CASE WHEN cu.monto_cuota > 0
                                           THEN cu.monto_principal * cu.saldo / cu.monto_cuota
                                           ELSE 0 END),
               monto_vencido    = SUM(CASE WHEN cu.fecha_vencimiento < @fecha_corte THEN cu.saldo ELSE 0 END),
               dias_mora_max    = MAX(CASE WHEN cu.fecha_vencimiento < @fecha_corte AND cu.saldo > 0
                                           THEN DATEDIFF(DAY, cu.fecha_vencimiento, @fecha_corte) ELSE 0 END),
               cuotas_total     = COUNT(*),
               cuotas_pagadas   = SUM(CASE WHEN cu.saldo <= 0 THEN 1 ELSE 0 END),
               cuotas_vencidas  = SUM(CASE WHEN cu.fecha_vencimiento < @fecha_corte AND cu.saldo > 0 THEN 1 ELSE 0 END)
        FROM cuota cu
        GROUP BY cu.credito_key
    )
    INSERT dw.fact_cartera (corte_key,credito_key,cliente_key,sucursal_key,producto_key,
                            saldo_total,saldo_principal,monto_vencido,monto_no_vencido,
                            dias_mora_max,tramo_mora,estado_credito,cuotas_total,cuotas_pagadas,cuotas_vencidas)
    SELECT @corte_key, cr.credito_key, dc.cliente_key, dc.sucursal_key, dc.producto_key,
           cr.saldo_total, cr.saldo_principal, cr.monto_vencido,
           cr.saldo_total - cr.monto_vencido,
           cr.dias_mora_max,
           CASE WHEN cr.dias_mora_max = 0 THEN 'AL_DIA'
                WHEN cr.dias_mora_max <= 30 THEN '1-30'
                WHEN cr.dias_mora_max <= 60 THEN '31-60'
                WHEN cr.dias_mora_max <= 90 THEN '61-90'
                ELSE '>90' END,
           dc.estado,
           cr.cuotas_total, cr.cuotas_pagadas, cr.cuotas_vencidas
    FROM credito cr
    JOIN dw.dim_credito dc ON dc.credito_key = cr.credito_key;
END
GO

/* =====================================================================
   INTEGRACION DE PAGOS EXTERNOS (STAGING -> HECHO)
   Los registros validos del extractor se promueven a fact_pago como
   pagos DIRECTOS (la API no trae id_cuota). La operacion es idempotente:
   una segunda ejecucion no inserta ni actualiza filas.
   Supuesto documentado: la API solo entrega fecha_pago, por lo que se
   usa la misma fecha como fecha_registro.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dw.usp_IntegrarPagosExternos
    @fecha_corte   DATE = NULL,
    @id_ejecucion  BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT dw.bitacora_ejecucion (proceso, fecha_inicio, estado, mensaje)
    VALUES ('INTEGRACION_API', SYSUTCDATETIME(), 'EN_PROCESO', 'Promocion de staging a fact_pago');
    SET @id_ejecucion = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dw.rechazos WHERE proceso = 'INTEGRACION_API';

        DECLARE @leidas INT = (SELECT COUNT(*) FROM dw.stg_pagos_externos);

        CREATE TABLE #validos (
            id_stg        BIGINT        NOT NULL PRIMARY KEY,
            referencia    VARCHAR(30)   COLLATE DATABASE_DEFAULT NOT NULL,
            credito_key   INT           NOT NULL,
            fecha_key     INT           NOT NULL,
            canal_key     INT           NOT NULL,
            monto         DECIMAL(14,2) NOT NULL,
            fecha_pago    DATE          NOT NULL
        );

        INSERT #validos (id_stg,referencia,credito_key,fecha_key,canal_key,monto,fecha_pago)
        SELECT s.id_stg, s.referencia, dc.credito_key, f.fecha_key, ca.canal_key, s.monto, s.fecha_pago
        FROM dw.stg_pagos_externos s
        JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
        JOIN dw.dim_canal   ca ON ca.canal     = s.canal
        JOIN dw.dim_fecha   f  ON f.fecha      = s.fecha_pago
        WHERE s.monto > 0;

        /* Rechazos de staging que no se pueden promover al hecho. */
        INSERT dw.rechazos (id_ejecucion,proceso,origen,referencia,motivo,detalle)
        SELECT @id_ejecucion, 'INTEGRACION_API', 'dw.stg_pagos_externos', s.referencia,
               CASE WHEN dc.credito_key IS NULL THEN 'CREDITO_INEXISTENTE'
                    WHEN ca.canal_key   IS NULL THEN 'CANAL_INEXISTENTE'
                    WHEN f.fecha_key    IS NULL THEN 'FECHA_INEXISTENTE'
                    WHEN s.monto <= 0           THEN 'MONTO_INVALIDO'
                    ELSE 'REGISTRO_INVALIDO' END,
               CONCAT('No se integro a fact_pago. credito=', ISNULL(s.id_credito,'NULL'),
                      ', canal=', ISNULL(s.canal,'NULL'),
                      ', fecha=', CONVERT(VARCHAR(10),s.fecha_pago,23),
                      ', monto=', s.monto)
        FROM dw.stg_pagos_externos s
        LEFT JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
        LEFT JOIN dw.dim_canal   ca ON ca.canal     = s.canal
        LEFT JOIN dw.dim_fecha   f  ON f.fecha      = s.fecha_pago
        WHERE dc.credito_key IS NULL OR ca.canal_key IS NULL
           OR f.fecha_key IS NULL OR s.monto <= 0;

        DECLARE @rechazadas INT = @@ROWCOUNT;

        /* Cambios reales sobre pagos API ya existentes, para historial. */
        SELECT v.referencia, p.monto AS monto_anterior, v.monto AS monto_nuevo,
               pf.fecha AS fecha_pago_anterior, v.fecha_pago AS fecha_pago_nueva
        INTO #cambios
        FROM #validos v
        JOIN dw.fact_pago p ON p.id_pago = v.referencia AND p.origen = 'API'
        JOIN dw.dim_fecha pf ON pf.fecha_key = p.fecha_pago_key
        WHERE p.credito_key <> v.credito_key
           OR p.fecha_pago_key <> v.fecha_key
           OR p.fecha_registro_key <> v.fecha_key
           OR p.canal_key <> v.canal_key
           OR p.monto <> v.monto;

        INSERT dw.historial_correcciones
            (id_ejecucion,id_pago,monto_anterior,monto_nuevo,
             fecha_pago_anterior,fecha_pago_nueva,detalle)
        SELECT @id_ejecucion, c.referencia, c.monto_anterior, c.monto_nuevo,
               c.fecha_pago_anterior, c.fecha_pago_nueva,
               'Correccion de pago proveniente de la API externa.'
        FROM #cambios c;

        DECLARE @acciones TABLE (accion NVARCHAR(10) NOT NULL);

        MERGE dw.fact_pago AS destino
        USING #validos AS origen
           ON destino.id_pago = origen.referencia
        WHEN MATCHED AND destino.origen = 'API'
             AND (destino.credito_key <> origen.credito_key
                  OR destino.fecha_pago_key <> origen.fecha_key
                  OR destino.fecha_registro_key <> origen.fecha_key
                  OR destino.canal_key <> origen.canal_key
                  OR destino.monto <> origen.monto)
        THEN UPDATE SET
             credito_key        = origen.credito_key,
             fecha_pago_key     = origen.fecha_key,
             fecha_registro_key = origen.fecha_key,
             canal_key          = origen.canal_key,
             monto              = origen.monto,
             tipo_pago          = 'DIRECTO',
             id_cuota_origen    = NULL,
             monto_aplicado     = 0,
             monto_no_aplicado  = origen.monto,
             origen             = 'API',
             es_correccion      = 1,
             fecha_carga        = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET
        THEN INSERT
             (id_pago,credito_key,fecha_pago_key,fecha_registro_key,canal_key,
              monto,tipo_pago,id_cuota_origen,monto_aplicado,monto_no_aplicado,
              origen,es_correccion,fecha_carga)
             VALUES
             (origen.referencia,origen.credito_key,origen.fecha_key,origen.fecha_key,
              origen.canal_key,origen.monto,'DIRECTO',NULL,0,origen.monto,
              'API',0,SYSUTCDATETIME())
        OUTPUT $action INTO @acciones (accion);

        DECLARE @insertadas INT = (SELECT COUNT(*) FROM @acciones WHERE accion = 'INSERT');
        DECLARE @actualizadas INT = (SELECT COUNT(*) FROM @acciones WHERE accion = 'UPDATE');
        DECLARE @omitidas INT = @leidas - @insertadas - @actualizadas - @rechazadas;

        DROP TABLE #validos;
        IF OBJECT_ID('tempdb..#cambios') IS NOT NULL DROP TABLE #cambios;

        /* Recalcular aplicaciones y regenerar el corte con los pagos API. */
        EXEC dw.usp_RecalcularAplicaciones;

        IF @fecha_corte IS NULL
            SET @fecha_corte = (SELECT MAX(fecha_pago) FROM dw.stg_pagos_externos);

        IF @fecha_corte IS NULL
            SET @fecha_corte = CAST(SYSUTCDATETIME() AS DATE);

        EXEC dw.usp_GenerarCorte @fecha_corte = @fecha_corte, @id_ejecucion = @id_ejecucion;

        UPDATE dw.bitacora_ejecucion
           SET fecha_fin = SYSUTCDATETIME(),
               filas_leidas = @leidas,
               filas_insertadas = @insertadas,
               filas_actualizadas = @actualizadas,
               filas_rechazadas = @rechazadas,
               filas_duplicadas = CASE WHEN @omitidas < 0 THEN 0 ELSE @omitidas END,
               estado = 'EXITOSO',
               mensaje = CONCAT('Corte ', @fecha_corte, ': ', @insertadas, ' insertadas, ',
                                @actualizadas, ' actualizadas, ', @rechazadas, ' rechazadas, ',
                                CASE WHEN @omitidas < 0 THEN 0 ELSE @omitidas END, ' omitidas.')
         WHERE id_ejecucion = @id_ejecucion;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        UPDATE dw.bitacora_ejecucion
           SET fecha_fin = SYSUTCDATETIME(), estado = 'FALLIDO', mensaje = ERROR_MESSAGE()
         WHERE id_ejecucion = @id_ejecucion;
        THROW;
    END CATCH
END
GO

/* =====================================================================
   VISTAS
   ===================================================================== */
CREATE VIEW dw.vw_mora_tramo_sucursal AS
SELECT fc.corte_key,
       f.fecha AS fecha_corte,
       ds.id_sucursal,
       ds.nombre AS sucursal,
       ds.provincia,
       fc.tramo_mora,
       COUNT(*) AS creditos,
       SUM(fc.monto_vencido) AS monto_vencido,
       SUM(fc.saldo_total)   AS saldo_total,
       SUM(fc.saldo_principal) AS saldo_principal
FROM dw.fact_cartera fc
JOIN dw.dim_sucursal ds ON ds.sucursal_key = fc.sucursal_key
JOIN dw.dim_fecha f     ON f.fecha_key = fc.corte_key
WHERE fc.monto_vencido > 0
GROUP BY fc.corte_key, f.fecha, ds.id_sucursal, ds.nombre, ds.provincia, fc.tramo_mora;
GO

CREATE VIEW dw.vw_bitacora_resumen AS
SELECT id_ejecucion, proceso, fecha_inicio, fecha_fin,
       DATEDIFF(SECOND, fecha_inicio, ISNULL(fecha_fin,SYSUTCDATETIME())) AS segundos,
       filas_leidas, filas_insertadas, filas_actualizadas, filas_rechazadas,
       filas_duplicadas, estado, mensaje
FROM dw.bitacora_ejecucion;
GO

PRINT '01_dw_ddl.sql completado.';
GO
