/* =====================================================================
   Prueba tecnica empresa - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   05_validaciones.sql
   Validaciones automaticas del DW, la carga incremental y el extractor.
   Si alguna validacion critica falla, lanza error (THROW).
   ===================================================================== */
SET NOCOUNT ON;
GO

CREATE TABLE #val (
    orden       INT           NOT NULL,
    validacion  VARCHAR(120)  NOT NULL,
    esperado    VARCHAR(60)   NOT NULL,
    obtenido    VARCHAR(60)   NOT NULL,
    resultado   VARCHAR(10)   NOT NULL,
    critica     BIT           NOT NULL
);

DECLARE @v INT, @e VARCHAR(60), @c BIT;
DECLARE @integracion_api BIT = CASE
    WHEN EXISTS (SELECT 1 FROM dw.bitacora_ejecucion
                 WHERE proceso='INTEGRACION_API' AND estado='EXITOSO') THEN 1 ELSE 0 END;
DECLARE @esperado_pago INT = 7559 + CASE WHEN @integracion_api = 1 THEN 113 ELSE 0 END;

/* ---------- Conteos de origen ---------- */
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.sucursales);            SET @e='10';    SET @c=1; INSERT #val VALUES (1,'src.sucursales',@e,CAST(@v AS VARCHAR),CASE WHEN @v=10 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.clientes);              SET @e='300';   SET @c=1; INSERT #val VALUES (2,'src.clientes',@e,CAST(@v AS VARCHAR),CASE WHEN @v=300 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.creditos);              SET @e='480';   SET @c=1; INSERT #val VALUES (3,'src.creditos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=480 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.cuotas);                SET @e='13485'; SET @c=1; INSERT #val VALUES (4,'src.cuotas',@e,CAST(@v AS VARCHAR),CASE WHEN @v=13485 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.pagos);                 SET @e='7518';  SET @c=1; INSERT #val VALUES (5,'src.pagos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=7518 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(DISTINCT id_pago) FROM [DatosPrueba].src.pagos);  SET @e='7513';  SET @c=1; INSERT #val VALUES (6,'src.pagos id_pago unicos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=7513 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.pagos WHERE id_cuota IS NULL); SET @e='91'; SET @c=1; INSERT #val VALUES (7,'src.pagos sin id_cuota',@e,CAST(@v AS VARCHAR),CASE WHEN @v=91 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.pagos_incremental);     SET @e='53';    SET @c=1; INSERT #val VALUES (8,'src.pagos_incremental',@e,CAST(@v AS VARCHAR),CASE WHEN @v=53 THEN 'OK' ELSE 'FALLO' END,@c);

/* ---------- Modelo y carga inicial ---------- */
SET @v=(SELECT COUNT(*) FROM dw.dim_credito);            SET @e='480';   SET @c=1; INSERT #val VALUES (10,'dw.dim_credito',@e,CAST(@v AS VARCHAR),CASE WHEN @v=480 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.fact_cuota);             SET @e='13485'; SET @c=1; INSERT #val VALUES (11,'dw.fact_cuota',@e,CAST(@v AS VARCHAR),CASE WHEN @v=13485 THEN 'OK' ELSE 'FALLO' END,@c);

SET @v=(SELECT COUNT(*) FROM (
            SELECT id_pago FROM [DatosPrueba].src.pagos
            UNION SELECT id_pago FROM [DatosPrueba].src.pagos_incremental
            UNION SELECT referencia FROM dw.stg_pagos_externos WHERE @integracion_api = 1
        ) x);
SET @e=CAST(@esperado_pago AS VARCHAR); SET @c=1;
INSERT #val VALUES (12,'dw.fact_pago id_pago esperados (7513+46+API)',@e,CAST(@v AS VARCHAR),CASE WHEN @v=@esperado_pago THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.fact_pago); SET @e=CAST(@esperado_pago AS VARCHAR); SET @c=1;
INSERT #val VALUES (13,'dw.fact_pago filas (con API si aplica)',@e,CAST(@v AS VARCHAR),CASE WHEN @v=@esperado_pago THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(DISTINCT id_pago) FROM dw.fact_pago); SET @e=CAST(@esperado_pago AS VARCHAR); SET @c=1;
INSERT #val VALUES (14,'dw.fact_pago sin duplicados',@e,CAST(@v AS VARCHAR),CASE WHEN @v=@esperado_pago THEN 'OK' ELSE 'FALLO' END,@c);

