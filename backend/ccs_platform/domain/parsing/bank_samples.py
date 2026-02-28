"""Expected transaction counts for sample PDF files used by parser validation jobs.

These constants belong to the diagnostic/QA layer, not to the parser logic itself.
Update them whenever the sample PDFs used in parser_validate jobs are replaced.
"""

from __future__ import annotations

PARSER_SAMPLE_EXPECTED_COUNTS: dict[str, int] = {
    "FAB": 49,
    "ADCB": 9,
    "ENBD": 8,
}
