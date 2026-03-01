from __future__ import annotations

import enum

from sqlalchemy import Enum as SAEnum


def pg_enum(enum_cls: type[enum.Enum]) -> SAEnum:
    """Create a SQLAlchemy Enum that stores the Python enum's .value (lowercase)
    rather than its .name (uppercase), matching the Alembic migration definitions."""
    return SAEnum(enum_cls, values_callable=lambda obj: [e.value for e in obj])


class SourceType(str, enum.Enum):
    SCRAPE = "scrape"
    UPLOAD = "upload"


class ReferenceSource(str, enum.Enum):
    EXPLICIT = "explicit"
    FALLBACK = "fallback"


class MatchType(str, enum.Enum):
    CONTAINS = "contains"
    EXACT = "exact"
    REGEX = "regex"


class JobStatus(str, enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"


class JobType(str, enum.Enum):
    # DEPRECATED: no handler exists; runner raises ValueError if submitted.
    # Cannot be dropped from PostgreSQL enum — kept for DB compatibility only.
    SCRAPE = "scrape"
    UPLOAD = "upload"
    RECLASSIFY = "reclassify"
    EXPORT_WORKBOOK = "export_workbook"
    PARSER_VALIDATE = "parser_validate"
    # DEPRECATED: no handler exists; runner raises ValueError if submitted.
    # Cannot be dropped from PostgreSQL enum — kept for DB compatibility only.
    BANK_CONNECTION_TEST = "bank_connection_test"
    REPARSE_STATEMENT = "reparse_statement"


class Direction(str, enum.Enum):
    DEBIT = "debit"
    CREDIT = "credit"


class ScheduleStatus(str, enum.Enum):
    ACTIVE = "active"
    PAUSED = "paused"


class ExportStatus(str, enum.Enum):
    QUEUED = "queued"
    READY = "ready"
    FAILED = "failed"


class EmailProvider(str, enum.Enum):
    MICROSOFT = "microsoft"
    GMAIL = "gmail"


class EmailIngestionStatus(str, enum.Enum):
    QUEUED = "queued"
    UPLOADED = "uploaded"
    DUPLICATE = "duplicate"
    IGNORED = "ignored"
    FAILED = "failed"
