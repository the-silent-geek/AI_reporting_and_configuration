"""Worker entry point.  Run:  python -m ai_worker  (from worker/)"""
import asyncio
import logging
import signal

from .config import Settings, check_runtime, settings
from .consumer import RabbitConsumer
from .mapping import MappingService
from .mapping.embeddings import BgeEmbedder
from .mapping.groq import GroqResolver
from .parsers import ParserRouter
from .parsers.ocr import PaddleOcrEngine
from .pipeline import IngestionPipeline
from .repository import PgRepository
from .storage import LocalFileStorage, StorageRouter

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("ai_worker")


def build_mapper(s: Settings) -> MappingService:
    embedder = None
    if s.embedding_model:
        log.info("loading embedding model %s", s.embedding_model)
        embedder = BgeEmbedder(s.embedding_model)   # fails loudly: configured means required
    else:
        log.warning("EMBEDDING_MODEL empty: BGE layer off")
    groq = None
    if s.groq_api_key:
        groq = GroqResolver(s.groq_api_key, s.groq_model, s.groq_base_url, s.groq_timeout_seconds)
    else:
        log.warning("GROQ_API_KEY empty: ambiguous fields are left for manual review")
    return MappingService(embedder, groq, s.bge_accept, s.bge_margin)


async def main() -> None:
    check_runtime(settings)
    repo = PgRepository(settings)
    pipeline = IngestionPipeline(
        repo,
        StorageRouter({"file": LocalFileStorage(settings.storage_dir)}),
        ParserRouter(PaddleOcrEngine(settings.ocr_lang), settings),
        build_mapper(settings),
    )
    consumer = RabbitConsumer(settings, pipeline)
    await consumer.start()

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:   # Windows: Ctrl+C arrives as KeyboardInterrupt instead
            pass
    try:
        await stop.wait()
    finally:
        log.info("stopping: finishing running jobs")
        await consumer.stop()
        repo.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
