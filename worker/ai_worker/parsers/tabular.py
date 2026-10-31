"""CSV and Excel: a header row, then one candidate record per data row."""
import csv
import io
from datetime import date, datetime, time
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable

from ..errors import FinalError
from ..records import CandidateRecord, Issue, Method, clean, unique_headers
from .base import Report

_HEADER_SCAN_ROWS = 20   # Excel: title/notes rows above the header are common


def _blank(v: Any) -> bool:
    return v is None or (isinstance(v, str) and not v.strip())


def rows_to_records(header: list[Any], rows: Iterable[tuple[dict, list[Any]]],
                    method: Method) -> list[CandidateRecord]:
    """rows = (source_location, values). Ragged rows are kept, never dropped, and flagged."""
    names = unique_headers(header)
    # trailing unnamed columns are spreadsheet noise unless a row actually uses them
    while names and names[-1].startswith("column_") and _blank(header[len(names) - 1]):
        names.pop()
    records = []
    for location, values in rows:
        if all(_blank(v) for v in values):
            continue
        fields = {n: clean(values[i]) if i < len(values) else None for i, n in enumerate(names)}
        issues = []
        extra = [clean(v) for v in values[len(names):] if not _blank(v)]
        if extra:
            fields["_extra"] = extra
            issues.append(Issue("EXTRACTION_RAGGED_ROW", f"Row has {len(names) + len(extra)} values but the "
                                f"header has {len(names)} columns", severity="ERROR"))
        elif len(values) < len(names) and method == "csv":
            issues.append(Issue("EXTRACTION_RAGGED_ROW", f"Row has {len(values)} values but the header has "
                                f"{len(names)} columns"))
        records.append(CandidateRecord(location, fields, method, issues=issues))
    return records


# --------------------------------------------------------------------- CSV ----

def _decode(data: bytes) -> str:
    for encoding in ("utf-8-sig", "cp1252"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")   # never fails; odd bytes stay visible for review


class CsvParser:
    def parse(self, path: Path, report: Report) -> list[CandidateRecord]:
        text = _decode(path.read_bytes())
        try:
            dialect = csv.Sniffer().sniff(text[:65536], delimiters=",;\t|")
        except csv.Error:
            dialect = csv.excel
        reader = csv.reader(io.StringIO(text, newline=""), dialect)

        def rows():
            start = 1
            for values in reader:
                yield {"row": start}, values
                start = reader.line_num + 1   # quoted fields may span lines

        try:
            it = rows()
            header = None
            for _, values in it:
                if not all(_blank(v) for v in values):
                    header = values
                    break
            if header is None:
                raise FinalError("EMPTY_FILE", "The CSV file has no header row.")
            report(50, "Reading CSV rows")
            return rows_to_records(header, it, "csv")
        except csv.Error as e:
            raise FinalError("INVALID_FILE", f"The CSV file could not be read near line {reader.line_num}: {e}.")


# ------------------------------------------------------------------- Excel ----

def _cell(v: Any) -> Any:
    """JSON-safe cell value: dates become ISO strings, numbers stay numbers."""
    if isinstance(v, datetime):
        return v.date().isoformat() if v.time() == time() else v.isoformat()
    if isinstance(v, (date, time)):
        return v.isoformat()
    if isinstance(v, Decimal):
        return float(v)
    return v


def _header_index(rows: list[list[Any]]) -> int | None:
    """First row that looks like column names: mostly text, about as wide as the data."""
    widths = [sum(not _blank(v) for v in r) for r in rows]
    if not any(widths):
        return None
    widest = max(widths)
    for i, r in enumerate(rows):
        filled = [v for v in r if not _blank(v)]
        if len(filled) >= max(1, widest // 2) and all(isinstance(v, str) for v in filled):
            return i
    return next(i for i, w in enumerate(widths) if w)


def _sheet_records(name: str, rows: Iterable[list[Any]]) -> list[CandidateRecord]:
    """rows are 1-based Excel rows in order."""
    it = iter(rows)
    head = [r for _, r in zip(range(_HEADER_SCAN_ROWS), it)]
    h = _header_index(head)
    if h is None:
        return []

    def data():
        n = h + 2
        for r in [*head[h + 1:], *it]:
            yield {"sheet": name, "row": n}, [_cell(v) for v in r]
            n += 1
    return rows_to_records(head[h], data(), "excel")


class ExcelParser:
    def parse(self, path: Path, report: Report) -> list[CandidateRecord]:
        with path.open("rb") as f:
            magic = f.read(8)
        if magic.startswith(b"PK\x03\x04"):
            sheets = self._xlsx(path)
        elif magic.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
            sheets = self._xls(path)
        else:
            raise FinalError("INVALID_FILE", "The file is not a valid Excel workbook.")

        records: list[CandidateRecord] = []
        for i, (name, total, rows) in enumerate(sheets, start=1):
            report(10 + 80 * (i - 1) // max(total, 1), f"Reading sheet {i} of {total}: {name}")
            records += _sheet_records(name, rows)
        return records

    @staticmethod
    def _xlsx(path: Path):
        import openpyxl
        from openpyxl.utils.exceptions import InvalidFileException
        from zipfile import BadZipFile
        try:
            wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        except (InvalidFileException, BadZipFile, KeyError, ValueError):
            raise FinalError("INVALID_FILE", "The Excel workbook could not be opened.")
        try:
            for ws in wb.worksheets:
                yield ws.title, len(wb.worksheets), (list(r) for r in ws.iter_rows(values_only=True))
        finally:
            wb.close()

    @staticmethod
    def _xls(path: Path):
        import xlrd
        try:
            wb = xlrd.open_workbook(path, on_demand=True)
        except xlrd.XLRDError:
            raise FinalError("INVALID_FILE", "The Excel workbook could not be opened.")

        def values(sheet):
            for r in range(sheet.nrows):
                row = []
                for c in sheet.row(r):
                    if c.ctype == xlrd.XL_CELL_DATE:
                        row.append(xlrd.xldate_as_datetime(c.value, wb.datemode))
                    elif c.ctype in (xlrd.XL_CELL_EMPTY, xlrd.XL_CELL_BLANK):
                        row.append(None)
                    elif c.ctype == xlrd.XL_CELL_ERROR:
                        row.append(xlrd.error_text_from_code.get(c.value, "#ERR"))
                    elif c.ctype == xlrd.XL_CELL_NUMBER and float(c.value).is_integer():
                        row.append(int(c.value))
                    else:
                        row.append(c.value)
                yield row
        try:
            names = wb.sheet_names()
            for name in names:
                yield name, len(names), values(wb.sheet_by_name(name))
        finally:
            wb.release_resources()
