"""Configuracion del extractor y del cargador, desde variables de entorno/.env.

Variante Windows / Azure SQL Database.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - permite ejecutar sin python-dotenv
    load_dotenv = None


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PACKAGE_DIR = PROJECT_ROOT / "Instacredit" / "Paquete_datos_prueba_tecnica"
DEFAULT_INPUT = PACKAGE_DIR / "api_pagos_externos.json"
DEFAULT_DATA = PACKAGE_DIR
DEFAULT_LOG = Path(__file__).resolve().parent / "extractor.log"
DEFAULT_REJECTS = Path(__file__).resolve().parent / "rechazos_api.json"


def _get(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.getenv(name, default)
    if required and (value is None or value == ""):
        raise ValueError(f"Falta la variable de entorno obligatoria {name}")
    return "" if value is None else value


def _path(name: str, default: Path) -> Path:
    """Resuelve rutas relativas contra la raiz de la entrega, no contra el cwd."""
    raw = _get(name, str(default))
    path = Path(raw).expanduser()
    return path if path.is_absolute() else (PROJECT_ROOT / path)


@dataclass(frozen=True)
class Config:
    db_server: str
    db_port: int
    db_name: str
    src_db_name: str
    db_user: str
    db_password: str
    db_driver: str
    db_encrypt: str
    db_trust_cert: str
    input_json: Path
    data_dir: Path
    log_file: Path
    rejects_file: Path
    log_level: str
    api_url: str
    api_token: str
    api_page_size: int
    api_timeout: int
    max_pages: int

    @classmethod
    def from_env(cls, env_file: str | Path | None = None) -> "Config":
        """Carga .env (si existe) y luego el entorno del proceso."""
        if load_dotenv is not None:
            if env_file is not None:
                load_dotenv(env_file, override=False)
            else:
                default_env = Path(__file__).resolve().parent / ".env"
                if default_env.exists():
                    load_dotenv(default_env, override=False)

        return cls(
            db_server=_get("DB_SERVER", "localhost"),
            db_port=int(_get("DB_PORT", "1433")),
            db_name=_get("DB_NAME", "dw.DatosPrueba"),
            src_db_name=_get("SRC_DB_NAME", "DatosPrueba"),
            db_user=_get("DB_USER", "sa"),
            db_password=_get("DB_PASSWORD", required=True),
            db_driver=_get("DB_DRIVER", "ODBC Driver 18 for SQL Server"),
            db_encrypt=_get("DB_ENCRYPT", "yes").lower(),
            db_trust_cert=_get("DB_TRUST_CERT", "no").lower(),
            input_json=_path("INPUT_JSON_PATH", DEFAULT_INPUT),
            data_dir=_path("DATA_DIR", DEFAULT_DATA),
            log_file=_path("LOG_FILE", DEFAULT_LOG),
            rejects_file=_path("REJECTS_FILE", DEFAULT_REJECTS),
            log_level=_get("LOG_LEVEL", "INFO").upper(),
            api_url=_get("API_URL", ""),
            api_token=_get("API_TOKEN", ""),
            api_page_size=int(_get("API_PAGE_SIZE", "50")),
            api_timeout=int(_get("API_TIMEOUT", "30")),
            max_pages=int(_get("MAX_PAGES", "1000")),
        )
