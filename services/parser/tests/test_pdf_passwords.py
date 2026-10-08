"""X-17: every PDF password the web app stores reaches the parser that needs it."""

from __future__ import annotations

from pathlib import Path

import pytest

from ccs_parser import PASSWORD_SETTING_KEYS
from ccs_parser.domain.parsing.models import ParserError
from ccs_parser.service import parse_document
from tests.synthetic.cases import CASES, PASSWORD

ENCRYPTED = [("mashreq_encrypted", "MASHREQ", "MASHREQ_PDF_PASSWORD"), ("eib_encrypted", "EIB", "EIB_PDF_PASSWORD")]


def test_password_keys_match_the_profile_secret_allow_list() -> None:
    # public.set_profile_secret accepts ^(FAB|ADCB|ENBD|EIB|SIB|MASHREQ)_PDF_PASSWORD$ and ADCB_CID;
    # worker_document_context sends all of them as `settings`.
    banks = ("FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ")
    assert set(PASSWORD_SETTING_KEYS) == {f"{b}_PDF_PASSWORD" for b in banks} | {"ADCB_CID"}


@pytest.mark.parametrize(("case", "bank", "key"), ENCRYPTED)
@pytest.mark.parametrize("hint", [False, True])
def test_bank_password_opens_its_statement(case: str, bank: str, key: str, hint: bool, tmp_path: Path) -> None:
    pdf = CASES[case].write(tmp_path / "s.pdf")
    out = parse_document(pdf, bank_code_hint=bank if hint else None, settings={key: PASSWORD})
    assert out["bank_code"] == bank
    assert len(out["statements"][0]["lines"]) >= 4


@pytest.mark.parametrize(("case", "bank", "key"), ENCRYPTED)
@pytest.mark.parametrize("settings", [{}, {"FAB_PDF_PASSWORD": "not-it"}])
def test_without_the_password_the_failure_is_permanent(
    case: str, bank: str, key: str, settings: dict, tmp_path: Path
) -> None:
    pdf = CASES[case].write(tmp_path / "s.pdf")
    for hint in (None, bank):
        with pytest.raises(ParserError) as exc:
            parse_document(pdf, bank_code_hint=hint, settings=settings)
        assert exc.value.code == "PDF_DECRYPT_FAILED"
