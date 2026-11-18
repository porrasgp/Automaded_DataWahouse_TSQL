# Carpeta `python/tests/` — pruebas del validador

Aquí hay pruebas automáticas para `validators.py`, la pieza que limpia los pagos
de la API. Son pruebas **sin base de datos**: no necesitan SQL Server ni
conexión, solo Python.

## ¿Para qué sirven?

Cada vez que cambies las reglas de limpieza (por ejemplo, cómo se leen los
montos), estas pruebas te avisan en segundos si rompiste algo. Es como un
corrector ortográfico, pero para las reglas de negocio.

## Cómo ejecutarlas

Desde la carpeta `python/`:

```bash
python -m unittest discover -s tests -v
```

No necesitas instalar nada extra: usa `unittest`, que viene con Python.

## Qué comprueba cada prueba

### Clase `ParseTests` — reglas de un solo campo

| Prueba | Qué verifica, en palabras simples |
|---|---|
| `test_monto_con_separador_de_miles` | `"58,000.00"` se convierte en el número 58000.00. |
| `test_monto_negativo_rechazado` | Un monto negativo es un error. |
| `test_monto_nulo_rechazado` | Un monto vacío o `null` es un error. |
| `test_fecha_iso_y_dd_mm` | Se entienden las fechas `2026-10-27` y `27/10/2026`. |
| `test_fecha_invalida` | Una fecha imposible (mes 13) es un error. |
| `test_credito_normaliza_mayusculas_y_espacios` | ` cr-00093 ` se arregla y queda `CR-00093`. |
| `test_credito_inexistente` | Un crédito que no está en la lista válida se rechaza. |
| `test_estado_no_aplicado` | Solo el estado `APLICADO` pasa. |
| `test_registro_valido_normalizado` | Un registro correcto sale limpio y completo. |
| `test_hash_cambia_con_monto` | Si cambia el monto, cambia la "huella" del registro (así se detectan correcciones). |

### Clase `ProcessTests` — el lote completo

| Prueba | Qué verifica |
|---|---|
| `test_deduplica_referencias` | Si una referencia viene dos veces, se queda una y la otra se rechaza como duplicada. |
| `test_lote_real_113_validos_9_rechazados` | Con el JSON real: **113 válidos y 9 rechazados** (7 inválidos + 2 duplicados). |
| `test_dos_corridas_mismo_resultado` | Procesar el lote dos veces da exactamente lo mismo (idempotencia). |

## Importante: dos pruebas se omiten solas

Las dos últimas pruebas buscan los datos en `empresa/Paquete_datos_prueba_tecnica`,
una ruta que **no existe en este repositorio** (aquí la carpeta es
`data/Paquete_datos_prueba_tecnica`). Por eso, al ejecutar, verás:

```text
Ran 13 tests ... OK (skipped=2)
```

Las 11 restantes pasan. Para que las 2 omitidas también se ejecuten, cambia la
variable `PACKAGE_DIR` al inicio de `test_validators.py` para que apunte a
`PROJECT_ROOT / "data" / "Paquete_datos_prueba_tecnica"`.

> Se comprobó a mano que con la ruta correcta el resultado es 113 válidos y 9
> rechazados, tal como esperan las pruebas.
