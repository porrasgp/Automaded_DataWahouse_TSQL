/* =====================================================================
   Prueba tecnica empresa - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   06_integrar_pagos_externos.sql
   Promueve los pagos validos de dw.stg_pagos_externos a dw.fact_pago.

   La logica vive en dw.usp_IntegrarPagosExternos (01_dw_ddl.sql).
   La operacion es idempotente: puede ejecutarse dos veces.
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('dw.stg_pagos_externos') IS NULL
    THROW 50000, 'Falta dw.stg_pagos_externos. Ejecute 01_dw_ddl.sql.', 1;

IF NOT EXISTS (SELECT 1 FROM dw.stg_pagos_externos)
BEGIN
    PRINT 'ADVERTENCIA: dw.stg_pagos_externos esta vacio. Ejecute python/extractor_pagos.py primero.';
END

DECLARE @id_ejecucion BIGINT;
EXEC dw.usp_IntegrarPagosExternos @fecha_corte = NULL, @id_ejecucion = @id_ejecucion OUTPUT;
GO

/* Ultima corrida de integracion. */
SELECT id_ejecucion, proceso, filas_leidas, filas_insertadas, filas_actualizadas,
       filas_rechazadas, filas_duplicadas, estado, mensaje
FROM dw.bitacora_ejecucion
WHERE proceso = 'INTEGRACION_API'
ORDER BY id_ejecucion DESC;
GO

/* Pagos API integrados y su aplicacion. */
SELECT COUNT(*) AS pagos_api,
       SUM(monto) AS monto_api,
       SUM(monto_aplicado) AS aplicado_api,
       SUM(monto_no_aplicado) AS no_aplicado_api
FROM dw.fact_pago
WHERE origen = 'API';
GO

/* Control de conciliacion global. */
SELECT (SELECT SUM(monto) FROM dw.fact_pago) AS monto_pagos,
       (SELECT SUM(monto_aplicado) FROM dw.fact_aplicacion) AS monto_aplicado,
       (SELECT SUM(monto_no_aplicado) FROM dw.fact_pago) AS monto_no_aplicado,
       (SELECT COUNT(*) FROM dw.fact_pago) AS filas_fact_pago;
GO
