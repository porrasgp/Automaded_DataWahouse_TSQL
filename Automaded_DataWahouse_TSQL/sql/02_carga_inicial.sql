/* =====================================================================
   Prueba tecnica empresa - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   02_carga_inicial.sql
   Carga inicial del DW desde src.* con fecha de corte 2026-10-25.

   Este script carga dimensiones y hechos. El DDL del DW se crea en
   01_dw_ddl.sql.

   Reglas:
     - Duplicados por id_pago: se conserva una fila y el resto va a
       dw.rechazos como DUPLICADO_EXACTO.
     - Pagos sin id_cuota: se cargan como DIRECTO y se aplican FIFO.
     - Pagos parciales / sobrepagos: se aplican a la cuota indicada y el
       remanente FIFO; el sobrante queda en monto_no_aplicado.
     - Pagos con credito, cuota, canal o fecha invalidos: se rechazan con
       motivo en dw.rechazos y no se cargan al hecho.
   Idempotente: limpia dimensiones y hechos y recarga el corte inicial.
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @fecha_corte DATE = '2026-10-25';
DECLARE @corte_key INT = CONVERT(INT,CONVERT(CHAR(8),@fecha_corte,112));
DECLARE @id_ejecucion BIGINT;

INSERT dw.bitacora_ejecucion (proceso, fecha_inicio, estado, mensaje)
VALUES ('CARGA_INICIAL', SYSUTCDATETIME(), 'EN_PROCESO', CONCAT('Corte ', @fecha_corte));
SET @id_ejecucion = SCOPE_IDENTITY();

BEGIN TRY
    BEGIN TRANSACTION;

    /* Limpieza de hechos y dimensiones (recarga completa e idempotente). */
    DELETE FROM dw.fact_aplicacion;
    DELETE FROM dw.fact_cartera;
    DELETE FROM dw.fact_pago;
    DELETE FROM dw.fact_cuota;
    DELETE FROM dw.dim_credito;
    DELETE FROM dw.dim_cliente;
    DELETE FROM dw.dim_sucursal;
    DELETE FROM dw.dim_producto;
    DELETE FROM dw.dim_canal;
    DELETE FROM dw.dim_fecha;
    DELETE FROM dw.rechazos WHERE proceso = 'CARGA_INICIAL';

    /* ---------- Dimensiones ---------- */
    ;WITH f AS (
        SELECT CONVERT(DATE,'2015-01-01') AS fecha
        UNION ALL
        SELECT DATEADD(DAY,1,fecha) FROM f WHERE fecha < '2035-12-31'
    )
    INSERT dw.dim_fecha (fecha_key,fecha,anio,mes,nombre_mes,trimestre,dia,dia_semana,nombre_dia,es_fin_semana,anio_mes)
    SELECT CONVERT(INT,CONVERT(CHAR(8),fecha,112)), fecha,
           YEAR(fecha), MONTH(fecha), DATENAME(MONTH,fecha), DATEPART(QUARTER,fecha),
           DAY(fecha), ((DATEPART(WEEKDAY,fecha)+@@DATEFIRST-2)%7)+1,
           DATENAME(WEEKDAY,fecha),
           CASE WHEN ((DATEPART(WEEKDAY,fecha)+@@DATEFIRST-2)%7)+1 >= 6 THEN 1 ELSE 0 END,
           CONVERT(CHAR(7),fecha,126)
    FROM f
    OPTION (MAXRECURSION 0);

    INSERT dw.dim_sucursal (id_sucursal,nombre,provincia)
    SELECT id_sucursal,nombre,provincia FROM [DatosPrueba].src.sucursales;

    INSERT dw.dim_cliente (id_cliente,nombre_completo,fecha_nacimiento,provincia,segmento,fecha_alta,ingreso_mensual)
    SELECT id_cliente,nombre_completo,fecha_nacimiento,provincia,segmento,fecha_alta,ingreso_mensual FROM [DatosPrueba].src.clientes;

    INSERT dw.dim_producto (producto)
    SELECT DISTINCT producto FROM [DatosPrueba].src.creditos;

    INSERT dw.dim_canal (canal,grupo)
    SELECT DISTINCT canal,
           CASE WHEN canal IN ('Sucursal') THEN 'Fisico'
                WHEN canal IN ('App') THEN 'Digital'
                WHEN canal IN ('Banco','Conectividad') THEN 'Bancario'
                WHEN canal IN ('BancoA','BancoB') THEN 'Externo'
                WHEN canal IN ('Pago Móvil') THEN 'Digital'
                ELSE 'Otro' END
    FROM (
        SELECT canal FROM [DatosPrueba].src.pagos
        UNION SELECT canal FROM [DatosPrueba].src.pagos_incremental
        UNION SELECT 'BancoA' UNION SELECT 'BancoB' UNION SELECT 'Pago Móvil'
    ) c;

    INSERT dw.dim_credito (id_credito,cliente_key,sucursal_key,producto_key,fecha_desembolso_key,
                           monto_desembolsado,tasa_anual,plazo_meses,cuota_mensual,estado)
    SELECT cr.id_credito, cl.cliente_key, su.sucursal_key, pr.producto_key,
           CONVERT(INT,CONVERT(CHAR(8),cr.fecha_desembolso,112)),
           cr.monto_desembolsado, cr.tasa_anual, cr.plazo_meses, cr.cuota_mensual, cr.estado
    FROM [DatosPrueba].src.creditos cr
    JOIN dw.dim_cliente  cl ON cl.id_cliente   = cr.id_cliente
    JOIN dw.dim_sucursal su ON su.id_sucursal  = cr.id_sucursal
    JOIN dw.dim_producto pr ON pr.producto     = cr.producto;

    /* ---------- fact_cuota ---------- */
    INSERT dw.fact_cuota (id_cuota,credito_key,numero_cuota,fecha_vencimiento_key,
                          monto_cuota,monto_principal,monto_interes)
    SELECT c.id_cuota, dc.credito_key, c.numero_cuota,
           CONVERT(INT,CONVERT(CHAR(8),c.fecha_vencimiento,112)),
           c.monto_cuota, c.monto_principal, c.monto_interes
    FROM [DatosPrueba].src.cuotas c
    JOIN dw.dim_credito dc ON dc.id_credito = c.id_credito;

    /* ---------- fact_pago: deduplicacion y validacion ---------- */
    SELECT p.*, ROW_NUMBER() OVER (
               PARTITION BY p.id_pago
               ORDER BY p.fecha_registro DESC, p.fecha_pago DESC, p.monto DESC
           ) AS rn
    INTO #pagos
    FROM [DatosPrueba].src.pagos p;

    SELECT s.id_pago, s.id_credito, s.id_cuota, s.fecha_pago, s.monto, s.canal,
           s.fecha_registro, dc.credito_key, ca.canal_key,
           fp.fecha_key AS fecha_pago_key, fr.fecha_key AS fecha_registro_key,
           fc.cuota_key
    INTO #pagos_validos
    FROM #pagos s
    JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
    JOIN dw.dim_canal   ca ON ca.canal     = s.canal
    JOIN dw.dim_fecha   fp ON fp.fecha      = s.fecha_pago
    JOIN dw.dim_fecha   fr ON fr.fecha      = s.fecha_registro
    LEFT JOIN dw.fact_cuota fc ON fc.id_cuota = s.id_cuota
    WHERE s.rn = 1
      AND s.monto > 0
      AND (s.id_cuota IS NULL OR (fc.cuota_key IS NOT NULL AND fc.credito_key = dc.credito_key));

    INSERT dw.fact_pago (id_pago,credito_key,fecha_pago_key,fecha_registro_key,canal_key,
                         monto,tipo_pago,id_cuota_origen,monto_aplicado,monto_no_aplicado,
                         origen,es_correccion)
    SELECT s.id_pago, s.credito_key, s.fecha_pago_key, s.fecha_registro_key,
           s.canal_key, s.monto,
           CASE WHEN s.id_cuota IS NULL THEN 'DIRECTO' ELSE 'CUOTA' END,
           s.id_cuota, 0, s.monto, 'INICIAL', 0
    FROM #pagos_validos s;

    DECLARE @leidas INT = (SELECT COUNT(*) FROM [DatosPrueba].src.pagos);
    DECLARE @insertadas INT = (SELECT COUNT(*) FROM #pagos_validos);
    DECLARE @duplicadas INT = (SELECT COUNT(*) FROM #pagos WHERE rn > 1);

    INSERT dw.rechazos (id_ejecucion,proceso,origen,referencia,motivo,detalle)
    SELECT @id_ejecucion, 'CARGA_INICIAL', 'src.pagos', s.id_pago,
           CASE WHEN s.rn > 1 THEN 'DUPLICADO_EXACTO'
                WHEN dc.credito_key IS NULL THEN 'CREDITO_INEXISTENTE'
                WHEN ca.canal_key IS NULL THEN 'CANAL_INEXISTENTE'
                WHEN fp.fecha_key IS NULL THEN 'FECHA_INEXISTENTE'
                WHEN fr.fecha_key IS NULL THEN 'FECHA_REGISTRO_INEXISTENTE'
                WHEN s.monto <= 0 THEN 'MONTO_INVALIDO'
                WHEN s.id_cuota IS NOT NULL AND fc.cuota_key IS NULL THEN 'CUOTA_INEXISTENTE'
                WHEN s.id_cuota IS NOT NULL AND fc.credito_key <> dc.credito_key THEN 'CUOTA_NO_CORRESPONDE'
                ELSE 'REGISTRO_INVALIDO' END,
           CONCAT('Pago no cargado a fact_pago. monto=', s.monto,
                  ', fecha_pago=', CONVERT(VARCHAR(10),s.fecha_pago,23),
                  ', canal=', s.canal)
    FROM #pagos s
    LEFT JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
    LEFT JOIN dw.dim_canal   ca ON ca.canal     = s.canal
    LEFT JOIN dw.dim_fecha   fp ON fp.fecha      = s.fecha_pago
    LEFT JOIN dw.dim_fecha   fr ON fr.fecha      = s.fecha_registro
    LEFT JOIN dw.fact_cuota  fc ON fc.id_cuota   = s.id_cuota
    WHERE s.rn > 1
       OR dc.credito_key IS NULL
       OR ca.canal_key IS NULL
       OR fp.fecha_key IS NULL
       OR fr.fecha_key IS NULL
       OR s.monto <= 0
       OR (s.id_cuota IS NOT NULL AND (fc.cuota_key IS NULL OR fc.credito_key <> dc.credito_key));

    DECLARE @rechazadas INT = (SELECT COUNT(*) FROM dw.rechazos WHERE id_ejecucion = @id_ejecucion);

    DROP TABLE #pagos;
    DROP TABLE #pagos_validos;

    /* ---------- Aplicaciones y snapshot de cartera ---------- */
    EXEC dw.usp_RecalcularAplicaciones;
    EXEC dw.usp_GenerarCorte @fecha_corte = @fecha_corte, @id_ejecucion = @id_ejecucion;

    UPDATE dw.bitacora_ejecucion
       SET fecha_fin = SYSUTCDATETIME(),
           filas_leidas = @leidas,
           filas_insertadas = @insertadas,
           filas_actualizadas = 0,
           filas_rechazadas = @rechazadas,
           filas_duplicadas = @duplicadas,
           estado = 'EXITOSO',
           mensaje = CONCAT('Corte ', @fecha_corte, ': ', @insertadas, ' pagos unicos, ',
                            @rechazadas, ' rechazados (', @duplicadas, ' duplicados).')
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
GO

/* ---------- Resumen de la carga inicial ---------- */
SELECT 'dim_credito' AS objeto, COUNT(*) AS filas FROM dw.dim_credito UNION ALL
SELECT 'fact_cuota',        COUNT(*) FROM dw.fact_cuota        UNION ALL
SELECT 'fact_pago',         COUNT(*) FROM dw.fact_pago         UNION ALL
SELECT 'fact_aplicacion',   COUNT(*) FROM dw.fact_aplicacion   UNION ALL
SELECT 'fact_cartera',      COUNT(*) FROM dw.fact_cartera      UNION ALL
SELECT 'rechazos',          COUNT(*) FROM dw.rechazos WHERE proceso='CARGA_INICIAL';

SELECT 'pagos_sin_cuota' AS metrica, COUNT(*) AS valor FROM dw.fact_pago WHERE tipo_pago='DIRECTO'
UNION ALL
SELECT 'pagos_parciales', COUNT(*) FROM dw.fact_pago p JOIN dw.fact_cuota c ON c.id_cuota = p.id_cuota_origen WHERE p.monto < c.monto_cuota
UNION ALL
SELECT 'pagos_con_sobrante', COUNT(*) FROM dw.fact_pago WHERE monto_no_aplicado > 0
UNION ALL
SELECT 'monto_no_aplicado', CAST(SUM(monto_no_aplicado) AS DECIMAL(18,2)) FROM dw.fact_pago;

SELECT * FROM dw.vw_bitacora_resumen WHERE proceso='CARGA_INICIAL';
GO
