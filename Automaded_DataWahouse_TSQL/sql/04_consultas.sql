/* =====================================================================
   Prueba tecnica empresa - Ingeniero de Datos
   Variante Windows / Azure SQL Database
   04_consultas.sql
   Consultas de negocio sobre el DW. Se usa el ultimo corte disponible.
   ===================================================================== */
SET NOCOUNT ON;
GO

DECLARE @corte INT = (SELECT MAX(corte_key) FROM dw.fact_cartera);
DECLARE @fecha_corte DATE = (SELECT fecha FROM dw.dim_fecha WHERE fecha_key = @corte);
PRINT CONCAT('Fecha de corte consultada: ', CONVERT(VARCHAR(10),@fecha_corte,23));

/* ---------------------------------------------------------------------
   1) Saldo de cartera por sucursal y producto al corte
   --------------------------------------------------------------------- */
SELECT ds.id_sucursal, ds.nombre AS sucursal, ds.provincia,
       dp.producto,
       COUNT(*)                          AS creditos,
       SUM(fc.saldo_total)               AS saldo_total,
       SUM(fc.saldo_principal)           AS saldo_principal,
       SUM(fc.monto_vencido)             AS monto_vencido
FROM dw.fact_cartera fc
JOIN dw.dim_sucursal ds ON ds.sucursal_key = fc.sucursal_key
JOIN dw.dim_producto dp ON dp.producto_key = fc.producto_key
WHERE fc.corte_key = @corte
GROUP BY ds.id_sucursal, ds.nombre, ds.provincia, dp.producto
ORDER BY ds.id_sucursal, dp.producto;

/* ---------------------------------------------------------------------
   2) Mora por tramo (1-30, 31-60, 61-90, >90) y sucursal al corte
      creditos = cantidad de creditos en ese tramo (peor atraso)
   --------------------------------------------------------------------- */
SELECT ds.id_sucursal, ds.nombre AS sucursal,
       SUM(CASE WHEN fc.tramo_mora='1-30'  THEN 1 ELSE 0 END) AS creditos_1_30,
       SUM(CASE WHEN fc.tramo_mora='31-60' THEN 1 ELSE 0 END) AS creditos_31_60,
       SUM(CASE WHEN fc.tramo_mora='61-90' THEN 1 ELSE 0 END) AS creditos_61_90,
       SUM(CASE WHEN fc.tramo_mora='>90'   THEN 1 ELSE 0 END) AS creditos_mas_90,
       SUM(CASE WHEN fc.tramo_mora='1-30'  THEN fc.monto_vencido ELSE 0 END) AS monto_1_30,
       SUM(CASE WHEN fc.tramo_mora='31-60' THEN fc.monto_vencido ELSE 0 END) AS monto_31_60,
       SUM(CASE WHEN fc.tramo_mora='61-90' THEN fc.monto_vencido ELSE 0 END) AS monto_61_90,
       SUM(CASE WHEN fc.tramo_mora='>90'   THEN fc.monto_vencido ELSE 0 END) AS monto_mas_90,
       SUM(fc.monto_vencido) AS monto_vencido_total
FROM dw.fact_cartera fc
JOIN dw.dim_sucursal ds ON ds.sucursal_key = fc.sucursal_key
WHERE fc.corte_key = @corte
  AND fc.monto_vencido > 0
GROUP BY ds.id_sucursal, ds.nombre
ORDER BY ds.id_sucursal;

/* ---------------------------------------------------------------------
   3) Mora consolidada por tramo (todas las sucursales)
   --------------------------------------------------------------------- */
SELECT fc.tramo_mora,
       COUNT(*)                    AS creditos,
       SUM(fc.monto_vencido)       AS monto_vencido,
       SUM(fc.saldo_total)         AS saldo_total
FROM dw.fact_cartera fc
WHERE fc.corte_key = @corte AND fc.monto_vencido > 0
GROUP BY fc.tramo_mora
ORDER BY CASE fc.tramo_mora WHEN '1-30' THEN 1 WHEN '31-60' THEN 2
                            WHEN '61-90' THEN 3 ELSE 4 END;

/* ---------------------------------------------------------------------
   4) Recuperacion mensual (pagos por mes de pago)
   --------------------------------------------------------------------- */
SELECT YEAR(f.fecha) AS anio, MONTH(f.fecha) AS mes,
       COUNT(*) AS pagos,
       SUM(p.monto) AS monto_recuperado,
       SUM(p.monto_aplicado) AS monto_aplicado,
       SUM(p.monto_no_aplicado) AS monto_no_aplicado
FROM dw.fact_pago p
JOIN dw.dim_fecha f ON f.fecha_key = p.fecha_pago_key
GROUP BY YEAR(f.fecha), MONTH(f.fecha)
ORDER BY anio, mes;

/* ---------------------------------------------------------------------
   5) Recuperacion por canal
   --------------------------------------------------------------------- */
SELECT dc.canal, dc.grupo,
       COUNT(*) AS pagos,
       SUM(p.monto) AS monto
FROM dw.fact_pago p
JOIN dw.dim_canal dc ON dc.canal_key = p.canal_key
GROUP BY dc.canal, dc.grupo
ORDER BY monto DESC;

/* ---------------------------------------------------------------------
   6) Pagos directos (sin cuota) y pagos con sobrante
   --------------------------------------------------------------------- */
SELECT p.tipo_pago,
       COUNT(*) AS pagos,
       SUM(p.monto) AS monto,
       SUM(p.monto_aplicado) AS aplicado,
       SUM(p.monto_no_aplicado) AS no_aplicado
FROM dw.fact_pago p
GROUP BY p.tipo_pago;

SELECT TOP (20) p.id_pago, p.id_cuota_origen, p.monto, p.monto_aplicado, p.monto_no_aplicado
FROM dw.fact_pago p
WHERE p.monto_no_aplicado > 0
ORDER BY p.monto_no_aplicado DESC;

/* ---------------------------------------------------------------------
   7) Comparacion del corte inicial vs el ultimo corte
   --------------------------------------------------------------------- */
SELECT fc.corte_key, f.fecha AS fecha_corte,
       COUNT(*) AS creditos,
       SUM(fc.saldo_total) AS saldo_total,
       SUM(fc.saldo_principal) AS saldo_principal,
       SUM(fc.monto_vencido) AS monto_vencido,
       SUM(CASE WHEN fc.monto_vencido > 0 THEN 1 ELSE 0 END) AS creditos_en_mora
FROM dw.fact_cartera fc
JOIN dw.dim_fecha f ON f.fecha_key = fc.corte_key
GROUP BY fc.corte_key, f.fecha
ORDER BY fc.corte_key;

/* ---------------------------------------------------------------------
   8) Misma consulta de mora por tramo ANTES y DESPUES del incremental
      (corte inicial 2026-10-25 vs corte nuevo 2026-10-27)
   --------------------------------------------------------------------- */
SELECT fc.corte_key, f.fecha AS fecha_corte, fc.tramo_mora,
       COUNT(*) AS creditos,
       SUM(fc.monto_vencido) AS monto_vencido
FROM dw.fact_cartera fc
JOIN dw.dim_fecha f ON f.fecha_key = fc.corte_key
WHERE fc.monto_vencido > 0
GROUP BY fc.corte_key, f.fecha, fc.tramo_mora
ORDER BY fc.corte_key,
         CASE fc.tramo_mora WHEN '1-30' THEN 1 WHEN '31-60' THEN 2
                            WHEN '61-90' THEN 3 ELSE 4 END;
GO
