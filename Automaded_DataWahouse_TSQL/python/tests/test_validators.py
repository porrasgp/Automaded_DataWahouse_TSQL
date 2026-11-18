from __future__ import annotations

import csv
import json
import sys
import unittest
from datetime import date
from decimal import Decimal
from pathlib import Path

PYTHON_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PYTHON_DIR))

from validators import (  # noqa: E402
    NormalizedPayment,
    parse_fecha,
    parse_monto,
    process_records,
    validate_record,
)

PROJECT_ROOT = PYTHON_DIR.parent
PACKAGE_DIR = PROJECT_ROOT / "Instacredit" / "Paquete_datos_prueba_tecnica"

VALID_CREDITS = {"CR-00012", "CR-00093", "CR-00154"}


def raw(**overrides):
    base = {
        "referencia": "EXT-260001",
        "credito": "CR-00093",
        "fecha_pago": "2026-10-27",
        "monto": "58,000.00",
        "moneda": "CRC",
        "canal": "BancoA",
        "estado": "APLICADO",
        "detalle": {"comercio": "Ventanilla", "hora": "20:12"},
    }
    base.update(overrides)
    return base


class ParseTests(unittest.TestCase):
    def test_monto_con_separador_de_miles(self):
        self.assertEqual(parse_monto("58,000.00"), Decimal("58000.00"))
        self.assertEqual(parse_monto("1,234,567.89"), Decimal("1234567.89"))
        self.assertEqual(parse_monto(15000), Decimal("15000.00"))

    def test_monto_negativo_rechazado(self):
        with self.assertRaises(ValueError):
            parse_monto("-15,000.00")

    def test_monto_nulo_rechazado(self):
        with self.assertRaises(ValueError):
            parse_monto(None)

    def test_fecha_iso_y_dd_mm(self):
        self.assertEqual(parse_fecha("2026-10-27"), date(2026, 10, 27))
        self.assertEqual(parse_fecha("26/10/2026"), date(2026, 10, 26))

    def test_fecha_invalida(self):
        with self.assertRaises(ValueError):
            parse_fecha("2026-13-01")

    def test_credito_normaliza_mayusculas_y_espacios(self):
        pago, errores, _ = validate_record(raw(credito=" cr-00012 "), VALID_CREDITS)
        self.assertEqual(errores, [])
        self.assertIsNotNone(pago)
        self.assertEqual(pago.credito, "CR-00012")

    def test_credito_inexistente(self):
        _, errores, _ = validate_record(raw(credito="CR-99999"), VALID_CREDITS)
        self.assertTrue(any("inexistente" in e for e in errores))

    def test_estado_no_aplicado(self):
        _, errores, _ = validate_record(raw(estado="REVERSADO"), VALID_CREDITS)
        self.assertTrue(any("no aplicable" in e for e in errores))

    def test_registro_valido_normalizado(self):
        pago, errores, _ = validate_record(raw(fecha_pago="26/10/2026"), VALID_CREDITS)
        self.assertEqual(errores, [])
        assert pago is not None
        self.assertIsInstance(pago, NormalizedPayment)
        self.assertEqual(pago.fecha_pago, date(2026, 10, 26))
        self.assertEqual(pago.monto, Decimal("58000.00"))
        self.assertEqual(pago.hash_registro(), pago.hash_registro())

    def test_hash_cambia_con_monto(self):
        p1, _, _ = validate_record(raw(monto="10,000.00"), VALID_CREDITS)
        p2, _, _ = validate_record(raw(monto="20,000.00"), VALID_CREDITS)
        assert p1 and p2
        self.assertNotEqual(p1.hash_registro(), p2.hash_registro())


class ProcessTests(unittest.TestCase):
    def test_deduplica_referencias(self):
        records = [raw(), raw(), raw()]
        validos, rechazos, _ = process_records(records, VALID_CREDITS)
        self.assertEqual(len(validos), 1)
        self.assertEqual(len(rechazos), 2)
        self.assertTrue(all(r.motivo == "DUPLICADO_REFERENCIA" for r in rechazos))

    @unittest.skipUnless(
        (PACKAGE_DIR / "api_pagos_externos.json").exists()
        and (PACKAGE_DIR / "creditos.csv").exists(),
        "Paquete de datos no disponible",
    )
    def test_lote_real_113_validos_9_rechazados(self):
        with open(PACKAGE_DIR / "creditos.csv", encoding="utf-8", newline="") as fh:
            creditos = {row["id_credito"] for row in csv.DictReader(fh)}
        payload = json.loads((PACKAGE_DIR / "api_pagos_externos.json").read_text(encoding="utf-8"))
        validos, rechazos, _ = process_records(payload["pagos"], creditos)
        self.assertEqual(len(validos), 113)
        self.assertEqual(len(rechazos), 9)
        self.assertEqual(sum(1 for r in rechazos if r.motivo == "DUPLICADO_REFERENCIA"), 2)
        self.assertEqual(sum(1 for r in rechazos if r.motivo == "REGISTRO_INVALIDO"), 7)

    @unittest.skipUnless((PACKAGE_DIR / "api_pagos_externos.json").exists(), "Paquete no disponible")
    def test_dos_corridas_mismo_resultado(self):
        payload = json.loads((PACKAGE_DIR / "api_pagos_externos.json").read_text(encoding="utf-8"))
        first = process_records(payload["pagos"], VALID_CREDITS | {"CR-00151", "CR-00243", "CR-00067"} | {
            f"CR-{i:05d}" for i in range(1, 481)
        })
        second = process_records(payload["pagos"], VALID_CREDITS | {"CR-00151", "CR-00243", "CR-00067"} | {
            f"CR-{i:05d}" for i in range(1, 481)
        })
        self.assertEqual(len(first[0]), len(second[0]))
        self.assertEqual(
            [p.hash_registro() for p in first[0]],
            [p.hash_registro() for p in second[0]],
        )


if __name__ == "__main__":
    unittest.main()
