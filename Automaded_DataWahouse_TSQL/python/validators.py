"""Normalizacion y validacion de los pagos recibidos de la API externa.

El diseno es intencionalmente tolerante: cada campo se normaliza cuando es
posible (fechas dd/mm/aaaa, montos con separador de miles, IDs con espacios
o minusculas) y los registros que no cumplen las reglas se devuelven como
rechazos con un motivo, sin detener el procesamiento del lote.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any, Iterable, Sequence

REFERENCE_RE = re.compile(r"^[A-Z0-9][A-Z0-9_-]{2,29}$")
CREDIT_RE = re.compile(r"^CR-\d{5}$")
DATE_FORMATS = ("%Y-%m-%d", "%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y")
ALLOWED_CURRENCIES = {"CRC", "USD"}
CANAL_MAP = {
    "bancoa": "BancoA",
    "bancob": "BancoB",
    "pago movil": "Pago Móvil",
    "pago móvil": "Pago Móvil",
    "sinpe": "Pago Móvil",
    "app": "App",
    "sucursal": "Sucursal",
    "banco": "Banco",
    "conectividad": "Conectividad",
}
CENT = Decimal("0.01")
MAX_MONTO = Decimal("999999999999.99")


@dataclass(frozen=True)
class NormalizedPayment:
    referencia: str
    credito: str
    fecha_pago: date
    monto: Decimal
    moneda: str
    canal: str
    estado: str
    comercio: str | None = None
    hora: str | None = None

    def hash_registro(self) -> str:
        """Hash canonico para detectar cambios reales entre corridas."""
        payload = "|".join(
            [
                self.referencia,
                self.credito,
                self.fecha_pago.isoformat(),
                f"{self.monto:.2f}",
                self.moneda,
                self.canal,
                self.estado,
                self.comercio or "",
                self.hora or "",
            ]
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass
class Reject:
    referencia: str | None
    motivo: str
    detalle: str
    raw: dict[str, Any] = field(default_factory=dict, repr=False)


def parse_fecha(value: Any) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if value is None:
        raise ValueError("fecha_pago faltante")
    text = str(value).strip()
    if not text:
        raise ValueError("fecha_pago vacia")
    # Fechas ISO con hora (2026-10-27T06:00:00)
    if "T" in text:
        try:
            return datetime.fromisoformat(text.replace("Z", "+00:00")).date()
        except ValueError:
            pass
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"fecha_pago invalida: {text!r}")


def parse_monto(value: Any) -> Decimal:
    if value is None:
        raise ValueError("monto faltante")
    if isinstance(value, bool):
        raise ValueError("monto booleano invalido")
    if isinstance(value, (int, float, Decimal)):
        text = str(value)
    else:
        text = str(value).strip()
    if not text:
        raise ValueError("monto vacio")

    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1]

    # Quita simbolos de moneda, espacios y separadores de miles.
    for token in ("CRC", "USD", "₡", "$", " "):
        text = text.replace(token, "")
    text = text.replace(",", "")
    text = text.replace("+", "")
    try:
        amount = Decimal(text)
    except (InvalidOperation, ValueError):
        raise ValueError(f"monto no numerico: {value!r}") from None
    if negative:
        amount = -amount
    amount = amount.quantize(CENT, rounding=ROUND_HALF_UP)
    if amount <= 0:
        raise ValueError(f"monto debe ser mayor que cero: {amount}")
    if amount > MAX_MONTO:
        raise ValueError(f"monto fuera de rango: {amount}")
    return amount


def normalize_referencia(value: Any) -> str:
    if value is None:
        raise ValueError("referencia faltante")
    text = re.sub(r"\s+", "", str(value)).upper()
    if not text:
        raise ValueError("referencia vacia")
    if not REFERENCE_RE.match(text):
        raise ValueError(f"referencia con formato invalido: {text!r}")
    return text


def normalize_credito(value: Any) -> str:
    if value is None:
        raise ValueError("credito faltante")
    text = re.sub(r"\s+", "", str(value)).upper()
    if not text:
        raise ValueError("credito vacio")
    if not CREDIT_RE.match(text):
        raise ValueError(f"credito con formato invalido: {text!r}")
    return text


def normalize_moneda(value: Any) -> tuple[str, list[str]]:
    warnings: list[str] = []
    if value is None or str(value).strip() == "":
        warnings.append("moneda faltante; se asume CRC")
        return "CRC", warnings
    text = str(value).strip().upper()
    if text not in ALLOWED_CURRENCIES:
        raise ValueError(f"moneda no soportada: {text!r}")
    return text, warnings


def normalize_canal(value: Any) -> str:
    if value is None:
        raise ValueError("canal faltante")
    text = re.sub(r"\s+", " ", str(value)).strip()
    if not text:
        raise ValueError("canal vacio")
    mapped = CANAL_MAP.get(text.lower())
    text = mapped or text
    if len(text) > 30:
        raise ValueError("canal excede 30 caracteres")
    return text


def normalize_estado(value: Any) -> str:
    if value is None:
        raise ValueError("estado faltante")
    text = str(value).strip().upper()
    if text != "APLICADO":
        raise ValueError(f"estado no aplicable: {text!r}")
    return text


def validate_record(
    raw: Any,
    valid_credit_ids: Sequence[str] | set[str] | None = None,
) -> tuple[NormalizedPayment | None, list[str], list[str]]:
    """Normaliza un registro. Devuelve (pago, errores, advertencias)."""
    errors: list[str] = []
    warnings: list[str] = []
    if not isinstance(raw, dict):
        return None, ["registro no es un objeto JSON"], warnings

    ref = None
    try:
        ref = normalize_referencia(raw.get("referencia"))
    except ValueError as exc:
        errors.append(str(exc))

    credito = None
    try:
        credito = normalize_credito(raw.get("credito"))
        if valid_credit_ids is not None and credito not in set(valid_credit_ids):
            errors.append(f"credito inexistente: {credito}")
    except ValueError as exc:
        errors.append(str(exc))

    fecha = None
    try:
        fecha = parse_fecha(raw.get("fecha_pago"))
    except ValueError as exc:
        errors.append(str(exc))

    monto = None
    try:
        monto = parse_monto(raw.get("monto"))
    except ValueError as exc:
        errors.append(str(exc))

    moneda = "CRC"
    try:
        moneda, warns = normalize_moneda(raw.get("moneda"))
        warnings.extend(warns)
    except ValueError as exc:
        errors.append(str(exc))

    canal = None
    try:
        canal = normalize_canal(raw.get("canal"))
    except ValueError as exc:
        errors.append(str(exc))

    estado = None
    try:
        estado = normalize_estado(raw.get("estado"))
    except ValueError as exc:
        errors.append(str(exc))

    detalle = raw.get("detalle")
    comercio = None
    hora = None
    if isinstance(detalle, dict):
        comercio = str(detalle.get("comercio")).strip() if detalle.get("comercio") else None
        hora = str(detalle.get("hora")).strip() if detalle.get("hora") else None
    elif detalle not in (None, ""):
        warnings.append("detalle no es objeto; se ignora")

    if errors or ref is None or credito is None or fecha is None or monto is None or canal is None or estado is None:
        return None, errors, warnings

    payment = NormalizedPayment(
        referencia=ref,
        credito=credito,
        fecha_pago=fecha,
        monto=monto,
        moneda=moneda,
        canal=canal,
        estado=estado,
        comercio=comercio[:60] if comercio else None,
        hora=hora[:8] if hora else None,
    )
    return payment, errors, warnings


def process_records(
    records: Iterable[Any],
    valid_credit_ids: Sequence[str] | set[str] | None = None,
) -> tuple[list[NormalizedPayment], list[Reject], list[str]]:
    """Valida, normaliza y deduplica por referencia.

    Si una referencia aparece varias veces se conserva la primera ocurrencia
    valida y las siguientes se registran como DUPLICADO_REFERENCIA.
    """
    valid: list[NormalizedPayment] = []
    rejects: list[Reject] = []
    warnings: list[str] = []
    seen: set[str] = set()

    for index, raw in enumerate(records, start=1):
        ref_hint = raw.get("referencia") if isinstance(raw, dict) else None
        payment, errors, warns = validate_record(raw, valid_credit_ids)
        if errors:
            rejects.append(
                Reject(
                    referencia=str(ref_hint) if ref_hint is not None else None,
                    motivo="REGISTRO_INVALIDO",
                    detalle="; ".join(errors),
                    raw=raw if isinstance(raw, dict) else {},
                )
            )
            continue

        assert payment is not None
        for warn in warns:
            warnings.append(f"{payment.referencia}: {warn}")

        if payment.referencia in seen:
            rejects.append(
                Reject(
                    referencia=payment.referencia,
                    motivo="DUPLICADO_REFERENCIA",
                    detalle=f"referencia repetida en el lote (registro {index})",
                    raw=raw if isinstance(raw, dict) else {},
                )
            )
            continue

        seen.add(payment.referencia)
        valid.append(payment)

    return valid, rejects, warnings
