"""Module-level functions for test_limits.py (isolated children import them by reference)."""

from __future__ import annotations

import time
import zlib
from pathlib import Path

from ccs_parser.domain.parsing.models import ParserError


def add(a: int, b: int) -> dict:
    return {"sum": a + b}


def raise_parser_error() -> None:
    raise ParserError("UNSUPPORTED_LAYOUT", "layout not recognised")


def raise_secret_value_error() -> None:
    raise ValueError("CARREFOUR 1234 secret statement text")


def burn_cpu() -> None:
    x = 0
    while True:
        x += 1


def sleep_forever() -> None:
    time.sleep(3600)


def read_env(name: str) -> str | None:
    import os

    return os.environ.get(name)


def inflate_through_pdfminer(n_bytes: int) -> int:
    import pdfminer.pdftypes as pdftypes

    return len(pdftypes.zlib.decompress(zlib.compress(b"q Q\n" * (n_bytes // 4), 9)))


def make_bomb_pdf(path: Path, n_mb: int) -> Path:
    """One page whose Flate content stream inflates to ``n_mb`` MB of ``q Q`` operators (audit SRV-01)."""
    raw = b"q Q\n" * (n_mb * 1024 * 1024 // 4)
    comp = zlib.compress(raw, 9)
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>",
        b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(comp) + comp + b"\nendstream",
    ]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objs, 1):
        offsets.append(len(pdf))
        pdf += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
    xref = len(pdf)
    pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        pdf += b"%010d 00000 n \n" % off
    pdf += b"trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    path.write_bytes(bytes(pdf))
    return path


def make_blank_pdf(path: Path, pages: int) -> Path:
    from pypdf import PdfWriter

    writer = PdfWriter()
    for _ in range(pages):
        writer.add_blank_page(width=612, height=792)
    with path.open("wb") as fh:
        writer.write(fh)
    return path
