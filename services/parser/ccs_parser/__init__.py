"""Stateless credit-card statement parsing service (contract: docs/contracts/parse-v1.md)."""

CONTRACT_VERSION = 1
PARSER_VERSION = "2026.10.0"

SUPPORTED_BANKS = ("FAB", "ADCB", "ENBD", "EIB", "SIB", "MASHREQ")

# Runtime-setting keys whose values are PDF passwords (same keys as the legacy backend).
PASSWORD_SETTING_KEYS = ("FAB_PDF_PASSWORD", "ADCB_PDF_PASSWORD", "ADCB_CID", "ENBD_PDF_PASSWORD", "SIB_PDF_PASSWORD")
