"""Groq LLM, called only for fields the alias and BGE layers could not settle.

What is sent: product, target entity, the allowed canonical fields (name, type,
description), and per ambiguous field its header, inferred type, masked samples and
BGE candidates. Never the dataset, file name, user, or anything secret.

The reply must validate against a strict schema and may only name fields it was
offered; anything else is dropped. Any failure (no key, timeout, 429, bad JSON)
returns no suggestions: the caller keeps the BGE/alias result flagged for review.
"""
import json
import logging
from typing import Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .catalog import Target
from .profiling import FieldProfile

log = logging.getLogger(__name__)

MAX_FIELDS_PER_CALL = 25

TransformType = Literal["none", "trim", "uppercase", "parse_decimal", "parse_integer",
                        "parse_date", "parse_datetime", "parse_boolean"]


class Transformation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    type: TransformType
    remove_characters: list[str] | None = Field(default=None, max_length=10)
    format: str | None = Field(default=None, max_length=40)
    true_values: list[str] | None = Field(default=None, max_length=10)


class GroqSuggestion(BaseModel):
    model_config = ConfigDict(extra="forbid")
    source_field: str
    target_field: str | None
    transformation: Transformation
    confidence: float = Field(ge=0, le=1)
    reason: str = Field(max_length=400)


class GroqReply(BaseModel):
    model_config = ConfigDict(extra="forbid")
    mappings: list[GroqSuggestion]


_SYSTEM = (
    "You map columns of an uploaded business file to canonical database fields. "
    "Use only the allowed target fields given. If no allowed field fits, use null. "
    "Do not map two source fields to the same target. Be conservative with confidence: "
    "the user reviews every suggestion. Reply with JSON only, exactly this shape: "
    '{"mappings":[{"source_field":str,"target_field":str|null,'
    '"transformation":{"type":"none|trim|uppercase|parse_decimal|parse_integer|parse_date|parse_datetime|parse_boolean",'
    '"remove_characters":[str]?,"format":"strptime format"?,"true_values":[str]?},'
    '"confidence":0..1,"reason":"one sentence"}]}'
)


class GroqResolver:
    def __init__(self, api_key: str, model: str, base_url: str, timeout: float,
                 transport: httpx.BaseTransport | None = None):   # transport: tests only
        self.model = model
        self.calls = 0
        self.client = httpx.Client(base_url=base_url, timeout=timeout, transport=transport,
                                   headers={"Authorization": f"Bearer {api_key}"})

    def resolve(self, app: str, entity: str, allowed: list[Target],
                fields: list[tuple[FieldProfile, list[dict]]]) -> dict[str, GroqSuggestion]:
        """fields = (profile, BGE candidates). Returns source_field -> validated suggestion."""
        out: dict[str, GroqSuggestion] = {}
        for i in range(0, len(fields), MAX_FIELDS_PER_CALL):
            out.update(self._call(app, entity, allowed, fields[i:i + MAX_FIELDS_PER_CALL]))
        return out

    def _call(self, app, entity, allowed, fields) -> dict[str, GroqSuggestion]:
        allowed_names = {t.name for t in allowed}
        asked = {p.name for p, _ in fields}
        payload = {
            "product": app,
            "target_entity": entity,
            "allowed_target_fields": [{"name": t.name, "type": t.type, "description": t.description} for t in allowed],
            "source_fields": [{"source_field": p.name, "inferred_type": p.type, "masked_samples": list(p.samples),
                               "semantic_candidates": candidates} for p, candidates in fields],
        }
        self.calls += 1
        try:
            r = self.client.post("/chat/completions", json={
                "model": self.model,
                "temperature": 0,
                "response_format": {"type": "json_object"},
                "messages": [{"role": "system", "content": _SYSTEM},
                             {"role": "user", "content": json.dumps(payload)}],
            })
            r.raise_for_status()
            reply = GroqReply.model_validate_json(r.json()["choices"][0]["message"]["content"])
        except httpx.HTTPStatusError as e:
            log.warning("Groq unavailable (HTTP %s); keeping local suggestions", e.response.status_code)
            return {}
        except httpx.HTTPError as e:
            log.warning("Groq unavailable (%s); keeping local suggestions", type(e).__name__)
            return {}
        except (ValidationError, KeyError, IndexError, TypeError, ValueError):
            log.warning("Groq reply did not match the schema; ignored")
            return {}

        valid = {}
        for s in reply.mappings:
            if s.source_field not in asked or s.source_field in valid:
                continue
            if s.target_field is not None and s.target_field not in allowed_names:
                log.warning("Groq suggested a field outside the allowed list; ignored")
                continue
            valid[s.source_field] = s
        return valid

    def close(self) -> None:
        self.client.close()
