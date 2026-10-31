"""Unit/pipeline tests run with no broker, DB, model or network: fakes stand in
(tests/fakes.py). test_repository_pg.py additionally runs against a built DB when
one is reachable (same db/.env settings as the API), otherwise it is skipped."""
import dataclasses

import pytest

from ai_worker.config import load
from ai_worker.mapping import MappingService
from ai_worker.parsers import ParserRouter
from ai_worker.pipeline import IngestionPipeline
from ai_worker.storage import LocalFileStorage, StorageRouter
from fakes import MemoryRepo, ScriptedOcr, StatePublisher


@pytest.fixture
def settings(tmp_path):
    # OCR at 72 dpi: one image pixel == one PDF point, so scripted OCR boxes are easy to place
    return dataclasses.replace(load(), storage_dir=tmp_path, ocr_dpi=72, embedding_model="", groq_api_key="")


@pytest.fixture
def repo():
    return MemoryRepo()


@pytest.fixture
def publisher(repo):
    return StatePublisher(repo)


@pytest.fixture
def ocr():
    return ScriptedOcr([])


@pytest.fixture
def pipeline(settings, repo, ocr):
    return IngestionPipeline(repo, StorageRouter({"file": LocalFileStorage(settings.storage_dir)}),
                             ParserRouter(ocr, settings), MappingService(None, None, settings.bge_accept,
                                                                         settings.bge_margin))
