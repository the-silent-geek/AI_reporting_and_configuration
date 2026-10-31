"""JSON: one candidate record per object.

Accepted shapes:
  [ {...}, {...} ]                     array of objects
  {"data": [ {...} ], "meta": {...}}   first array of objects found under the root
  {...}                                a single object -> one record
  {...}\\n{...}\\n                       JSON Lines
Nested objects are flattened to dotted names ("customer.name") so every value has
a mappable field name; arrays are kept as they are.
"""
import json
from pathlib import Path
from typing import Any

from ..errors import FinalError
from ..records import CandidateRecord, Issue, clean
from .base import Report


def _reject_constant(name: str):
    raise ValueError(f"{name} is not valid JSON")   # NaN/Infinity can't go into jsonb


def _loads(text: str) -> Any:
    return json.loads(text, parse_constant=_reject_constant)


def flatten(obj: dict, prefix: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in obj.items():
        name = f"{prefix}{clean(str(key))}"
        if isinstance(value, dict) and value:
            out.update(flatten(value, f"{name}."))
        else:
            out[name] = clean(value) if not isinstance(value, list) else _clean_deep(value)
    return out


def _clean_deep(v: Any) -> Any:
    if isinstance(v, list):
        return [_clean_deep(x) for x in v]
    if isinstance(v, dict):
        return {clean(str(k)): _clean_deep(x) for k, x in v.items()}
    return clean(v)


def _locate(doc: Any) -> tuple[list[Any], str]:
    """The list of items to turn into records, and its JSONPath."""
    if isinstance(doc, list):
        return doc, "$"
    if isinstance(doc, dict):
        for key, value in doc.items():
            if isinstance(value, list) and any(isinstance(x, dict) for x in value):
                return value, f"$.{key}"
        return [doc], "$"
    raise FinalError("INVALID_FILE", "The JSON file holds a single value, not records.")


class JsonParser:
    def parse(self, path: Path, report: Report) -> list[CandidateRecord]:
        raw = path.read_bytes()
        try:
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError:
            raise FinalError("INVALID_FILE", "The JSON file is not UTF-8 text.")
        try:
            items, root = _locate(_loads(text))
        except json.JSONDecodeError as e:
            if e.msg != "Extra data":
                raise FinalError("INVALID_FILE", f"The JSON file is not valid JSON (line {e.lineno}).")
            items, root = self._json_lines(text), "$"
        except (ValueError, RecursionError) as e:
            raise FinalError("INVALID_FILE", f"The JSON file could not be read: {e}.")

        report(50, f"Read {len(items)} JSON items")
        records = []
        for i, item in enumerate(items):
            location = {"path": f"{root}[{i}]", "index": i}
            if isinstance(item, dict):
                if item:
                    records.append(CandidateRecord(location, flatten(item), "json"))
            elif item is not None:
                records.append(CandidateRecord(location, {"value": _clean_deep(item)}, "json", issues=[
                    Issue("EXTRACTION_NOT_OBJECT", "Item is not an object; kept under 'value'")]))
        return records

    @staticmethod
    def _json_lines(text: str) -> list[Any]:
        items = []
        for n, line in enumerate(text.splitlines(), start=1):
            if line.strip():
                try:
                    items.append(_loads(line))
                except (json.JSONDecodeError, ValueError):
                    raise FinalError("INVALID_FILE", f"The JSON Lines file has invalid JSON on line {n}.")
        return items