SET @v=(SELECT COUNT(*) FROM [DatosPrueba].src.pagos p WHERE NOT EXISTS (SELECT 1 FROM dw.fact_pago f WHERE f.id_pago=p.id_pago));
SET @e='0'; SET @c=1; INSERT #val VALUES (15,'pagos de [DatosPrueba].src.pagos no cargados',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM (SELECT DISTINCT id_pago FROM [DatosPrueba].src.pagos_incremental) i WHERE NOT EXISTS (SELECT 1 FROM dw.fact_pago f WHERE f.id_pago=i.id_pago));
SET @e='0'; SET @c=1; INSERT #val VALUES (16,'id_pago incremental no cargados',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

SET @v=(SELECT COUNT(*) FROM dw.rechazos WHERE proceso='CARGA_INICIAL' AND motivo='DUPLICADO_EXACTO');
SET @e='5'; SET @c=1; INSERT #val VALUES (17,'rechazos duplicados carga inicial',@e,CAST(@v AS VARCHAR),CASE WHEN @v=5 THEN 'OK' ELSE 'FALLO' END,@c);

SET @v=(SELECT COUNT(*) FROM dw.fact_aplicacion a JOIN dw.fact_cuota c ON c.cuota_key=a.cuota_key WHERE a.credito_key<>c.credito_key);
SET @e='0'; SET @c=1; INSERT #val VALUES (18,'aplicaciones con credito/cuota inconsistente',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

SET @v=(SELECT COUNT(*) FROM dw.fact_aplicacion a JOIN dw.fact_cuota c ON c.cuota_key=a.cuota_key
        WHERE a.monto_aplicado > c.monto_cuota + 0.01);
SET @e='0'; SET @c=1; INSERT #val VALUES (19,'cuotas sobre-aplicadas',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

DECLARE @sum_pagos DECIMAL(18,2) = (SELECT SUM(monto) FROM dw.fact_pago);
DECLARE @sum_aplic  DECIMAL(18,2) = (SELECT SUM(monto_aplicado) FROM dw.fact_aplicacion);
DECLARE @sum_noapl  DECIMAL(18,2) = (SELECT SUM(monto_no_aplicado) FROM dw.fact_pago);
SET @v = CASE WHEN ABS(@sum_pagos - (@sum_aplic + @sum_noapl)) < 0.01 THEN 0 ELSE 1 END;
SET @e='0'; SET @c=1; INSERT #val VALUES (20,'conciliacion monto pagos = aplicado + no aplicado',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

/* ---------- Cartera / mora ---------- */
SET @v=(SELECT COUNT(*) FROM dw.fact_cartera WHERE corte_key=20261025); SET @e='480'; SET @c=1;
INSERT #val VALUES (21,'dw.fact_cartera corte 2026-10-25',@e,CAST(@v AS VARCHAR),CASE WHEN @v=480 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.fact_cartera WHERE corte_key=20261027); SET @e='480'; SET @c=1;
INSERT #val VALUES (22,'dw.fact_cartera corte 2026-10-27',@e,CAST(@v AS VARCHAR),CASE WHEN @v=480 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.fact_cartera WHERE saldo_total < 0 OR monto_vencido < 0); SET @e='0'; SET @c=1;
INSERT #val VALUES (23,'cartera con saldos negativos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.fact_cartera WHERE tramo_mora='AL_DIA' AND dias_mora_max > 0); SET @e='0'; SET @c=1;
INSERT #val VALUES (24,'tramo AL_DIA con dias de mora',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

/* ---------- Historia / encoding ---------- */
SET @v=(SELECT COUNT(*) FROM dw.dim_cliente WHERE nombre_completo LIKE '%Ã%' OR provincia LIKE '%Ã%' OR provincia LIKE '%├%'); SET @e='0'; SET @c=1;
INSERT #val VALUES (25,'mojibake en nombres/provincias',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.dim_cliente WHERE provincia='Limón'); SET @e='>0'; SET @c=1;
INSERT #val VALUES (26,'provincia Limón bien codificada',@e,CAST(@v AS VARCHAR),CASE WHEN @v>0 THEN 'OK' ELSE 'FALLO' END,@c);

