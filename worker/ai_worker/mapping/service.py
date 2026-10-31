"""Hybrid field mapping: aliases + types -> local BGE -> Groq only when still unclear.

  1. profile every source field (type, date format, masked samples)
  2. pick the target entity: the domain table whose fields the file covers best
  3. per field, within that entity:
       alias match (one, type-compatible)          -> accept   method=alias
       BGE best >= BGE_ACCEPT, clear lead, fits    -> accept   method=bge
       otherwise                                   -> ask Groq method=groq
       Groq off / failed / unsure                  -> best local guess, needs_review
  4. one target per field: if two fields claim one target, the weaker one is unset

The result is only a proposal (mapping_version.status = PROPOSED). A person approves
it; the worker never writes normalized_fields or domain tables.
"""
import logging
from dataclasses import asdict, dataclass, field

from ..records import CandidateRecord
from .catalog import Target, entities, targets
from .embeddings import Embedder, TargetIndex, dot
from .groq import GroqResolver
from .profiling import FieldProfile, normalize_name, profile

log = logging.getLogger(__name__)

# how well an inferred source type fits a target type: 1 fits, 0.6 convertible/unclear, 0 wrong
_FIT = {
    "text":     {"text": 1, "integer": 1, "currency": 1, "decimal": .6, "date": .6, "datetime": .6, "boolean": .6},
    "decimal":  {"decimal": 1, "integer": 1},
    "integer":  {"integer": 1, "decimal": .6},
    "date":     {"date": 1, "datetime": .6},
    "datetime": {"datetime": 1, "date": .6},
    "currency": {"currency": 1, "text": .6},
    "boolean":  {"boolean": 1, "integer": .6, "text": .6},
}
_TYPE_PENALTY = 0.15      # BGE score penalty for a wrong type (scaled by 1 - fit)
_GUESS_FLOOR = 0.60       # below this a local guess is not worth showing
_GROQ_REVIEW_BELOW = 0.85


def type_fit(target_type: str, inferred: str) -> float:
    return 0.6 if inferred == "empty" else _FIT[target_type].get(inferred, 0.0)


def transform_for(t: Target, p: FieldProfile) -> dict:
    """How the value must be converted at approval time (shown to the reviewer)."""
    if t.type == "decimal":
        return {"type": "parse_decimal", "remove_characters": [",", " ", "$", "€", "£", "₹"]}
    if t.type == "integer":
        return {"type": "parse_integer"}
    if t.type in ("date", "datetime"):
        tr = {"type": f"parse_{t.type}"}
        return tr | {"format": p.fmt} if p.fmt else tr
    if t.type == "currency":
        return {"type": "uppercase"}
    if t.type == "boolean":
        return {"type": "parse_boolean", "true_values": ["true", "yes", "y", "1", "approved"]}
    return {"type": "trim"}


@dataclass
class Suggestion:
    source_field: str
    target_entity: str | None
    target_field: str | None
    transform: dict
    confidence: float
    rationale: str
    method: str                      # alias | bge | groq | none
    needs_review: bool
    candidates: list[dict] = field(default_factory=list)


@dataclass
class MappingResult:
    entity: str | None
    suggestions: list[Suggestion]

    def mappings(self) -> list[dict]:
        """mapping_version.mappings: [{source_field, target_field, transform, confidence, rationale, ...}]"""
        return [asdict(s) for s in self.suggestions]


