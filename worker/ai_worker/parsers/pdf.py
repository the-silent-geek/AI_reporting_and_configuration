"""PDF routing: native text where the page has it, PaddleOCR only for scanned regions.

Per page:
  * >= PDF_MIN_TEXT_CHARS embedded characters  -> native words (pdf_text), plus OCR of any
    large image on the page that has no text layer over it (a scan pasted into a report)
  * fewer                                      -> the whole page is a scan: OCR it
OCR boxes are scaled back to PDF points, so bbox in source_location means the same
thing for both methods. Both feed layout.build_rows.
"""
import time
from pathlib import Path

from ..config import Settings
from ..errors import FinalError, RetryableError
from ..records import CandidateRecord, Issue
from .base import Report
from .layout import Word, build_rows
from .ocr import OcrEngine

_IMAGE_REGION_SHARE = 0.25   # images covering at least this share of a page are OCR candidates


class PdfParser:
    def __init__(self, ocr: OcrEngine, settings: Settings):
        self.ocr = ocr
        self.s = settings

    def parse(self, path: Path, report: Report) -> list[CandidateRecord]:
        import pdfplumber
        try:
            pdf = pdfplumber.open(path)
            pages = pdf.pages
        except Exception as e:   # pdfminer raises many types (wrapped differently per version)
            if "password" in repr(e).lower():
                raise FinalError("PDF_ENCRYPTED", "The PDF is password protected.")
            raise FinalError("INVALID_FILE", "The PDF file could not be opened.")

        deadline = time.monotonic() + self.s.ocr_timeout_seconds
        records: list[CandidateRecord] = []
        carry, tables = None, 0
        with pdf:
            total = len(pages)
            for p, page in enumerate(pages, start=1):
                words, regions = self._native(page)
                if regions:
                    if time.monotonic() > deadline:
                        raise RetryableError("OCR_TIMEOUT", "OCR processing exceeded the configured time limit.")
                    report(5 + 90 * (p - 1) // total, f"OCR on scanned page {p} of {total}")
                    for bbox in regions:
                        words += self._ocr_region(page, bbox)
                else:
                    report(5 + 90 * (p - 1) // total, f"Reading PDF page {p} of {total}")

                rows, carry = build_rows(words, carry, tables + 1)
                tables = max([tables, *(r.table for r in rows)])
                records += [self._record(p, r) for r in rows]
        return records

    def _native(self, page) -> tuple[list[Word], list[tuple[float, float, float, float]]]:
        """Embedded words, and the regions that still need OCR."""
        chars = [c for c in page.chars if c["text"].strip()]
        page_box = (0.0, 0.0, float(page.width), float(page.height))
        if len(chars) < self.s.pdf_min_text_chars:
            return [], [page_box]

        words = [Word(w["text"], w["x0"], w["top"], w["x1"], w["bottom"], "pdf_text")
                 for w in page.extract_words(keep_blank_chars=False, use_text_flow=False)]
        regions = []
        area = page.width * page.height
        for img in page.images:
            box = (max(img["x0"], 0.0), max(img["top"], 0.0),
                   min(img["x1"], page.width), min(img["bottom"], page.height))
            if (box[2] - box[0]) * (box[3] - box[1]) < area * _IMAGE_REGION_SHARE:
                continue
            inside = sum(box[0] <= c["x0"] <= box[2] and box[1] <= c["top"] <= box[3] for c in chars)
            if inside < self.s.pdf_min_text_chars:   # no searchable text layer over the image
                regions.append(box)
        return words, regions

    def _ocr_region(self, page, bbox) -> list[Word]:
        image = page.crop(bbox).to_image(resolution=self.s.ocr_dpi).original
        scale = 72.0 / self.s.ocr_dpi
        x, y = bbox[0], bbox[1]
        return [Word(w.text, x + w.x0 * scale, y + w.top * scale, x + w.x1 * scale, y + w.bottom * scale,
                     "ocr", w.confidence)
                for w in self.ocr.recognize(image) if w.text.strip()]

    def _record(self, page: int, row) -> CandidateRecord:
        location = {"page": page, row.kind: row.table, "bbox": row.bbox}
        if row.kind == "table":
            location["row"] = row.row
        issues = []
        conf = row.confidence
        if row.source == "ocr" and conf is not None and conf < self.s.ocr_review_below:
            issues.append(Issue("EXTRACTION_LOW_CONFIDENCE",
                                f"OCR confidence {conf:.2f} is below {self.s.ocr_review_below:.2f}; check the values"))
        return CandidateRecord(location, row.fields, row.source, conf, issues)
