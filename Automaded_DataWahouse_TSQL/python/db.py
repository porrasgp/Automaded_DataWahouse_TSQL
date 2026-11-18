"""Acceso a Azure SQL Database / SQL Server con pyodbc.

Variante Windows. Todas las operaciones usan consultas parametrizadas;
ninguna credencial se escribe en el codigo.
"""
from __future__ import annotations

from typing import Iterable, Sequence

from validators import NormalizedPayment, Reject

try:
    import pyodbc
except ImportError:  # pragma: no cover
    pyodbc = None


PROCESO = "EXTRACTOR_API"
ORIGEN = "API_PAGOS_EXTERNOS"


def _server(config) -> str:
    server = config.db_server.strip()
    if "," not in server and "\\" not in server:
        server = f"{server},{config.db_port}"
    return server


def _yesno(value) -> str:
    """Convierte bool o texto (true/1/yes/si) a 'yes' / 'no' para el driver ODBC."""
    if isinstance(value, str):
        return "yes" if value.strip().lower() in {"1", "true", "yes", "y", "si", "sí"} else "no"
    return "yes" if value else "no"


def connect(config, database: str | None = None):
    if pyodbc is None:
        raise RuntimeError(
            "Falta el driver pyodbc. Instale requirements.txt y el "
            "ODBC Driver 18 for SQL Server."
        )
    driver = config.db_driver.strip()
    if not driver.startswith("{"):
        driver = "{" + driver + "}"
    return pyodbc.connect(
        driver=driver,
        server=_server(config),
        database=database or config.db_name,
        uid=config.db_user,
        pwd=config.db_password,
        Encrypt=_yesno(config.db_encrypt),
        TrustServerCertificate=_yesno(config.db_trust_cert),
        timeout=30,
        autocommit=False,
    )


def start_bitacora(conn, proceso: str = PROCESO) -> int:
    cur = conn.cursor()
    cur.execute("SET NOCOUNT ON")
    cur.execute(
        "INSERT INTO dw.bitacora_ejecucion (proceso, estado) "
        "OUTPUT INSERTED.id_ejecucion VALUES (?, 'EN_PROCESO')",
        (proceso,),
    )
    row = cur.fetchone()
    conn.commit()
    return int(row[0])


def finish_bitacora(
    conn,
    id_ejecucion: int,
    *,
    leidas: int,
    insertadas: int,
    actualizadas: int,
    rechazadas: int,
    duplicadas: int,
    estado: str,
    mensaje: str,
) -> None:
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE dw.bitacora_ejecucion
           SET fecha_fin = SYSUTCDATETIME(),
               filas_leidas = ?,
               filas_insertadas = ?,
               filas_actualizadas = ?,
               filas_rechazadas = ?,
               filas_duplicadas = ?,
               estado = ?,
               mensaje = ?
         WHERE id_ejecucion = ?
        """,
        (
            leidas,
            insertadas,
            actualizadas,
            rechazadas,
            duplicadas,
            estado,
            mensaje[:1000],
            id_ejecucion,
        ),
    )
    conn.commit()


def get_credit_ids(conn) -> set[str]:
    cur = conn.cursor()
    cur.execute("SELECT id_credito FROM dw.dim_credito")
    return {str(row[0]).strip() for row in cur.fetchall()}


def clear_rechazos(conn, proceso: str = PROCESO) -> None:
    cur = conn.cursor()
    cur.execute("DELETE FROM dw.rechazos WHERE proceso = ?", (proceso,))


def _get_hash(conn, referencia: str) -> str | None:
    cur = conn.cursor()
    cur.execute(
        "SELECT hash_registro FROM dw.stg_pagos_externos WHERE referencia = ?",
        (referencia,),
    )
    row = cur.fetchone()
    return str(row[0]) if row else None


def upsert_pagos(conn, payments: Sequence[NormalizedPayment]) -> tuple[int, int, int]:
    """Upsert idempotente por referencia. Devuelve (insert, update, omit)."""
    inserted = updated = omitted = 0
    cur = conn.cursor()
    for p in payments:
        digest = p.hash_registro()
        current = _get_hash(conn, p.referencia)
        if current is None:
            cur.execute(
                """
                INSERT INTO dw.stg_pagos_externos
                    (referencia,id_credito,fecha_pago,monto,moneda,canal,estado,
                     comercio,hora,hash_registro,origen)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    p.referencia,
                    p.credito,
                    p.fecha_pago,
                    p.monto,
                    p.moneda,
                    p.canal,
                    p.estado,
                    p.comercio,
                    p.hora,
                    digest,
                    ORIGEN,
                ),
            )
            inserted += 1
        elif current != digest:
            cur.execute(
                """
                UPDATE dw.stg_pagos_externos
                   SET id_credito = ?, fecha_pago = ?, monto = ?, moneda = ?,
                       canal = ?, estado = ?, comercio = ?, hora = ?,
                       hash_registro = ?, fecha_carga = SYSUTCDATETIME()
                 WHERE referencia = ?
                """,
                (
                    p.credito,
                    p.fecha_pago,
                    p.monto,
                    p.moneda,
                    p.canal,
                    p.estado,
                    p.comercio,
                    p.hora,
                    digest,
                    p.referencia,
                ),
            )
            updated += 1
        else:
            omitted += 1
    return inserted, updated, omitted


def insert_rechazos(
    conn,
    id_ejecucion: int,
    rejects: Iterable[Reject],
    proceso: str = PROCESO,
    origen: str = ORIGEN,
) -> int:
    cur = conn.cursor()
    count = 0
    for r in rejects:
        cur.execute(
            """
            INSERT INTO dw.rechazos
                (id_ejecucion,proceso,origen,referencia,motivo,detalle)
            VALUES (?,?,?,?,?,?)
            """,
            (
                id_ejecucion,
                proceso,
                origen,
                (r.referencia or "")[:40] or None,
                r.motivo[:100],
                r.detalle[:1000],
            ),
        )
        count += 1
    return count