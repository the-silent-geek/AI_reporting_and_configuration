"""Positioned words -> table rows or label/value forms. Used for both native PDF
text and OCR output, so a scanned table and a digital one give the same records.

  words + positions
    -> lines   (similar vertical centre)
    -> cells   (words closer than ~1.5 characters join)
    -> header  (first mostly-text line with >= 2 cells followed by more multi-cell lines)
    -> columns (header cell x-ranges); each later cell goes to the column it overlaps most
    -> drop repeated headers, totals, blank lines; join wrapped cell text to the row above
  No table on a page -> "Label: value" / two-cell lines become one form record.
"""
import re
from dataclasses import dataclass, field
from statistics import mean, median
from typing import Literal

Source = Literal["pdf_text", "ocr"]

_TOTAL = re.compile(r"^(sub\s*-?\s*total|grand\s+total|total|balance\s+c/?f|carried\s+forward)\b", re.I)


@dataclass(frozen=True)
class Word:
    text: str
    x0: float
    top: float
    x1: float
    bottom: float
    source: Source
    confidence: float | None = None   # OCR only


@dataclass
class Cell:
    words: list[Word]

    @property
    def text(self) -> str: return " ".join(w.text for w in self.words)
    @property
    def x0(self) -> float: return min(w.x0 for w in self.words)
    @property
    def x1(self) -> float: return max(w.x1 for w in self.words)


@dataclass
class Line:
    cells: list[Cell]

    @property
    def words(self) -> list[Word]: return [w for c in self.cells for w in c.words]
    @property
    def top(self) -> float: return min(w.top for w in self.words)
    @property
    def bottom(self) -> float: return max(w.bottom for w in self.words)


@dataclass
class Row:
    """One reconstructed record before it becomes a CandidateRecord."""
    kind: Literal["table", "form"]
    table: int
    row: int
    fields: dict[str, str]
    words: list[Word] = field(default_factory=list)

    @property
    def bbox(self) -> list[float]:
        return [round(min(w.x0 for w in self.words), 1), round(min(w.top for w in self.words), 1),
                round(max(w.x1 for w in self.words), 1), round(max(w.bottom for w in self.words), 1)]

    @property
    def source(self) -> Source:
        return "ocr" if any(w.source == "ocr" for w in self.words) else "pdf_text"

    @property
    def confidence(self) -> float | None:
        scores = [w.confidence for w in self.words if w.confidence is not None]
        return round(mean(scores), 4) if scores else None


@dataclass
class Columns:
    names: list[str]
    spans: list[tuple[float, float]]
    table: int


def to_lines(words: list[Word]) -> list[Line]:
    words = [w for w in words if w.text.strip()]
    if not words:
        return []
    height = median(w.bottom - w.top for w in words) or 1.0
    char_w = median((w.x1 - w.x0) / max(len(w.text), 1) for w in words) or 1.0

    groups: list[list[Word]] = []
    for w in sorted(words, key=lambda w: (w.top + w.bottom) / 2):
        centre = (w.top + w.bottom) / 2
        if groups and abs(centre - mean((g.top + g.bottom) / 2 for g in groups[-1])) <= height * 0.5:
            groups[-1].append(w)
        else:
            groups.append([w])

    lines = []
    for g in groups:
        cells: list[Cell] = []
        for w in sorted(g, key=lambda w: w.x0):
            if cells and w.x0 - cells[-1].x1 <= char_w * 1.5:
                cells[-1].words.append(w)
            else:
                cells.append(Cell([w]))
        lines.append(Line(cells))
    return lines


def _is_header(line: Line, following: list[Line]) -> bool:
    if len(line.cells) < 2:
        return False
    texts = [c.text for c in line.cells]
    if sum(any(ch.isdigit() for ch in t) for t in texts) > len(texts) // 3:   # ids, amounts, dates = data
        return False
    return sum(len(l.cells) >= 2 for l in following[:3]) >= min(2, len(following))


def _column_of(cell: Cell, spans: list[tuple[float, float]]) -> int:
    overlaps = [min(cell.x1, x1) - max(cell.x0, x0) for x0, x1 in spans]
    best = max(range(len(spans)), key=overlaps.__getitem__)
    if overlaps[best] > 0:
        return best
    centre = (cell.x0 + cell.x1) / 2
    return min(range(len(spans)), key=lambda i: abs(centre - (spans[i][0] + spans[i][1]) / 2))


def _form(lines: list[Line]) -> dict[str, tuple[str, list[Word]]]:
    pairs: dict[str, tuple[str, list[Word]]] = {}
    for line in lines:
        text = " ".join(c.text for c in line.cells)
        if ":" in line.cells[0].text:
            label, _, value = text.partition(":")
        elif len(line.cells) == 2:
            label, value = line.cells[0].text, line.cells[1].text
        else:
            continue
        label, value = label.strip(), value.strip()
        if label and value and label not in pairs:
            pairs[label] = (value, line.words)
    return pairs


def build_rows(words: list[Word], carry: Columns | None, next_table: int) -> tuple[list[Row], Columns | None]:
    """Rows for one page. `carry` = columns of a table still open from the previous page
    (multi-page tables often repeat the header, sometimes they don't)."""
    lines = to_lines(words)
    rows: list[Row] = []
    columns = carry
    start = 0
    for i, line in enumerate(lines):
        if _is_header(line, lines[i + 1:]):
            names = [c.text for c in line.cells]
            if not (carry and [n.lower() for n in names] == [n.lower() for n in carry.names]):
                columns = Columns(names, [(c.x0, c.x1) for c in line.cells], next_table)
            start = i + 1
            break
    else:
        if carry is None or not any(len(l.cells) >= 2 for l in lines):
            pairs = _form(lines)
            if len(pairs) >= 2:
                rows.append(Row("form", next_table, 1, {k: v for k, (v, _) in pairs.items()},
                                [w for _, ws in pairs.values() for w in ws]))
            return rows, None

    header_lc = [n.lower() for n in columns.names]
    height = median(l.bottom - l.top for l in lines) or 1.0
    n, prev, prev_line = 0, None, None
    for line in lines[start:]:
        if [c.text.lower() for c in line.cells] == header_lc:
            continue                                     # header repeated mid-page
        if _TOTAL.match(line.cells[0].text):
            continue
        values: dict[int, list[Cell]] = {}
        for cell in line.cells:
            values.setdefault(_column_of(cell, columns.spans), []).append(cell)

        wrapped = (prev is not None and prev_line is not None
                   and len(values) < max(2, len(columns.names) // 2)
                   and line.top - prev_line.bottom < height * 0.8
                   and all(prev.fields.get(columns.names[c]) for c in values))
        if wrapped:
            for c, cells in values.items():
                name = columns.names[c]
                prev.fields[name] += " " + " ".join(x.text for x in cells)
                prev.words += [w for x in cells for w in x.words]
            prev_line = line
            continue
        if len(values) < 2 and len(columns.names) >= 3:
            continue                                     # stray text (page number, note) in the table area

        n += 1
        prev = Row("table", columns.table, n,
                   {name: " ".join(x.text for x in values.get(c, [])) for c, name in enumerate(columns.names)},
                   line.words)
        prev_line = line
        rows.append(prev)
    return rows, columns
