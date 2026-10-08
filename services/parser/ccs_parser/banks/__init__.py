# Individual parsers are imported lazily by the dispatcher so pdfplumber is
# only loaded when a parse actually runs.
from .dispatcher import parse_statement_for_bank

__all__ = ["parse_statement_for_bank"]
