"""Year inference for statement periods printed with two-digit years (ENBD / EIB).

ENBD prints the wrong year around the Dec/Jan boundary (audit DP-03/DP-04, X-06):

* January statement: ``Statement Period: 29-Dec-25 to 28-Jan-25`` (start year is the
  end's year, so start > end and the DB rejects the statement);
* December statement: ``Statement Period: 29-Nov-25 to 28-Dec-26`` (end year is the
  due date's year, a statement a year in the future).

Day and month are always right; the year is re-derived from a trustworthy anchor:
the summary row's ``Statement Date`` (DD/MM/YYYY, full year), else the newest
transaction posting date (full year), else the printed end date.
"""

from __future__ import annotations

from datetime import date, timedelta

# A posting can't be (much) after the statement closes.
_POSTING_GRACE = timedelta(days=7)


def _with_year(value: date, year: int) -> date | None:
    try:
        return value.replace(year=year)
    except ValueError:  # 29 Feb in a non-leap year
        return None


def _end_from_anchor(printed_end: date, anchor: date, *, at_or_after: date | None) -> date:
    candidates = [c for y in (anchor.year - 1, anchor.year, anchor.year + 1) if (c := _with_year(printed_end, y))]
    if at_or_after is not None:
        later = [c for c in candidates if c >= at_or_after]
        if later:
            return min(later)
    return min(candidates, key=lambda c: (abs((c - anchor).days), c)) if candidates else printed_end


def _start_before(printed_start: date, end: date) -> date:
    year = end.year if (printed_start.month, printed_start.day) <= (end.month, end.day) else end.year - 1
    return _with_year(printed_start, year) or printed_start


def resolve_period_years(
    printed_start: date | None,
    printed_end: date | None,
    *,
    statement_date: date | None = None,
    newest_posting: date | None = None,
) -> tuple[date | None, date | None, bool]:
    """Return ``(period_start, period_end, corrected)`` with consistent years.

    ``period_start <= period_end`` always holds for the result, the end lands on (or
    next to) the statement date, and it is never before the newest posting minus a
    week.
    """
    if printed_end is None:
        return printed_start, printed_end, False
    if statement_date is not None:
        end = _end_from_anchor(printed_end, statement_date, at_or_after=None)
    elif newest_posting is not None:
        end = _end_from_anchor(printed_end, newest_posting, at_or_after=newest_posting - _POSTING_GRACE)
    else:
        end = printed_end
    start = _start_before(printed_start, end) if printed_start is not None else None
    if start is not None and start > end:  # only reachable for odd 29-Feb inputs
        start = None
    return start, end, (start, end) != (printed_start, printed_end)
