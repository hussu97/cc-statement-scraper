from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import BinaryIO, Union

from sqlalchemy import select
from sqlalchemy.orm import Session

from ccs_platform.db import models


SPEND_KINDS = {"purchase", "fee", "cash_advance", "refund"}


def _line_rows_for_year(db: Session, year: int, *, profile_id: int) -> list[dict]:
    rows: list[dict] = []
    query = (
        select(models.StatementLine, models.Statement)
        .join(models.Statement)
        .where(models.Statement.profile_id == profile_id)
        .where(models.Statement.statement_date >= date(year, 1, 1))
        .where(models.Statement.statement_date <= date(year, 12, 31))
    )
    for line, statement in db.execute(query).all():
        rows.append(
            {
                "statement_id": statement.id,
                "bank_code": statement.bank_code,
                "statement_reference": statement.statement_reference,
                "statement_date": statement.statement_date.isoformat(),
                "line_no": line.line_no,
                "transaction_date": line.transaction_date.isoformat(),
                "transaction_time": line.transaction_time.isoformat(),
                "posting_date": line.posting_date.isoformat() if line.posting_date else None,
                "merchant_raw": line.merchant_raw,
                "merchant_normalized": line.merchant_normalized,
                "amount_original": float(line.amount_original),
                "currency_original": line.currency_original,
                "amount_aed": float(line.amount_aed) if line.amount_aed is not None else None,
                "direction": line.direction.value,
                "transaction_kind": line.transaction_kind,
                "country_code": line.country_code,
                "card_last4": line.card_last4,
                "category": line.category,
                "is_time_inferred": line.is_time_inferred,
            }
        )
    return rows


def build_yearly_workbook_from_statements(
    db: Session, output_path: Union[Path, BinaryIO], year: int, *, profile_id: int
) -> Union[Path, BinaryIO]:
    import pandas as pd  # noqa: PLC0415 — lazy import to avoid loading pandas/numpy (~104 MB) at startup
    if isinstance(output_path, Path):
        output_path.parent.mkdir(parents=True, exist_ok=True)
    rows = _line_rows_for_year(db, year, profile_id=profile_id)

    tx_df = pd.DataFrame(rows)
    if tx_df.empty:
        tx_df = pd.DataFrame(
            columns=[
                "statement_id",
                "bank_code",
                "statement_reference",
                "statement_date",
                "line_no",
                "transaction_date",
                "transaction_time",
                "posting_date",
                "merchant_raw",
                "merchant_normalized",
                "amount_original",
                "currency_original",
                "amount_aed",
                "direction",
                "transaction_kind",
                "country_code",
                "card_last4",
                "category",
                "is_time_inferred",
            ]
        )
    else:
        tx_df["transaction_date"] = pd.to_datetime(tx_df["transaction_date"], errors="coerce")
        tx_df["posting_date"] = pd.to_datetime(tx_df["posting_date"], errors="coerce")
        tx_df["effective_date"] = tx_df["posting_date"].fillna(tx_df["transaction_date"])
        tx_df["posting_month"] = tx_df["effective_date"].dt.strftime("%Y-%m")

        tx_df["spend_amount"] = 0.0
        spend_mask = tx_df["transaction_kind"].isin(SPEND_KINDS)
        tx_df.loc[spend_mask, "spend_amount"] = tx_df.loc[spend_mask, "amount_aed"].fillna(0.0)

    monthly_bank_df = (
        tx_df.groupby(["posting_month", "bank_code"], dropna=False)["spend_amount"]
        .sum()
        .reset_index()
        .sort_values(["posting_month", "bank_code"])
        if not tx_df.empty
        else pd.DataFrame(columns=["posting_month", "bank_code", "spend_amount"])
    )

    monthly_category_df = (
        tx_df.groupby(["posting_month", "category"], dropna=False)["spend_amount"]
        .sum()
        .reset_index()
        .sort_values(["posting_month", "category"])
        if not tx_df.empty
        else pd.DataFrame(columns=["posting_month", "category", "spend_amount"])
    )

    top_merchants_df = (
        tx_df.groupby(["merchant_normalized"], dropna=False)["spend_amount"]
        .sum()
        .reset_index()
        .sort_values("spend_amount", ascending=False)
        .head(100)
        if not tx_df.empty
        else pd.DataFrame(columns=["merchant_normalized", "spend_amount"])
    )

    fx_gaps_df = (
        tx_df[
            (tx_df["currency_original"].fillna("AED") != "AED")
            & tx_df["amount_aed"].isna()
        ].copy()
        if not tx_df.empty
        else pd.DataFrame(columns=tx_df.columns)
    )

    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        tx_df.to_excel(writer, sheet_name="Transactions", index=False)
        monthly_bank_df.to_excel(writer, sheet_name="MonthlyBankSpend", index=False)
        monthly_category_df.to_excel(writer, sheet_name="MonthlyCategorySpend", index=False)
        top_merchants_df.to_excel(writer, sheet_name="TopMerchants", index=False)
        fx_gaps_df.to_excel(writer, sheet_name="FXGaps", index=False)

    return output_path


def build_yearly_csv_bytes(db: Session, year: int, *, profile_id: int) -> bytes:
    """Return a UTF-8 CSV of all transaction rows for *year* as raw bytes."""
    import pandas as pd  # noqa: PLC0415

    rows = _line_rows_for_year(db, year, profile_id=profile_id)
    df = pd.DataFrame(rows) if rows else pd.DataFrame(
        columns=[
            "statement_id", "bank_code", "statement_reference", "statement_date",
            "line_no", "transaction_date", "transaction_time", "posting_date",
            "merchant_raw", "merchant_normalized", "amount_original", "currency_original",
            "amount_aed", "direction", "transaction_kind", "country_code",
            "card_last4", "category", "is_time_inferred",
        ]
    )
    return df.to_csv(index=False).encode("utf-8")
