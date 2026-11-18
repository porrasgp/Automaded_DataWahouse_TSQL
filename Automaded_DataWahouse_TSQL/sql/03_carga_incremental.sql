/* =====================================================================
   Prueba tecnica Instacredit - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   03_carga_incremental.sql
   Procedimiento almacenado de carga incremental de [DatosPrueba].src.pagos_incremental.

   - Pagos nuevos: INSERT.
   - Pagos tardios (fecha_pago anterior al corte): INSERT y recalculo FIFO.
   - Correcciones (mismo id_pago, datos distintos): UPDATE + historial.
   - Duplicados del lote o filas ya aplicadas: se omiten y se cuentan.
   - Filas con credito, cuota, canal o fecha invalida: se rechazan con motivo.
   - Idempotente: una segunda ejecucion no inserta ni actualiza nada.

   Ejecute este script una vez para la 1a corrida y otra vez para probar
   que la 2a corrida es idempotente.
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dw.usp_CargaIncrementalPagos
    @fecha_corte  DATE = NULL,
    @id_ejecucion BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT dw.bitacora_ejecucion (proceso, fecha_inicio, estado)
    VALUES ('CARGA_INCREMENTAL', SYSUTCDATETIME(), 'EN_PROCESO');
    SET @id_ejecucion = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;

        /* 1) Lote leido y deduplicacion determinista por id_pago. */
        SELECT s.*,
               ROW_NUMBER() OVER (
                   PARTITION BY s.id_pago
                   ORDER BY s.fecha_registro DESC, s.fecha_pago DESC, s.monto DESC
               ) AS rn
        INTO #stg
        FROM [DatosPrueba].src.pagos_incremental s;

        DECLARE @leidas INT = (SELECT COUNT(*) FROM [DatosPrueba].src.pagos_incremental);

        /* 2) Filas validas: existen dimensiones y la cuota pertenece al credito. */
        SELECT s.id_pago, s.id_credito, s.id_cuota, s.fecha_pago, s.monto, s.canal,
               s.fecha_registro, dc.credito_key, ca.canal_key,
               fp.fecha_key AS fecha_pago_key, fr.fecha_key AS fecha_registro_key,
               fc.cuota_key
        INTO #validos
        FROM #stg s
        JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
        JOIN dw.dim_canal   ca ON ca.canal     = s.canal
        JOIN dw.dim_fecha   fp ON fp.fecha      = s.fecha_pago
        JOIN dw.dim_fecha   fr ON fr.fecha      = s.fecha_registro
        LEFT JOIN dw.fact_cuota fc ON fc.id_cuota = s.id_cuota
        WHERE s.rn = 1
          AND s.monto > 0
          AND (s.id_cuota IS NULL OR (fc.cuota_key IS NOT NULL AND fc.credito_key = dc.credito_key));

        /* 3) Pagos nuevos (id_pago inexistente en el DW). */
        INSERT dw.fact_pago (id_pago,credito_key,fecha_pago_key,fecha_registro_key,canal_key,
                             monto,tipo_pago,id_cuota_origen,monto_aplicado,monto_no_aplicado,
                             origen,es_correccion)
        SELECT v.id_pago, v.credito_key, v.fecha_pago_key, v.fecha_registro_key,
               v.canal_key, v.monto,
               CASE WHEN v.id_cuota IS NULL THEN 'DIRECTO' ELSE 'CUOTA' END,
               v.id_cuota, 0, v.monto, 'INCREMENTAL', 0
        FROM #validos v
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_pago p WHERE p.id_pago = v.id_pago);

        DECLARE @insertadas INT = @@ROWCOUNT;

        /* 4) Correcciones: mismo id_pago con algun dato distinto. */
        SELECT v.id_pago, v.id_credito, v.id_cuota, v.fecha_pago, v.monto, v.canal,
               v.fecha_registro, v.credito_key, v.canal_key,
               v.fecha_pago_key, v.fecha_registro_key
        INTO #dif
        FROM #validos v
        JOIN dw.fact_pago p ON p.id_pago = v.id_pago
        WHERE p.credito_key <> v.credito_key
           OR ISNULL(p.id_cuota_origen,'') <> ISNULL(v.id_cuota,'')
           OR p.fecha_pago_key <> v.fecha_pago_key
           OR p.fecha_registro_key <> v.fecha_registro_key
           OR p.monto <> v.monto
           OR p.canal_key <> v.canal_key;

        INSERT dw.historial_correcciones (id_ejecucion,id_pago,monto_anterior,monto_nuevo,
                                          fecha_pago_anterior,fecha_pago_nueva,detalle)
        SELECT @id_ejecucion, d.id_pago, p.monto, d.monto,
               pf.fecha, d.fecha_pago,
               CONCAT('Correccion desde lote incremental. canal anterior=', pc.canal,
                      ', canal nuevo=', d.canal)
        FROM #dif d
        JOIN dw.fact_pago p ON p.id_pago = d.id_pago
        JOIN dw.dim_fecha pf ON pf.fecha_key = p.fecha_pago_key
        JOIN dw.dim_canal pc ON pc.canal_key = p.canal_key;

        UPDATE p
           SET p.credito_key        = d.credito_key,
               p.fecha_pago_key     = d.fecha_pago_key,
               p.fecha_registro_key = d.fecha_registro_key,
               p.canal_key          = d.canal_key,
               p.monto              = d.monto,
               p.tipo_pago          = CASE WHEN d.id_cuota IS NULL THEN 'DIRECTO' ELSE 'CUOTA' END,
               p.id_cuota_origen    = d.id_cuota,
               p.monto_aplicado     = 0,
               p.monto_no_aplicado  = d.monto,
               p.origen             = 'INCREMENTAL',
               p.es_correccion      = 1,
               p.fecha_carga        = SYSUTCDATETIME()
        FROM dw.fact_pago p
        JOIN #dif d ON d.id_pago = p.id_pago;

        DECLARE @actualizadas INT = @@ROWCOUNT;

        /* 5) Duplicados del lote y filas invalidas quedan trazados. */
        INSERT dw.rechazos (id_ejecucion,proceso,origen,referencia,motivo,detalle)
        SELECT @id_ejecucion, 'CARGA_INCREMENTAL', 'src.pagos_incremental', s.id_pago,
               'DUPLICADO_EXACTO',
               CONCAT('id_pago repetido en el lote; se conserva la fila con fecha_registro mas reciente. monto=', s.monto)
        FROM #stg s
        WHERE s.rn > 1;

        INSERT dw.rechazos (id_ejecucion,proceso,origen,referencia,motivo,detalle)
        SELECT @id_ejecucion, 'CARGA_INCREMENTAL', 'src.pagos_incremental', s.id_pago,
               CASE WHEN dc.credito_key IS NULL THEN 'CREDITO_INEXISTENTE'
                    WHEN ca.canal_key IS NULL THEN 'CANAL_INEXISTENTE'
                    WHEN fp.fecha_key IS NULL THEN 'FECHA_INEXISTENTE'
                    WHEN fr.fecha_key IS NULL THEN 'FECHA_REGISTRO_INEXISTENTE'
                    WHEN s.monto <= 0 THEN 'MONTO_INVALIDO'
                    WHEN s.id_cuota IS NOT NULL AND fc.cuota_key IS NULL THEN 'CUOTA_INEXISTENTE'
                    WHEN s.id_cuota IS NOT NULL AND fc.credito_key <> dc.credito_key THEN 'CUOTA_NO_CORRESPONDE'
                    ELSE 'REGISTRO_INVALIDO' END,
               CONCAT('Pago incremental no cargado. monto=', s.monto,
                      ', fecha_pago=', CONVERT(VARCHAR(10),s.fecha_pago,23),
                      ', canal=', s.canal)
        FROM #stg s
        LEFT JOIN dw.dim_credito dc ON dc.id_credito = s.id_credito
        LEFT JOIN dw.dim_canal   ca ON ca.canal     = s.canal
        LEFT JOIN dw.dim_fecha   fp ON fp.fecha      = s.fecha_pago
        LEFT JOIN dw.dim_fecha   fr ON fr.fecha      = s.fecha_registro
        LEFT JOIN dw.fact_cuota  fc ON fc.id_cuota   = s.id_cuota
        WHERE s.rn = 1
          AND NOT EXISTS (SELECT 1 FROM #validos v WHERE v.id_pago = s.id_pago);

        DECLARE @invalidas INT = @@ROWCOUNT;
        DECLARE @duplicadas INT = CASE
            WHEN @leidas - @insertadas - @actualizadas - @invalidas < 0 THEN 0
            ELSE @leidas - @insertadas - @actualizadas - @invalidas
        END;

        DROP TABLE #stg;
        DROP TABLE #validos;
        DROP TABLE #dif;

        /* 6) Recalcular aplicaciones por cambios y pagos tardios. */
        EXEC dw.usp_RecalcularAplicaciones;

        /* 7) Nuevo snapshot de cartera/mora. */
        IF @fecha_corte IS NULL
            SET @fecha_corte = (SELECT MAX(fecha_registro) FROM [DatosPrueba].src.pagos_incremental);

        EXEC dw.usp_GenerarCorte @fecha_corte = @fecha_corte, @id_ejecucion = @id_ejecucion;

        UPDATE dw.bitacora_ejecucion
           SET fecha_fin = SYSUTCDATETIME(),
               filas_leidas = @leidas,
               filas_insertadas = @insertadas,
               filas_actualizadas = @actualizadas,
               filas_rechazadas = @invalidas,
               filas_duplicadas = @duplicadas,
               estado = 'EXITOSO',
               mensaje = CONCAT('Corte ', @fecha_corte, ': ', @insertadas, ' insertadas, ',
                                @actualizadas, ' actualizadas, ', @invalidas, ' rechazadas, ',
                                @duplicadas, ' omitidas (duplicadas o ya aplicadas).')
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

/* ---------- Ejecucion del lote incremental ---------- */
DECLARE @id BIGINT;
EXEC dw.usp_CargaIncrementalPagos @fecha_corte = NULL, @id_ejecucion = @id OUTPUT;
GO

/* ---------- Resultado de la corrida ---------- */
SELECT id_ejecucion, proceso, filas_leidas, filas_insertadas, filas_actualizadas,
       filas_rechazadas, filas_duplicadas, estado, mensaje
FROM dw.bitacora_ejecucion
WHERE proceso = 'CARGA_INCREMENTAL'
ORDER BY id_ejecucion;
GO

/* ---------- Correcciones registradas ---------- */
SELECT id_correccion, id_pago, monto_anterior, monto_nuevo,
       fecha_pago_anterior, fecha_pago_nueva
FROM dw.historial_correcciones
ORDER BY id_correccion;
GO

/* ---------- Mora por tramo y sucursal: antes vs despues ---------- */
DECLARE @antes INT = 20261025;
DECLARE @despues INT = (SELECT MAX(corte_key) FROM dw.fact_cartera);

SELECT CASE WHEN v.corte_key = @antes THEN 'ANTES (2026-10-25)' ELSE 'DESPUES' END AS momento,
       v.corte_key, v.id_sucursal, v.sucursal, v.tramo_mora,
       v.creditos, v.monto_vencido, v.saldo_total, v.saldo_principal
FROM dw.vw_mora_tramo_sucursal v
WHERE v.corte_key IN (@antes, @despues)
ORDER BY v.corte_key, v.id_sucursal, v.tramo_mora;
GO