/* ---------- Incremental ---------- */
SET @v=(SELECT COUNT(*) FROM dw.bitacora_ejecucion WHERE proceso='CARGA_INCREMENTAL' AND estado='EXITOSO');
SET @e='>=1'; SET @c=1; INSERT #val VALUES (30,'corridas incrementales exitosas',@e,CAST(@v AS VARCHAR),CASE WHEN @v>=1 THEN 'OK' ELSE 'FALLO' END,@c);
SET @v=(SELECT COUNT(*) FROM dw.historial_correcciones); SET @e='4'; SET @c=1;
INSERT #val VALUES (31,'correcciones registradas',@e,CAST(@v AS VARCHAR),CASE WHEN @v=4 THEN 'OK' ELSE 'FALLO' END,@c);

DECLARE @corridas_inc INT = (SELECT COUNT(*) FROM dw.bitacora_ejecucion
                             WHERE proceso='CARGA_INCREMENTAL' AND estado='EXITOSO');
;WITH ult AS (
    SELECT TOP (1) * FROM dw.bitacora_ejecucion
    WHERE proceso='CARGA_INCREMENTAL' AND estado='EXITOSO'
    ORDER BY id_ejecucion DESC
)
SELECT @v = CASE
              WHEN @corridas_inc >= 2
                   AND filas_insertadas=0 AND filas_actualizadas=0 AND filas_duplicadas=53 THEN 0
              WHEN @corridas_inc = 1
                   AND filas_insertadas=46 AND filas_actualizadas=4 AND filas_duplicadas=3 THEN 0
              ELSE 1
            END
FROM ult;
SET @e = CASE WHEN @corridas_inc >= 2 THEN '0 insertadas / 0 actualizadas / 53 omitidas'
              ELSE '46 insertadas / 4 actualizadas / 3 omitidas' END;
SET @c=1;
INSERT #val VALUES (32,'ultima corrida incremental idempotente',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

