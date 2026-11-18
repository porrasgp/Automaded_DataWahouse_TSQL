#!/usr/bin/env python3
"""Extractor de pagos de la API externa hacia staging en SQL Server/Azure SQL.

La fuente de datos esta abstraida en PageSource. Hoy se implementan dos:
  - JsonFilePageSource: simula paginas a partir del JSON del paquete.
  - HttpPageSource: llamada HTTP real paginada (reemplazable por la API).
El resto del flujo (normalizacion, validacion, staging, rechazos y bitacora)
no depende de la fuente.
"""
from __future__ import annotations

import argparse
import json
import logging
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Protocol

import db
from config import Config
from validators import NormalizedPayment, Reject, process_records

LOG = logging.getLogger("extractor_pagos")


@dataclass
class PageInfo:
    records: list[dict[str, Any]]
    page: int
    total_pages: int
    total_records: int


class PageSource(Protocol):
    def fetch_page(self, page: int) -> PageInfo: ...


class JsonFilePageSource:
    """Fuente local que simula la paginacion de la API."""

    def __init__(self, path: Path, page_size: int = 50) -> None:
        self.path = path
        self.page_size = max(1, page_size)
        payload = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(payload, dict):
            self.records = list(payload.get("pagos", []))
            self.metadata = {k: v for k, v in payload.items() if k != "pagos"}
        elif isinstance(payload, list):
            self.records = list(payload)
            self.metadata = {}
        else:  # pragma: no cover
            raise ValueError("El JSON debe ser un objeto con 'pagos' o una lista")
        self.total_records = len(self.records)
        self.total_pages = max(1, math.ceil(self.total_records / self.page_size))

    def fetch_page(self, page: int) -> PageInfo:
        if page < 1 or page > self.total_pages:
            return PageInfo([], page, self.total_pages, self.total_records)
        start = (page - 1) * self.page_size
        end = start + self.page_size
        return PageInfo(self.records[start:end], page, self.total_pages, self.total_records)


class HttpPageSource:
    """Fuente HTTP real paginada. Reemplaza a JsonFilePageSource en produccion."""

    def __init__(self, url: str, token: str = "", timeout: int = 30, page_size: int = 50) -> None:
        self.url = url
        self.token = token
        self.timeout = timeout
        self.page_size = max(1, page_size)

    def fetch_page(self, page: int) -> PageInfo:
        import requests

        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        response = requests.get(
            self.url,
            params={"page": page, "page_size": self.page_size},
            headers=headers,
            timeout=self.timeout,
        )
        response.raise_for_status()
        payload = response.json()
        records = payload.get("pagos") or payload.get("data") or payload.get("items") or []
        total_pages = int(payload.get("total_paginas") or payload.get("total_pages") or 1)
        total_records = int(payload.get("total_registros") or payload.get("total_records") or len(records))
        return PageInfo(list(records), page, total_pages, total_records)


def iter_records(source: PageSource, max_pages: int = 1000) -> Iterable[dict[str, Any]]:
    page = 1
    info = source.fetch_page(page)
    while True:
        yield from info.records
        if page >= info.total_pages or page >= max_pages:
            break
        page += 1
        info = source.fetch_page(page)


def build_source(config: Config) -> PageSource:
    if config.api_url:
        LOG.info("Fuente HTTP: %s (pagina de %s registros)", config.api_url, config.api_page_size)
        return HttpPageSource(config.api_url, config.api_token, config.api_timeout, config.api_page_size)
    LOG.info("Fuente JSON local: %s (pagina simulada de %s registros)", config.input_json, config.api_page_size)
    return JsonFilePageSource(config.input_json, config.api_page_size)


def setup_logging(config: Config) -> None:
    config.log_file.parent.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    root = logging.getLogger()
    root.setLevel(getattr(logging, config.log_level, logging.INFO))
    root.handlers.clear()
    file_handler = logging.FileHandler(config.log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)
    root.addHandler(file_handler)
    root.addHandler(stream_handler)


def write_rejects(config: Config, rejects: list[Reject]) -> None:
    config.rejects_file.parent.mkdir(parents=True, exist_ok=True)
    payload = [
        {
            "referencia": r.referencia,
            "motivo": r.motivo,
            "detalle": r.detalle,
            "raw": r.raw,
        }
        for r in rejects
    ]
    config.rejects_file.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, default=str), encoding="utf-8"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Extractor de pagos externos hacia staging SQL Server")
    parser.add_argument("--env-file", default=None, help="Ruta alternativa a .env")
    args = parser.parse_args(argv)

    config = Config.from_env(args.env_file)
    setup_logging(config)
    LOG.info("Inicio del extractor. DB=%s:%s/%s", config.db_server, config.db_port, config.db_name)

    conn = None
    id_ejecucion = None
    try:
        conn = db.connect(config)
        id_ejecucion = db.start_bitacora(conn)

        source = build_source(config)
        records = list(iter_records(source, config.max_pages))
        LOG.info("Registros leidos de la fuente: %d", len(records))

        valid_credit_ids = db.get_credit_ids(conn)
        if not valid_credit_ids:
            raise RuntimeError("dw.dim_credito esta vacio; ejecute 00, load_src.py y 01-02 primero")

        pagos: list[NormalizedPayment]
        rechazos: list[Reject]
        advertencias: list[str]
        pagos, rechazos, advertencias = process_records(records, valid_credit_ids)
        for warning in advertencias:
            LOG.warning("Normalizacion: %s", warning)

        duplicados = sum(1 for r in rechazos if r.motivo == "DUPLICADO_REFERENCIA")
        LOG.info(
            "Validacion: %d validos, %d rechazados (%d duplicados de referencia)",
            len(pagos), len(rechazos), duplicados,
        )

        db.clear_rechazos(conn)
        insertadas, actualizadas, omitidas = db.upsert_pagos(conn, pagos)
        db.insert_rechazos(conn, id_ejecucion, rechazos)
        conn.commit()

        write_rejects(config, rechazos)

        mensaje = (
            f"{len(records)} leidos, {len(pagos)} validos, {insertadas} insertados, "
            f"{actualizadas} actualizados, {omitidas} omitidos, {len(rechazos)} rechazados "
            f"({duplicados} duplicados de referencia)."
        )
        db.finish_bitacora(
            conn,
            id_ejecucion,
            leidas=len(records),
            insertadas=insertadas,
            actualizadas=actualizadas,
            rechazadas=len(rechazos),
            duplicadas=omitidas,
            estado="EXITOSO",
            mensaje=mensaje,
        )

        resumen = {
            "id_ejecucion": id_ejecucion,
            "leidos": len(records),
            "validos": len(pagos),
            "insertados": insertadas,
            "actualizados": actualizadas,
            "omitidos": omitidas,
            "rechazados": len(rechazos),
            "duplicados_referencia": duplicados,
        }
        LOG.info("Fin OK: %s", json.dumps(resumen, ensure_ascii=False))
        print(json.dumps(resumen, ensure_ascii=False))
        return 0

    except Exception as exc:  # noqa: BLE001 - se registra y no se oculta
        LOG.exception("Fallo el extractor: %s", exc)
        if conn is not None:
            try:
                conn.rollback()
                if id_ejecucion is not None:
                    db.finish_bitacora(
                        conn,
                        id_ejecucion,
                        leidas=0,
                        insertadas=0,
                        actualizadas=0,
                        rechazadas=0,
                        duplicadas=0,
                        estado="FALLIDO",
                        mensaje=str(exc),
                    )
            except Exception:  # pragma: no cover
                LOG.exception("No se pudo actualizar la bitacora a FALLIDO")
        return 1
    finally:
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
