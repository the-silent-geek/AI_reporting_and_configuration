"""OCR engine interface + PaddleOCR implementation.

PaddleOCR is heavy (model download + ~1 GB RAM), so it is imported and loaded on
first use only: a worker that never sees a scanned PDF never pays for it.
"""
import threading
from dataclasses import dataclass
from typing import Any, Protocol


@dataclass(frozen=True)
class OcrWord:
    """Pixel coordinates in the image that was passed in."""
    text: str
    confidence: float
    x0: float
    top: float
    x1: float
    bottom: float


class OcrEngine(Protocol):
    def recognize(self, image) -> list[OcrWord]:
        """image: PIL.Image of a rendered page or page region."""


def _box(points: Any) -> tuple[float, float, float, float]:
    """4-point polygon [[x,y]x4] or [x0,y0,x1,y1] -> (x0, top, x1, bottom)."""
    pts = [list(map(float, p)) for p in points] if hasattr(points[0], "__len__") else None
    if pts:
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        return min(xs), min(ys), max(xs), max(ys)
    x0, y0, x1, y1 = map(float, points)
    return x0, y0, x1, y1


class PaddleOcrEngine:
    def __init__(self, lang: str):
        self.lang = lang
        self._ocr = None
        self._lock = threading.Lock()   # one Paddle predictor, not thread-safe

    def _load(self):
        from paddleocr import PaddleOCR
        try:   # PaddleOCR 3.x
            return PaddleOCR(lang=self.lang, use_doc_orientation_classify=False,
                             use_doc_unwarping=False, use_textline_orientation=False)
        except TypeError:   # 2.x
            return PaddleOCR(lang=self.lang, use_angle_cls=False, show_log=False)

    def recognize(self, image) -> list[OcrWord]:
        import numpy as np
        bgr = np.array(image.convert("RGB"))[:, :, ::-1].copy()
        with self._lock:
            if self._ocr is None:
                self._ocr = self._load()
            if hasattr(self._ocr, "predict"):
                return self._from_v3(self._ocr.predict(bgr))
            return self._from_v2(self._ocr.ocr(bgr, cls=False))

    @staticmethod
    def _from_v3(results) -> list[OcrWord]:
        words = []
        for res in results:
            boxes = res.get("rec_polys")
            if boxes is None:
                boxes = res.get("rec_boxes")
            for text, score, box in zip(res["rec_texts"], res["rec_scores"], boxes):
                words.append(OcrWord(str(text), float(score), *_box(box)))
        return words

    @staticmethod
    def _from_v2(results) -> list[OcrWord]:
        words = []
        for page in results or []:
            for box, (text, score) in page or []:
                words.append(OcrWord(str(text), float(score), *_box(box)))
        return words
