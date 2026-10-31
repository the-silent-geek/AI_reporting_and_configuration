"""Parser router: ingestion_batch.file_type -> parser."""
from ..config import Settings
from ..errors import FinalError
from .base import Parser, Report
from .json_parser import JsonParser
from .ocr import OcrEngine
from .pdf import PdfParser
from .tabular import CsvParser, ExcelParser


class ParserRouter:
    def __init__(self, ocr: OcrEngine, settings: Settings):
        self.parsers: dict[str, Parser] = {
            "CSV": CsvParser(),
            "EXCEL": ExcelParser(),
            "JSON": JsonParser(),
            "PDF": PdfParser(ocr, settings),
        }

    def for_type(self, file_type: str) -> Parser:
        parser = self.parsers.get(file_type.upper())
        if parser is None:
            raise FinalError("UNSUPPORTED_FILE", f"File type {file_type} is not supported.")
        return parser


__all__ = ["ParserRouter", "Parser", "Report"]
