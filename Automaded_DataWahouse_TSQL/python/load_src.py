#!/usr/bin/env python3
"""Carga los CSV del paquete en las tablas src.* de la base origen (DatosPrueba).

Uso:
    python load_src.py
    python load_src.py --data-dir "C:/Users/Admin/Downloads/empresa/Paquete_datos_prueba_tecnica/"

Requisitos:
    - Haber ejecutado sql/00_cargar_origen.sql en la base destino.
    - ODBC Driver 18 for SQL Server y pyodbc instalados.
    - Configuracion en .env o variables de entorno.

La carga es idempotente: limpia src.* y vuelve a insertar los seis CSV.
"""
from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import replace
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import Iterable, Sequence

import db
from config import Config

TABLAS_BORRADO = [
    "src.pagos_incremental",
    "src.pagos",
    "src.cuotas",
    "src.creditos",
    "src.clientes",
    "src.sucursales",
]


def _text(value: str | None) -> str | None:
    value = (value or "").strip()
    return value or None


def _int(value: str | None) -> int:
    return int((value or "").strip())


def _dec(value: str | None) -> Decimal | None:
    value = (value or "").strip()
    return Decimal(value) if value else None


def _date(value: str | None) -> date | None:
    value = (value or "").strip()
    return date.fromisoformat(value) if value else None


def _rows(path: Path) -> Iterable[dict[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        yield from csv.DictReader(handle)


def _insert(cur, sql: str, rows: Sequence[tuple]) -> int:
    if not rows:
        return 0
    cur.fast_executemany = True
    cur.executemany(sql, rows)
    return len(rows)


def load(config: Config) -> dict[str, int]:
    data = config.data_dir
    if not data.is_dir():
        raise FileNotFoundError(f"No existe la carpeta de datos: {data}")

    conn = db.connect(config, database=config.src_db_name)
    counts: dict[str, int] = {}
    try:
        cur = conn.cursor()
        for table in TABLAS_BORRADO:
            cur.execute(f"DELETE FROM {table}")

        sucursales = [
            (_int(r["id_sucursal"]), r["nombre"].strip(), r["provincia"].strip())
            for r in _rows(data / "sucursales.csv")
        ]
        counts["sucursales"] = _insert(
            cur,
            "INSERT INTO src.sucursales (id_sucursal,nombre,provincia) VALUES (?,?,?)",
            sucursales,
        )

        clientes = [
            (
                r["id_cliente"].strip(),
                r["nombre_completo"].strip(),
                _date(r["fecha_nacimiento"]),
                r["provincia"].strip(),
                _text(r["telefono"]),
                _date(r["fecha_alta"]),
                r["segmento"].strip(),
                _dec(r["ingreso_mensual"]),
            )
            for r in _rows(data / "clientes.csv")
        ]
        counts["clientes"] = _insert(
            cur,
            "INSERT INTO src.clientes "
            "(id_cliente,nombre_completo,fecha_nacimiento,provincia,telefono,"
            "fecha_alta,segmento,ingreso_mensual) VALUES (?,?,?,?,?,?,?,?)",
            clientes,
        )

        creditos = [
            (
                r["id_credito"].strip(),
                r["id_cliente"].strip(),
                _int(r["id_sucursal"]),
                r["producto"].strip(),
                _dec(r["monto_desembolsado"]),
                _dec(r["tasa_anual"]),
                _int(r["plazo_meses"]),
                _date(r["fecha_desembolso"]),
                _dec(r["cuota_mensual"]),
                r["estado"].strip(),
            )
            for r in _rows(data / "creditos.csv")
        ]
        counts["creditos"] = _insert(
            cur,
            "INSERT INTO src.creditos "
            "(id_credito,id_cliente,id_sucursal,producto,monto_desembolsado,"
            "tasa_anual,plazo_meses,fecha_desembolso,cuota_mensual,estado) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            creditos,
        )

        cuotas = [
            (
                r["id_cuota"].strip(),
                r["id_credito"].strip(),
                _int(r["numero_cuota"]),
                _date(r["fecha_vencimiento"]),
                _dec(r["monto_cuota"]),
                _dec(r["monto_principal"]),
                _dec(r["monto_interes"]),
            )
            for r in _rows(data / "cuotas.csv")
        ]
        counts["cuotas"] = _insert(
            cur,
            "INSERT INTO src.cuotas "
            "(id_cuota,id_credito,numero_cuota,fecha_vencimiento,monto_cuota,"
            "monto_principal,monto_interes) VALUES (?,?,?,?,?,?,?)",
            cuotas,
        )

        pagos = [
            (
                r["id_pago"].strip(),
                r["id_credito"].strip(),
                _text(r["id_cuota"]),
                _date(r["fecha_pago"]),
                _dec(r["monto"]),
                r["canal"].strip(),
                _date(r["fecha_registro"]),
            )
            for r in _rows(data / "pagos.csv")
        ]
        counts["pagos"] = _insert(
            cur,
            "INSERT INTO src.pagos "
            "(id_pago,id_credito,id_cuota,fecha_pago,monto,canal,fecha_registro) "
            "VALUES (?,?,?,?,?,?,?)",
            pagos,
        )

        incrementales = [
            (
                r["id_pago"].strip(),
                r["id_credito"].strip(),
                _text(r["id_cuota"]),
                _date(r["fecha_pago"]),
                _dec(r["monto"]),
                r["canal"].strip(),
                _date(r["fecha_registro"]),
            )
            for r in _rows(data / "pagos_incremental.csv")
        ]
        counts["pagos_incremental"] = _insert(
            cur,
            "INSERT INTO src.pagos_incremental "
            "(id_pago,id_credito,id_cuota,fecha_pago,monto,canal,fecha_registro) "
            "VALUES (?,?,?,?,?,?,?)",
            incrementales,
        )

        conn.commit()
        return counts
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Carga los CSV del paquete en src.*")
    parser.add_argument("--env-file", default=None, help="Ruta alternativa a .env")
    parser.add_argument("--data-dir", default=None, help="Carpeta con los CSV")
    args = parser.parse_args(argv)

    config = Config.from_env(args.env_file)
    if args.data_dir:
        config = replace(config, data_dir=Path(args.data_dir))

    try:
        counts = load(config)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR cargando src.*: {exc}", file=sys.stderr)
        return 1

    expected = {
        "sucursales": 10,
        "clientes": 300,
        "creditos": 480,
        "cuotas": 13485,
        "pagos": 7518,
        "pagos_incremental": 53,
    }
    print("Carga de src completada:")
    ok = True
    for table in expected:
        got = counts.get(table, 0)
        status = "OK" if got == expected[table] else "REVISAR"
        ok = ok and got == expected[table]
        print(f"  {table:<18} {got:>6} filas  (esperado {expected[table]:>6})  {status}")
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main())
