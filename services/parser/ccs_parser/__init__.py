"""Stateless credit-card statement parsing service (contract: docs/contracts/parse-v1.md)."""

CONTRACT_VERSION = 1
PARSER_VERSION = "2026.10.6"

SUPPORTED_BANKS = ("FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ")

# Runtime-setting keys whose values are PDF passwords: the keys `set_profile_secret` accepts.
# Detection, page counting and totals try each of them; the bank parser uses its own key.
PASSWORD_SETTING_KEYS = (
    "FAB_PDF_PASSWORD",
    "ADCB_PDF_PASSWORD",
    "ADCB_CID",
    "ENBD_PDF_PASSWORD",
    "EIB_PDF_PASSWORD",
    "SIB_PDF_PASSWORD",
    "MASHREQ_PDF_PASSWORD",
)
