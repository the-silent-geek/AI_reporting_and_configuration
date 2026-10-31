"""What each source field looks like: inferred type, date format, masked samples.

Only masked samples ever leave this module (to BGE text or to Groq): digits -> 9,
letters -> x/X, so "LN-1001" -> "XX-9999". Low-cardinality columns (status, currency,
severity) keep real values: they carry meaning and are not personal data.
"""
import re
from dataclasses import dataclass
from datetime import datetime

from ..records import CandidateRecord

PROFILE_ROWS = 1000      # rows looked at per field
SAMPLES = 5
_ENUM_MAX_DISTINCT = 12
_SHARE = 0.9             # share of non-empty values that must fit a type

_INT = re.compile(r"^[+-]?\d+$")
_DEC = re.compile(r"^\(?[+-]?\s*[$€£₹¥]?\s*(\d{1,3}(,\d{3})+|\d+)?(\.\d+)?\s*\)?(\s?[A-Z]{3})?$")
_CCY = re.compile(r"^[A-Z]{3}$")
_BOOL = {"true", "false", "yes", "no", "y", "n", "approved", "not approved"}
DATE_FORMATS = ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y", "%d.%m.%Y", "%Y/%m/%d",
                "%d-%b-%Y", "%d %b %Y", "%d-%b-%y", "%b %d, %Y", "%d %B %Y", "%B %d, %Y")
DATETIME_FORMATS = ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M",
                    "%Y-%m-%d %H:%M", "%d/%m/%Y %H:%M", "%m/%d/%Y %H:%M", "%d-%m-%Y %H:%M:%S")


@dataclass(frozen=True)
class FieldProfile:
    name: str
    type: str                  # empty | integer | decimal | date | datetime | boolean | currency | text
    fmt: str | None            # strptime format for date/datetime
    samples: tuple[str, ...]   # masked
    filled: float              # share of rows with a value
    distinct: int

    def describe(self, app: str) -> str:
        """Text BGE embeds: name, samples, type, product context."""
        return f"Source: {self.name} | samples: {', '.join(self.samples) or 'none'} | {self.type} | {app}"


def _text(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v).strip()


def mask(value: str) -> str:
    out = []
    for ch in value[:24]:
        out.append("9" if ch.isdigit() else ("X" if ch.isupper() else "x") if ch.isalpha() else ch)
    return "".join(out)


def _fits_format(values: list[str], formats: tuple[str, ...]) -> str | None:
    best, best_n = None, 0
    for fmt in formats:
        n = 0
        for v in values:
            try:
                datetime.strptime(v, fmt)
                n += 1
            except ValueError:
                pass
        if n > best_n:
            best, best_n = fmt, n
    return best if best_n >= len(values) * _SHARE else None


def infer_type(values: list, distinct: int) -> tuple[str, str | None]:
    texts = [_text(v) for v in values if _text(v)]
    if not texts:
        return "empty", None
    natives = [v for v in values if v is not None and not isinstance(v, str)]
    if natives and all(isinstance(v, bool) for v in natives) and len(natives) == len(texts):
        return "boolean", None
    need = len(texts) * _SHARE

    def share(pred) -> bool:
        return sum(1 for t in texts if pred(t)) >= need

    if share(lambda t: t.lower() in _BOOL) and distinct <= 4:
        return "boolean", None
    if share(_INT.match):
        return "integer", None
    if share(lambda t: bool(_DEC.match(t)) and any(c.isdigit() for c in t)):
        return "decimal", None
    if fmt := _fits_format(texts, DATETIME_FORMATS):
        return "datetime", fmt
    if fmt := _fits_format(texts, DATE_FORMATS):
        return "date", fmt
    if share(_CCY.match) and distinct <= 50:
        return "currency", None
    return "text", None


def profile(records: list[CandidateRecord]) -> list[FieldProfile]:
    rows = records[:PROFILE_ROWS]
    names = list(dict.fromkeys(k for r in rows for k in r.raw_fields if k != "_extra"))
    profiles = []
    for name in names:
        values = [r.raw_fields.get(name) for r in rows]
        texts = [_text(v) for v in values if _text(v)]
        distinct_values = list(dict.fromkeys(texts))
        kind, fmt = infer_type(values, len(distinct_values))
        enum_like = len(distinct_values) <= _ENUM_MAX_DISTINCT and len(texts) >= 2 * len(distinct_values)
        samples = distinct_values[:SAMPLES] if enum_like or kind in ("boolean", "currency") \
            else [mask(t) for t in distinct_values[:SAMPLES]]
        profiles.append(FieldProfile(name, kind, fmt, tuple(samples),
                                     round(len(texts) / max(len(rows), 1), 3), len(distinct_values)))
    return profiles


def normalize_name(name: str) -> str:
    """'Invoice_No' / 'invoiceNo' / 'Invoice #' / 'Amount (USD)' -> 'invoice no' / ... / 'amount'."""
    name = re.sub(r"\(.*?\)", " ", name)
    name = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name)
    name = name.replace("#", " no ")
    name = re.sub(r"[^0-9a-zA-Z]+", " ", name)
    return " ".join(name.lower().split())