class MappingService:
    def __init__(self, embedder: Embedder | None, groq: GroqResolver | None, accept: float, margin: float):
        self.embedder = embedder
        self.index = TargetIndex(embedder) if embedder else None
        self.groq = groq
        self.accept = accept
        self.margin = margin
        self._aliases: dict[str, dict[str, list[Target]]] = {}

    # ---------------------------------------------------------------- layers ----

    def _alias_index(self, app: str) -> dict[str, list[Target]]:
        if app not in self._aliases:
            idx: dict[str, list[Target]] = {}
            for t in targets(app):
                for a in {normalize_name(t.name), *(normalize_name(a) for a in t.aliases)}:
                    idx.setdefault(a, []).append(t)
            self._aliases[app] = idx
        return self._aliases[app]

    def _semantic(self, app: str, profiles: list[FieldProfile]) -> dict[tuple[str, str], float]:
        """(source_field, entity.field) -> type-adjusted cosine similarity."""
        if not self.index or not profiles:
            return {}
        ts, tvecs = self.index.get(app)
        svecs = self.embedder.encode([p.describe(app) for p in profiles])
        return {(p.name, t.qualified): dot(sv, tv) - _TYPE_PENALTY * (1 - type_fit(t.type, p.type))
                for p, sv in zip(profiles, svecs) for t, tv in zip(ts, tvecs)}

    def _pick_entity(self, app, profiles, alias_hits, sims) -> str | None:
        def evidence(p: FieldProfile, t: Target) -> float:
            if t in alias_hits[p.name] and type_fit(t.type, p.type) > 0:
                return 1.0
            s = sims.get((p.name, t.qualified), 0.0)
            return s if s >= self.accept - 0.1 else 0.0

        best, best_key = None, (0.0, 0.0)
        for e in entities(app):
            ts = targets(app, e)
            covered = {t.name: max((evidence(p, t) for p in profiles), default=0.0) for t in ts}
            score = sum(covered.values())
            if all(covered[t.name] >= 0.9 for t in ts if t.key):
                score += 0.5
            key = (round(score, 6), score / len(ts))
            if key > best_key:
                best, best_key = e, key
        return best if best_key[0] > 0.5 else None

    # ------------------------------------------------------------------ main ----

    def suggest(self, app: str, records: list[CandidateRecord]) -> MappingResult:
        profiles = profile(records)
        aliases = self._alias_index(app)
        alias_hits = {p.name: aliases.get(normalize_name(p.name), []) for p in profiles}
        sims = self._semantic(app, profiles)
        entity = self._pick_entity(app, profiles, alias_hits, sims)
        if entity is None:
            return MappingResult(None, [Suggestion(p.name, None, None, {"type": "none"}, 0.0,
                                                   "No target table matches this file's fields", "none", True)
                                        for p in profiles])
        allowed = targets(app, entity)

        decided: dict[str, Suggestion] = {}
        unclear: list[tuple[FieldProfile, list[tuple[Target, float]], list[Target]]] = []
        for p in profiles:
            ranked = sorted(((t, sims.get((p.name, t.qualified), 0.0)) for t in allowed),
                            key=lambda x: x[1], reverse=True)
            hits = [t for t in alias_hits[p.name] if t.entity == entity and type_fit(t.type, p.type) > 0]
            if len(hits) == 1:
                t = hits[0]
                fit = type_fit(t.type, p.type)
                decided[p.name] = Suggestion(
                    p.name, entity, t.name, transform_for(t, p), 0.97 if fit == 1 else 0.85,
                    f"Header matches known name for {t.name}; values look {p.type}", "alias", fit < 1,
                    self._candidates(ranked))
                continue
            if hits:   # alias fits several fields (e.g. "Supplier" -> id or name): let BGE/Groq choose
                ranked = sorted(ranked, key=lambda x: (x[0] in hits, x[1]), reverse=True)
            if self.index and ranked:
                (top, s1), s2 = ranked[0], ranked[1][1] if len(ranked) > 1 else 0.0
                if not hits and s1 >= self.accept and s1 - s2 >= self.margin and type_fit(top.type, p.type) > 0:
                    decided[p.name] = Suggestion(
                        p.name, entity, top.name, transform_for(top, p), round(s1, 4),
                        f"Semantically closest to {top.name} ({s1:.2f}, next {s2:.2f})", "bge", False,
                        self._candidates(ranked))
                    continue
            unclear.append((p, ranked, hits))

        decided |= self._resolve_unclear(app, entity, allowed, unclear)
        suggestions = [decided[p.name] for p in profiles]
        self._one_field_per_target(suggestions)
        return MappingResult(entity, suggestions)

    def _resolve_unclear(self, app, entity, allowed, unclear) -> dict[str, Suggestion]:
        if not unclear:
            return {}
        by_name = {t.name: t for t in allowed}
        answers = {}
        if self.groq:
            answers = self.groq.resolve(app, entity, allowed,
                                        [(p, self._candidates(ranked)) for p, ranked, _ in unclear])
        out = {}
        for p, ranked, hits in unclear:
            candidates = self._candidates(ranked)
            a = answers.get(p.name)
            if a is not None:
                t = by_name.get(a.target_field) if a.target_field else None
                out[p.name] = Suggestion(
                    p.name, entity, a.target_field, a.transformation.model_dump(exclude_none=True) if t else {"type": "none"},
                    round(a.confidence, 4), a.reason, "groq",
                    t is None or a.confidence < _GROQ_REVIEW_BELOW, candidates)
                continue
            # No Groq answer: offer the best local guess, flagged.
            if hits:
                t = hits[0]   # ranked puts alias hits first when there are several
                out[p.name] = Suggestion(p.name, entity, t.name, transform_for(t, p), 0.6,
                                         f"Header could mean {' or '.join(h.name for h in hits)}; please confirm",
                                         "alias", True, candidates)
            elif ranked and ranked[0][1] >= _GUESS_FLOOR and type_fit(ranked[0][0].type, p.type) > 0:
                t, s = ranked[0]
                out[p.name] = Suggestion(p.name, entity, t.name, transform_for(t, p), round(s, 4),
                                         f"Uncertain: closest field is {t.name} ({s:.2f}); please confirm",
                                         "bge", True, candidates)
            else:
                out[p.name] = Suggestion(p.name, entity, None, {"type": "none"}, 0.0,
                                         "No confident match; map manually or leave unmapped", "none", True,
                                         candidates)
        return out

    @staticmethod
    def _candidates(ranked: list[tuple[Target, float]]) -> list[dict]:
        return [{"target_field": t.name, "score": round(s, 4)} for t, s in ranked[:3] if s > 0]

    @staticmethod
    def _one_field_per_target(suggestions: list[Suggestion]) -> None:
        winner: dict[str, Suggestion] = {}
        for s in sorted(suggestions, key=lambda s: s.confidence, reverse=True):
            if s.target_field is None:
                continue
            if s.target_field in winner:
                s.rationale = f"{s.target_field} is already suggested for '{winner[s.target_field].source_field}'"
                s.target_field, s.transform, s.needs_review = None, {"type": "none"}, True
            else:
                winner[s.target_field] = s
