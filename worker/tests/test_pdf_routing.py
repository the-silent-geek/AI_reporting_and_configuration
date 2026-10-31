"""PDF routing: native text never goes to OCR; scanned pages/regions always do,
and both come out as the same table records."""
from ai_worker.parsers.ocr import OcrWord, PaddleOcrEngine
from ai_worker.parsers.pdf import PdfParser
from fakes import ScriptedOcr, job_for, make_pdf

COLUMNS = (50, 200, 350)      # x of: Invoice No | Supplier | Amount


def _table(top: float, rows: list[tuple[str, str, str]]):
    """Text placements for a header + rows, 20pt apart."""
    out = []
    for i, cells in enumerate([("Invoice No", "Supplier", "Amount"), *rows]):
        out += [(x, top + 20 * i, text) for x, text in zip(COLUMNS, cells)]
    return out


def _ocr_words(top: float, rows: list[tuple[str, str, str]], conf: float = 0.95):
    """What PaddleOCR would return for the same table (pixel coords; tests render at 72 dpi)."""
    words = []
    for i, cells in enumerate([("Invoice No", "Supplier", "Amount"), *rows]):
        y = top + 20 * i
        words += [OcrWord(text, conf, x, y, x + 6 * len(text), y + 10) for x, text in zip(COLUMNS, cells)]
    return words


ROWS = [("INV-001", "ACME Ltd", "10,000.00"), ("INV-002", "Globex", "2,500.00")]


def _parse(tmp_path, pdf: bytes, ocr: ScriptedOcr, settings):
    path = tmp_path / "doc.pdf"
    path.write_bytes(pdf)
    messages = []
    records = PdfParser(ocr, settings).parse(path, lambda pct, msg: messages.append(msg))
    return records, messages


def test_text_pdf_uses_native_extraction_only(tmp_path, settings):
    ocr = ScriptedOcr([])
    pdf = make_pdf([{"text": [(50, 40, "Payables report - October"), *_table(80, ROWS),
                              (50, 160, "Total"), (350, 160, "12,500.00")]}])
    records, messages = _parse(tmp_path, pdf, ocr, settings)

    assert ocr.calls == 0
    assert [r.raw_fields for r in records] == [
        {"Invoice No": "INV-001", "Supplier": "ACME Ltd", "Amount": "10,000.00"},
        {"Invoice No": "INV-002", "Supplier": "Globex", "Amount": "2,500.00"}]   # title + total dropped
    assert all(r.extraction_method == "pdf_text" and r.confidence is None for r in records)
    assert records[0].source_location["page"] == 1 and records[0].source_location["row"] == 1
    assert len(records[0].source_location["bbox"]) == 4
    assert messages == ["Reading PDF page 1 of 1"]


def test_scanned_pdf_goes_to_ocr(tmp_path, settings):
    ocr = ScriptedOcr(_ocr_words(80, ROWS + [("INV-003", "Initech", "99.00")], conf=0.95))
    pdf = make_pdf([{"image": (0, 0, 612, 792)}])                 # a page that is just a picture
    records, messages = _parse(tmp_path, pdf, ocr, settings)

    assert ocr.calls == 1 and ocr.sizes == [(612, 792)]           # whole page rendered
    assert [r.raw_fields["Invoice No"] for r in records] == ["INV-001", "INV-002", "INV-003"]
    assert all(r.extraction_method == "ocr" and r.confidence == 0.95 for r in records)
    assert all(r.state == "PENDING" for r in records)
    assert messages == ["OCR on scanned page 1 of 1"]


def test_low_ocr_confidence_needs_review(tmp_path, settings):
    ocr = ScriptedOcr(_ocr_words(80, ROWS, conf=0.55))
    records, _ = _parse(tmp_path, make_pdf([{"image": (0, 0, 612, 792)}]), ocr, settings)
    assert all(r.state == "NEEDS_REVIEW" for r in records)
    assert records[0].issues[0].rule_code == "EXTRACTION_LOW_CONFIDENCE"


