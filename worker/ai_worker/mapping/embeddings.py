"""Local semantic similarity with BAAI/bge-small-en-v1.5 (sentence-transformers).

Runs on the worker's CPU: field descriptions never leave the machine. The model is
loaded once at startup; canonical-field vectors are cached per product.
"""
from typing import Protocol, Sequence

from .catalog import Target, targets


class Embedder(Protocol):
    def encode(self, texts: Sequence[str]) -> list[list[float]]:
        """Unit-length vectors, so a dot product is the cosine similarity."""


class BgeEmbedder:
    def __init__(self, model_name: str):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer(model_name, device="cpu")

    def encode(self, texts: Sequence[str]) -> list[list[float]]:
        return self.model.encode(list(texts), normalize_embeddings=True, convert_to_numpy=True).tolist()


def describe_target(app: str, t: Target) -> str:
    return f"Target: {t.name.replace('_', ' ')} | {t.description} | {t.type} | {app} {t.entity.replace('_', ' ')}"


class TargetIndex:
    """Cached vectors of every canonical field of a product."""

    def __init__(self, embedder: Embedder):
        self.embedder = embedder
        self._cache: dict[str, tuple[list[Target], list[list[float]]]] = {}

    def get(self, app: str) -> tuple[list[Target], list[list[float]]]:
        if app not in self._cache:
            ts = targets(app)
            self._cache[app] = (ts, self.embedder.encode([describe_target(app, t) for t in ts]))
        return self._cache[app]


def dot(a: Sequence[float], b: Sequence[float]) -> float:
    return float(sum(x * y for x, y in zip(a, b)))
