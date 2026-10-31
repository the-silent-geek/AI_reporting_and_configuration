"""Test doubles: in-memory repository, state-machine-checking publisher, exact
embedder, scripted OCR, and a tiny PDF writer (no PDF library needed to make fixtures)."""
import hashlib
import math
from pathlib import Path
from uuid import UUID, uuid4

from ai_worker.messages import IngestionRequested, Progress
from ai_worker.parsers.ocr import OcrWord
from ai_worker.repository import Batch, Saved

# Legal transitions of sp_update_batch_status (db/_product_pipeline.sql), for the statuses the worker uses.
LEGAL = {("UPLOADED", "EXTRACTING"), ("EXTRACTING", "MAPPING_REVIEW"), ("EXTRACTING", "NEEDS_REVIEW"),
         ("NEEDS_REVIEW", "MAPPING_REVIEW"), ("FAILED", "UPLOADED")}


def legal(src: str, dst: str) -> bool:
    return src == dst or (src, dst) in LEGAL or (dst == "FAILED" and src not in ("COMMITTED", "FAILED"))


class MemoryRepo:
    def __init__(self):
        self.batches: dict[UUID, Batch] = {}
        self.rows: dict[UUID, list] = {}
        self.mappings: dict[UUID, list] = {}
        self.save_calls = 0

    def add_batch(self, path: Path, file_type: str, status: str = "UPLOADED") -> Batch:
        b = Batch(uuid4(), status, file_type, path.name, path.resolve().as_uri(),
                  hashlib.sha256(path.read_bytes()).hexdigest())
        self.batches[b.batch_id] = b
        return b

    def set_status(self, batch_id: UUID, status: str) -> None:
        b = self.batches[batch_id]
        self.batches[batch_id] = Batch(b.batch_id, status, b.file_type, b.file_name, b.storage_uri, b.sha256)

    def load_batch(self, app, batch_id):
        return self.batches.get(batch_id)

    def existing_result(self, app, batch_id):
        rows = self.rows.get(batch_id)
        if not rows:
            return None
        return Saved(len(rows), sum(r.state == "NEEDS_REVIEW" for r in rows),
                     len(self.mappings.get(batch_id, [])), already_saved=True)

    def save(self, app, batch_id, records, mapping):
        self.save_calls += 1
        if done := self.existing_result(app, batch_id):
            return done
        self.rows[batch_id] = list(records)
        self.mappings[batch_id] = mapping.mappings()
        return Saved(len(records), sum(r.state == "NEEDS_REVIEW" for r in records), len(mapping.suggestions))


class StatePublisher:
    """Applies progress like the API's handle_progress would, rejecting illegal jumps."""

    def __init__(self, repo: MemoryRepo):
        self.repo = repo
        self.sent: list[Progress] = []

    def progress(self, p: Progress) -> None:
        current = self.repo.batches[p.batch_id].status
        assert legal(current, p.status), f"illegal transition {current} -> {p.status}"
        self.sent.append(p)
        self.repo.set_status(p.batch_id, p.status)

    @property
    def statuses(self) -> list[str]:
        return [p.status for p in self.sent]


def job_for(batch: Batch, app: str = "erp") -> IngestionRequested:
    return IngestionRequested(batch_id=batch.batch_id, app=app, file_type=batch.file_type,
                              file_name=batch.file_name, storage_uri=batch.storage_uri,
                              sha256=batch.sha256, uploaded_by=uuid4())


class ExactEmbedder:
    """dot(source, target) == the similarity you script, so BGE decisions are testable.

    Targets are one-hot by description; a source's vector is its scripted similarities
    plus a residual component that keeps it unit length.
    """

    def __init__(self, sims: dict[str, dict[str, float]]):
        self.sims = sims            # source field name -> {target field name: cosine}
        self.targets: list[str] = []
        self.dim = 512

    def encode(self, texts):
        out = []
        for text in texts:
            if text.startswith("Target: "):
                self.targets.append(text)
                v = [0.0] * self.dim
                v[len(self.targets) - 1] = 1.0
            else:
                name = text.removeprefix("Source: ").split(" | ")[0]
                v = [0.0] * self.dim
                for i, t in enumerate(self.targets):
                    field = t.removeprefix("Target: ").split(" | ")[0].replace(" ", "_")
                    v[i] = self.sims.get(name, {}).get(field, 0.0)
                v[-1] = math.sqrt(max(0.0, 1 - sum(x * x for x in v)))
            out.append(v)
        return out


class ScriptedOcr:
    def __init__(self, words: list[OcrWord]):
        self.words = words
        self.calls = 0
        self.sizes: list[tuple[int, int]] = []

    def recognize(self, image):
        self.calls += 1
        self.sizes.append(image.size)
        return self.words


# ---------------------------------------------------------------- PDF writer ----

def make_pdf(pages: list[dict], width: int = 612, height: int = 792) -> bytes:
    """pages: [{"text": [(x, top, "string"), ...], "image": (x0, top, x1, bottom) | None}]
    Coordinates are top-left based like pdfplumber's; Helvetica 10pt."""
    objs: list[bytes] = []

    def add(body: bytes) -> int:
        objs.append(body)
        return len(objs)

    catalog = add(b"")          # filled in last
    pages_id = add(b"")
    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pixels = bytes([40, 200, 120, 255])
    image = add(b"<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray "
                b"/BitsPerComponent 8 /Length 4 >>\nstream\n" + pixels + b"\nendstream")
    kids = []
    for page in pages:
        ops = []
        if box := page.get("image"):
            x0, top, x1, bottom = box
            ops.append(f"q {x1 - x0} 0 0 {bottom - top} {x0} {height - bottom} cm /Im1 Do Q")
        for x, top, s in page.get("text", []):
            s = s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
            ops.append(f"BT /F1 10 Tf {x} {height - top - 8} Td ({s}) Tj ET")
        stream = "\n".join(ops).encode("latin-1")
        content = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        kids.append(add(f"<< /Type /Page /Parent {pages_id} 0 R /MediaBox [0 0 {width} {height}] "
                        f"/Resources << /Font << /F1 {font} 0 R >> /XObject << /Im1 {image} 0 R >> >> "
                        f"/Contents {content} 0 R >>".encode()))
    objs[catalog - 1] = f"<< /Type /Catalog /Pages {pages_id} 0 R >>".encode()
    objs[pages_id - 1] = (f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] "
                          f"/Count {len(kids)} >>").encode()

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    out += b"".join(f"{o:010d} 00000 n \n".encode() for o in offsets)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root {catalog} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)
