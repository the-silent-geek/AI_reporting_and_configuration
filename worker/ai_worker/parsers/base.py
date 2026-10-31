"""Parser interface shared by every format."""
from pathlib import Path
from typing import Protocol

from ..records import CandidateRecord


class Report(Protocol):
    """Progress callback: pct is 0-100 within the extraction stage."""
    def __call__(self, pct: int, message: str) -> None: ...


class Parser(Protocol):
    def parse(self, path: Path, report: Report) -> list[CandidateRecord]: ...
