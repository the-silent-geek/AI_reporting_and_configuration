"""The one adapter contract: every parser (CSV, Excel, JSON, PDF text, OCR) yields
CandidateRecord, which maps 1:1 onto a <app>.raw_record row.

Extraction problems found on a record (ragged CSV row, low OCR confidence ...) are
kept as issues: they go to <app>.validation_issue and put the record in NEEDS_REVIEW.
"""
from dataclasses import dataclass, field
from typing import Any, Literal

# raw_record.extraction_method CHECK constraint
Method = Literal["csv", "excel", "json", "pdf_text", "ocr"]


@dataclass(frozen=True)
class Issue:
    rule_code: str                   # validation_issue.rule_code, e.g. EXTRACTION_RAGGED_ROW
    message: str
    field: str | None = None
    severity: Literal["ERROR", "WARNING"] = "WARNING"
    original_value: str | None = None


@dataclass
class CandidateRecord:
    source_location: dict[str, Any]  # {"row":12} {"sheet":"Payables","row":12} {"page":2,"table":1,"row":4,"bbox":[..]}
    raw_fields: dict[str, Any]       # original names -> values, untouched
    extraction_method: Method
    confidence: float | None = None  # 0-1; None = exact (not a model guess)
    issues: list[Issue] = field(default_factory=list)

    @property
    def state(self) -> Literal["PENDING", "NEEDS_REVIEW"]:
        return "NEEDS_REVIEW" if self.issues else "PENDING"


def clean(value: Any) -> Any:
    """PostgreSQL jsonb rejects \\u0000. Everything else is kept as found (raw_fields
    is the untouched original); profiling/mapping trims on its own copy."""
    if isinstance(value, str):
        return value.replace("\x00", "")
    return value


def unique_headers(names: list[Any]) -> list[str]:
    """Blank headers become column_<n>; repeats get a suffix (Amount, Amount_2) so no
    value is silently overwritten in raw_fields."""
    seen: dict[str, int] = {}
    out = []
    for i, name in enumerate(names, start=1):
        base = " ".join(str(clean(name) if name is not None else "").split()) or f"column_{i}"
        seen[base] = seen.get(base, 0) + 1
        out.append(base if seen[base] == 1 else f"{base}_{seen[base]}")
    return out
