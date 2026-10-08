"""A tiny, dependency-free PDF writer for synthetic statements (audit SRV-24).

Every bank parser reads ``page.extract_text()`` lines (FAB also reads word positions), so
a PDF that places plain Helvetica text at fixed positions reproduces a statement layout
without any real statement data. Output is deterministic: the same input gives the same
bytes, so ``pdf_sha256`` and fallback statement references are stable.

A line is either a string (drawn at the left margin) or a list of ``(x, text)`` segments
for column layouts. ``pages`` is a list of pages, each a list of lines.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

Segment = tuple[float, str]
Line = str | Sequence[Segment]

PAGE_WIDTH = 595
PAGE_HEIGHT = 842
LEFT = 30
TOP = 810
LEADING = 13
FONT_SIZE = 8


def _escape(text: str) -> str:
    if not text.isascii():
        raise ValueError("synthetic PDFs are ASCII-only")
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _content(lines: Sequence[Line]) -> bytes:
    ops = ["BT", f"/F1 {FONT_SIZE} Tf"]
    y = TOP
    for line in lines:
        segments: Sequence[Segment] = [(LEFT, line)] if isinstance(line, str) else line
        for x, text in segments:
            # Absolute positioning per segment: Tm resets the text matrix.
            ops.append(f"1 0 0 1 {x:g} {y:g} Tm ({_escape(text)}) Tj")
        y -= LEADING
        if y < 20:
            raise ValueError("too many lines for one synthetic page")
    ops.append("ET")
    return "\n".join(ops).encode("ascii")


def build_pdf(pages: Sequence[Sequence[Line]]) -> bytes:
    """Return the bytes of a PDF with one page per entry of ``pages``."""
    n = len(pages)
    # Objects: 1 catalog, 2 pages, 3 font, then per page: page object + content stream.
    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % (4 + 2 * i) for i in range(n)) + b"] /Count %d >>" % n,
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    ]
    for i, lines in enumerate(pages):
        content = _content(lines)
        objects.append(
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R"
            b" /Resources << /Font << /F1 3 0 R >> >> >>" % (PAGE_WIDTH, PAGE_HEIGHT, 5 + 2 * i)
        )
        objects.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")

    pdf = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
    xref = len(pdf)
    pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        pdf += b"%010d 00000 n \n" % off
    pdf += b"trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(pdf)


def write_pdf(path: Path, pages: Sequence[Sequence[Line]], *, password: str | None = None) -> Path:
    """Write a synthetic PDF; with ``password``, encrypt it (AES-128) like an emailed statement."""
    data = build_pdf(pages)
    if password is None:
        path.write_bytes(data)
        return path
    import io

    from pypdf import PdfReader, PdfWriter

    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(data)))
    writer.encrypt(user_password=password, owner_password=None, algorithm="AES-128")
    with path.open("wb") as fh:
        writer.write(fh)
    return path
