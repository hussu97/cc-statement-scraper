from __future__ import annotations

from ccs_platform.db import models
from ccs_platform.api.v1.schemas import StatementLineOut, StatementOut


def to_statement_out(
    statement: models.Statement,
    line_count: int = 0,
    total_debit_aed: float = 0.0,
    total_credit_aed: float = 0.0,
) -> StatementOut:
    return StatementOut(
        id=statement.id,
        bank_code=statement.bank_code,
        statement_reference=statement.statement_reference,
        statement_reference_raw=statement.statement_reference_raw,
        reference_source=statement.reference_source,
        statement_date=statement.statement_date,
        statement_period_start=statement.statement_period_start,
        statement_period_end=statement.statement_period_end,
        primary_card_last4=statement.primary_card_last4,
        card_holder=statement.card_holder,
        card_type=statement.card_type,
        pdf_file_id=statement.pdf_file_id,
        ingested_at=statement.ingested_at,
        line_count=line_count,
        total_debit_aed=total_debit_aed,
        total_credit_aed=total_credit_aed,
    )


def to_line_out(line: models.StatementLine) -> StatementLineOut:
    return StatementLineOut(
        id=line.id,
        statement_id=line.statement_id,
        line_no=line.line_no,
        transaction_date=line.transaction_date,
        transaction_time=line.transaction_time.isoformat(),
        is_time_inferred=line.is_time_inferred,
        posting_date=line.posting_date,
        merchant_raw=line.merchant_raw,
        merchant_normalized=line.merchant_normalized,
        amount_original=float(line.amount_original),
        currency_original=line.currency_original,
        amount_aed=float(line.amount_aed) if line.amount_aed is not None else None,
        direction=line.direction.value,
        transaction_kind=line.transaction_kind,
        country_code=line.country_code,
        card_last4=line.card_last4,
        category=line.category,
    )
