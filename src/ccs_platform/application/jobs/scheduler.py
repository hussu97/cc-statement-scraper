from __future__ import annotations

from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo

DAY_TO_WEEKDAY = {
    "MO": 0,
    "TU": 1,
    "WE": 2,
    "TH": 3,
    "FR": 4,
    "SA": 5,
    "SU": 6,
}


def parse_rrule(rrule: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for chunk in rrule.split(";"):
        if "=" not in chunk:
            continue
        key, raw_value = chunk.split("=", 1)
        values[key.upper().strip()] = raw_value.strip()
    return values


def compute_next_run(rrule: str, *, timezone: str, now_utc: datetime | None = None) -> datetime:
    parts = parse_rrule(rrule)
    freq = parts.get("FREQ", "").upper()
    if not freq:
        raise ValueError("RRULE missing FREQ")

    now_utc = now_utc or datetime.now(UTC)
    tz = ZoneInfo(timezone)
    now_local = now_utc.astimezone(tz)

    if freq == "HOURLY":
        interval = int(parts.get("INTERVAL", "1"))
        if interval <= 0:
            raise ValueError("INTERVAL must be > 0")
        candidate = now_local.replace(minute=0, second=0, microsecond=0) + timedelta(hours=interval)
        return candidate.astimezone(UTC)

    if freq == "WEEKLY":
        byday = [token.strip().upper() for token in parts.get("BYDAY", "").split(",") if token.strip()]
        if not byday:
            raise ValueError("WEEKLY schedules require BYDAY")
        byhour = int(parts.get("BYHOUR", "0"))
        byminute = int(parts.get("BYMINUTE", "0"))

        weekdays = sorted(DAY_TO_WEEKDAY[token] for token in byday if token in DAY_TO_WEEKDAY)
        if not weekdays:
            raise ValueError("BYDAY contains no valid weekdays")

        for day_offset in range(0, 14):
            candidate_day = now_local.date() + timedelta(days=day_offset)
            if candidate_day.weekday() not in weekdays:
                continue
            candidate = datetime(
                year=candidate_day.year,
                month=candidate_day.month,
                day=candidate_day.day,
                hour=byhour,
                minute=byminute,
                tzinfo=tz,
            )
            if candidate > now_local:
                return candidate.astimezone(UTC)

        raise ValueError("Unable to compute next WEEKLY run")

    raise ValueError(f"Unsupported RRULE frequency: {freq}")
