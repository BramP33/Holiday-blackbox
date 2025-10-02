from __future__ import annotations

from functools import lru_cache
from typing import Optional

try:
    from sentence_transformers import SentenceTransformer
except ImportError:  # pragma: no cover - optional dependency
    SentenceTransformer = None  # type: ignore


class SemanticModelUnavailable(RuntimeError):
    pass


@lru_cache(maxsize=4)
def _load_model(model_id: str, device: str = 'cpu') -> SentenceTransformer:
    if SentenceTransformer is None:
        raise SemanticModelUnavailable('sentence-transformers package is not installed')
    return SentenceTransformer(model_id, device=device)


def encode_text(text: str, *, model_id: str, device: str = 'cpu', normalize: bool = True):
    if not text.strip():
        raise ValueError('Cannot encode empty text')
    model = _load_model(model_id, device)
    return model.encode([text], normalize_embeddings=normalize)[0]


def encode_queries(queries: list[str], *, model_id: str, device: str = 'cpu', normalize: bool = True):
    if not queries:
        return []
    model = _load_model(model_id, device)
    return model.encode(queries, normalize_embeddings=normalize)


def available() -> bool:
    return SentenceTransformer is not None
