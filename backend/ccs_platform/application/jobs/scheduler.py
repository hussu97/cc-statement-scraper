from __future__ import annotations

from datetime import UTC, datetime
from zoneinfo import ZoneInfo

from dateutil.rrule import rrulestr


def compute_next_run(rrule: str, *, timezone: str, now_utc: datetime | None = None) -> datetime:
    now_utc = now_utc or datetime.now(UTC)
    tz = ZoneInfo(timezone)
    now_local_naive = now_utc.astimezone(tz).replace(tzinfo=None)
    rule = rrulestr(rrule, dtstart=now_local_naive, ignoretz=True)
    next_dt = rule.after(now_local_naive)
    if next_dt is None:
        raise ValueError("RRULE produces no future occurrences")
    return next_dt.replace(tzinfo=tz).astimezone(UTC)