def test_mixed_document_routes_per_page(tmp_path, settings):
    ocr = ScriptedOcr(_ocr_words(80, [("INV-003", "Initech", "99.00")]))
    pdf = make_pdf([{"text": _table(80, ROWS)}, {"image": (0, 0, 612, 792)}])
    records, messages = _parse(tmp_path, pdf, ocr, settings)

    assert ocr.calls == 1
    assert [(r.source_location["page"], r.extraction_method) for r in records] == [
        (1, "pdf_text"), (1, "pdf_text"), (2, "ocr")]
    assert messages == ["Reading PDF page 1 of 2", "OCR on scanned page 2 of 2"]


def test_scanned_region_inside_text_page_is_ocred(tmp_path, settings):
    """Digital page with a pasted scan: only the image region goes to OCR, offset back
    into page coordinates."""
    region = (40, 300, 572, 700)
    x0, top = region[0], region[1]
    words = [OcrWord(w.text, w.confidence, w.x0 - x0, w.top - top, w.x1 - x0, w.bottom - top)
             for w in _ocr_words(320, ROWS)]          # region-relative pixels
    ocr = ScriptedOcr(words)
    pdf = make_pdf([{"text": [(50, 40, "Scanned supplier statement attached below, see appendix")],
                     "image": region}])
    records, _ = _parse(tmp_path, pdf, ocr, settings)

    assert ocr.calls == 1 and ocr.sizes == [(532, 400)]
    assert [r.raw_fields["Supplier"] for r in records] == ["ACME Ltd", "Globex"]
    assert records[0].extraction_method == "ocr"
    assert records[0].source_location["bbox"][1] > 300   # back in page coordinates


def test_label_value_form(tmp_path, settings):
    pdf = make_pdf([{"text": [(50, 60, "Application No: LN-1001"), (50, 80, "Applicant: Jane Roe"),
                              (50, 100, "Loan Amount: 25,000")]}])
    records, _ = _parse(tmp_path, pdf, ScriptedOcr([]), settings)
    assert len(records) == 1
    assert records[0].raw_fields == {"Application No": "LN-1001", "Applicant": "Jane Roe", "Loan Amount": "25,000"}
    assert records[0].source_location["form"] == 1


def test_table_continues_on_next_page_without_header(tmp_path, settings):
    second = [(x, 80, t) for x, t in zip(COLUMNS, ("INV-003", "Initech", "99.00"))] + \
             [(x, 100, t) for x, t in zip(COLUMNS, ("INV-004", "Umbrella", "15.00"))]
    pdf = make_pdf([{"text": _table(80, ROWS)}, {"text": second}])
    records, _ = _parse(tmp_path, pdf, ScriptedOcr([]), settings)
    assert [r.raw_fields["Invoice No"] for r in records] == ["INV-001", "INV-002", "INV-003", "INV-004"]
    assert {r.source_location["table"] for r in records} == {1}


def test_pipeline_pdf_progress_and_records(tmp_path, pipeline, repo, publisher, ocr):
    ocr.words = _ocr_words(80, ROWS)
    path = tmp_path / "scan.pdf"
    path.write_bytes(make_pdf([{"text": _table(80, ROWS)}, {"image": (0, 0, 612, 792)}]))
    batch = repo.add_batch(path, "PDF")
    outcome = pipeline.run(job_for(batch), publisher)

    assert outcome.status == "MAPPING_REVIEW" and outcome.records == 4
    assert any("OCR on scanned page 2 of 2" == p.message for p in publisher.sent)
    methods = [r.extraction_method for r in repo.rows[batch.batch_id]]
    assert methods == ["pdf_text", "pdf_text", "ocr", "ocr"]


def test_paddle_adapter_reads_v3_and_v2_results():
    v3 = [{"rec_texts": ["INV-1"], "rec_scores": [0.9], "rec_polys": [[[1, 2], [11, 2], [11, 8], [1, 8]]]}]
    assert PaddleOcrEngine._from_v3(v3) == [OcrWord("INV-1", 0.9, 1, 2, 11, 8)]
    v2 = [[[[[1, 2], [11, 2], [11, 8], [1, 8]], ("INV-1", 0.9)]]]
    assert PaddleOcrEngine._from_v2(v2) == [OcrWord("INV-1", 0.9, 1, 2, 11, 8)]
