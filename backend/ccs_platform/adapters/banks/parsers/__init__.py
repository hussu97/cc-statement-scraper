# Individual parser imports have been removed from this __init__ to avoid
# loading pdfplumber (~15 MB) at startup.  Import parsers directly from
# their submodules (e.g. `from .fab import parse_fab_statement`) or use
# the dispatcher: `from .dispatcher import parse_statement_for_bank`.
from .dispatcher import parse_statement_for_bank

__all__ = ["parse_statement_for_bank"]
