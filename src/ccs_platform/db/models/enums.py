from __future__ import annotations

import enum


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
    SCRAPE = "scrape"
    UPLOAD = "upload"
    RECLASSIFY = "reclassify"
    EXPORT_WORKBOOK = "export_workbook"
    PARSER_VALIDATE = "parser_validate"
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