/* ---------- Extractor API e integracion a fact_pago ---------- */
IF OBJECT_ID('dw.stg_pagos_externos') IS NOT NULL AND EXISTS (SELECT 1 FROM dw.stg_pagos_externos)
BEGIN
    SET @v=(SELECT COUNT(*) FROM dw.stg_pagos_externos); SET @e='113'; SET @c=1;
    INSERT #val VALUES (40,'stg_pagos_externos (validos)',@e,CAST(@v AS VARCHAR),CASE WHEN @v=113 THEN 'OK' ELSE 'FALLO' END,@c);
    SET @v=(SELECT COUNT(*) FROM dw.stg_pagos_externos WHERE monto<=0 OR id_credito IS NULL); SET @e='0'; SET @c=1;
    INSERT #val VALUES (41,'stg_pagos_externos invalidos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);
    SET @v=(SELECT COUNT(*) FROM dw.rechazos WHERE proceso='EXTRACTOR_API'); SET @e='9'; SET @c=1;
    INSERT #val VALUES (42,'rechazos extractor API',@e,CAST(@v AS VARCHAR),CASE WHEN @v=9 THEN 'OK' ELSE 'FALLO' END,@c);
    SET @v=(SELECT COUNT(DISTINCT id_credito) FROM dw.stg_pagos_externos
            WHERE id_credito NOT IN (SELECT id_credito FROM dw.dim_credito)); SET @e='0'; SET @c=1;
    INSERT #val VALUES (43,'staging con creditos inexistentes',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

    IF EXISTS (SELECT 1 FROM dw.bitacora_ejecucion WHERE proceso='INTEGRACION_API')
    BEGIN
        SET @v=(SELECT COUNT(*) FROM dw.fact_pago WHERE origen='API'); SET @e='113'; SET @c=1;
        INSERT #val VALUES (44,'fact_pago pagos API integrados',@e,CAST(@v AS VARCHAR),CASE WHEN @v=113 THEN 'OK' ELSE 'FALLO' END,@c);

        SET @v=(SELECT COUNT(*) FROM dw.stg_pagos_externos s
                WHERE NOT EXISTS (SELECT 1 FROM dw.fact_pago f
                                  WHERE f.id_pago = s.referencia AND f.origen='API'));
        SET @e='0'; SET @c=1;
        INSERT #val VALUES (45,'staging API sin fila en fact_pago',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

        SET @v=(SELECT COUNT(*) FROM dw.bitacora_ejecucion
                WHERE proceso='INTEGRACION_API' AND estado='EXITOSO'); SET @e='>=1'; SET @c=1;
        INSERT #val VALUES (46,'corridas de integracion API exitosas',@e,CAST(@v AS VARCHAR),CASE WHEN @v>=1 THEN 'OK' ELSE 'FALLO' END,@c);

        DECLARE @corridas_api INT = (SELECT COUNT(*) FROM dw.bitacora_ejecucion
                                     WHERE proceso='INTEGRACION_API' AND estado='EXITOSO');
        ;WITH ult_api AS (
            SELECT TOP (1) * FROM dw.bitacora_ejecucion
            WHERE proceso='INTEGRACION_API' AND estado='EXITOSO'
            ORDER BY id_ejecucion DESC
        )
        SELECT @v = CASE
                      WHEN @corridas_api >= 2
                           AND filas_insertadas=0 AND filas_actualizadas=0 AND filas_duplicadas=113 THEN 0
                      WHEN @corridas_api = 1
                           AND filas_insertadas=113 AND filas_actualizadas=0 THEN 0
                      ELSE 1
                    END
        FROM ult_api;
        SET @e = CASE WHEN @corridas_api >= 2 THEN '0 insertadas / 0 actualizadas / 113 omitidas'
                      ELSE '113 insertadas / 0 actualizadas' END;
        SET @c=1;
        INSERT #val VALUES (47,'ultima integracion API idempotente',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);

        SET @v=(SELECT COUNT(*) FROM dw.fact_pago WHERE origen='API' AND (monto<=0 OR monto_no_aplicado<0));
        SET @e='0'; SET @c=1;
        INSERT #val VALUES (48,'pagos API con montos invalidos',@e,CAST(@v AS VARCHAR),CASE WHEN @v=0 THEN 'OK' ELSE 'FALLO' END,@c);
    END
    ELSE
    BEGIN
        INSERT #val VALUES (44,'fact_pago pagos API integrados','113','PENDIENTE','PENDIENTE',0);
        INSERT #val VALUES (45,'staging API sin fila en fact_pago','0','PENDIENTE','PENDIENTE',0);
        INSERT #val VALUES (46,'corridas de integracion API exitosas','>=1','PENDIENTE','PENDIENTE',0);
        INSERT #val VALUES (47,'ultima integracion API idempotente','0/0/113','PENDIENTE','PENDIENTE',0);
        INSERT #val VALUES (48,'pagos API con montos invalidos','0','PENDIENTE','PENDIENTE',0);
    END
END
ELSE
BEGIN
    INSERT #val VALUES (40,'stg_pagos_externos (validos)','113','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (42,'rechazos extractor API','9','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (44,'fact_pago pagos API integrados','113','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (45,'staging API sin fila en fact_pago','0','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (46,'corridas de integracion API exitosas','>=1','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (47,'ultima integracion API idempotente','0/0/113','PENDIENTE','PENDIENTE',0);
    INSERT #val VALUES (48,'pagos API con montos invalidos','0','PENDIENTE','PENDIENTE',0);
END

/* ---------- Resultado ---------- */
SELECT orden, validacion, esperado, obtenido, resultado
FROM #val
ORDER BY orden;

IF EXISTS (SELECT 1 FROM #val WHERE critica=1 AND resultado='FALLO')
    THROW 50000, 'VALIDACION FALLIDA: revise el detalle de 05_validaciones.sql', 1;

SELECT COUNT(*) AS validaciones, SUM(CASE WHEN resultado='OK' THEN 1 ELSE 0 END) AS ok,
       SUM(CASE WHEN resultado='FALLO' THEN 1 ELSE 0 END) AS fallos,
       SUM(CASE WHEN resultado='PENDIENTE' THEN 1 ELSE 0 END) AS pendientes
FROM #val;

DROP TABLE #val;
GO
