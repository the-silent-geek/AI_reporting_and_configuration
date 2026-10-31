"""Reads uploads by the storage_uri stored on ingestion_batch.

Only file:// is implemented, because that is what the API writes today
(storage/<app>/<sha256><ext>, D20). Object storage = one more StorageReader
registered under its scheme (e.g. "s3"), nothing else changes.

The URI comes from the DB, but it is still checked: the resolved path must be
inside STORAGE_DIR, so a bad row can never make the worker read arbitrary files.
"""
import hashlib
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Protocol
from urllib.parse import urlparse
from urllib.request import url2pathname

from .errors import FinalError, RetryableError

_CHUNK = 1024 * 1024


class StorageReader(Protocol):
    def local_copy(self, uri: str, expected_sha256: str):
        """Context manager yielding a local Path whose sha256 has been verified."""


class LocalFileStorage:
    def __init__(self, root: Path):
        self.root = root.resolve()

    def _path(self, uri: str) -> Path:
        parsed = urlparse(uri)
        if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
            raise FinalError("STORAGE_UNSUPPORTED", "The file location is not supported by the worker.")
        path = Path(url2pathname(parsed.path)).resolve()
        if not path.is_relative_to(self.root):
            raise FinalError("STORAGE_PATH_REJECTED", "The file location is outside the upload storage.")
        return path

    @contextmanager
    def local_copy(self, uri: str, expected_sha256: str) -> Iterator[Path]:
        path = self._path(uri)
        try:
            digest = hashlib.sha256()
            with path.open("rb") as f:
                while chunk := f.read(_CHUNK):
                    digest.update(chunk)
        except FileNotFoundError:
            # Shared/network storage can lag behind the API's write: retry before giving up.
            raise RetryableError("FILE_NOT_FOUND", "The uploaded file could not be found in storage.")
        except OSError:
            raise RetryableError("STORAGE_UNAVAILABLE", "The upload storage could not be read.")
        if digest.hexdigest() != expected_sha256.lower():
            raise FinalError("CHECKSUM_MISMATCH", "The stored file does not match its upload checksum.")
        yield path   # already local: parsers read it in place


class StorageRouter:
    """Picks the reader by URI scheme."""

    def __init__(self, readers: dict[str, StorageReader]):
        self.readers = readers

    def local_copy(self, uri: str, expected_sha256: str):
        reader = self.readers.get(urlparse(uri).scheme)
        if reader is None:
            raise FinalError("STORAGE_UNSUPPORTED", "The file location is not supported by the worker.")
        return reader.local_copy(uri, expected_sha256)
