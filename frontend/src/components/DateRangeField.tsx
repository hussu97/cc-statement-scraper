import { useEffect, useMemo, useRef, useState } from 'react';

import {
  DateRangePicker,
  createStaticRanges,
  type Range,
} from 'react-date-range';
import {
  endOfMonth,
  isSameDay,
  startOfDay,
  startOfMonth,
  subDays,
} from 'date-fns';

export type DateRangeValue = {
  from: string;
  to: string;
};

function parseIso(value: string | null | undefined): Date | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return null;
  }
  const [year, month, day] = value.split('-').map(Number);
  const parsed = new Date(year, month - 1, day);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return startOfDay(parsed);
}

function toIso(value: Date | null | undefined): string {
  if (!value) {
    return '';
  }
  const year = value.getFullYear();
  const month = String(value.getMonth() + 1).padStart(2, '0');
  const day = String(value.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function clampDate(value: Date, minDate: Date | null, maxDate: Date | null): Date {
  if (minDate && value < minDate) {
    return minDate;
  }
  if (maxDate && value > maxDate) {
    return maxDate;
  }
  return value;
}

function normalizeRange(
  start: Date | null | undefined,
  end: Date | null | undefined,
  minDate: Date | null,
  maxDate: Date | null,
): Range {
  const safeStart = clampDate(start ?? maxDate ?? minDate ?? new Date(), minDate, maxDate);
  const safeEnd = clampDate(end ?? safeStart, minDate, maxDate);
  if (safeEnd < safeStart) {
    return { startDate: safeEnd, endDate: safeStart, key: 'selection' };
  }
  return { startDate: safeStart, endDate: safeEnd, key: 'selection' };
}

function rangeToValue(range: Range): DateRangeValue {
  return {
    from: toIso(range.startDate),
    to: toIso(range.endDate),
  };
}

function valueToRange(value: DateRangeValue, minDate: Date | null, maxDate: Date | null): Range {
  const start = parseIso(value.from);
  const end = parseIso(value.to);
  if (!start && !end) {
    return normalizeRange(maxDate ?? minDate ?? new Date(), maxDate ?? minDate ?? new Date(), minDate, maxDate);
  }
  return normalizeRange(start ?? end, end ?? start, minDate, maxDate);
}

function summarizeRange(value: DateRangeValue, min?: string | null, max?: string | null): string {
  if (!value.from && !value.to) {
    return min || max ? 'All available dates' : 'All dates';
  }
  const from = parseIso(value.from);
  const to = parseIso(value.to);
  const formatter = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
  if (from && to) {
    return `${formatter.format(from)} ~ ${formatter.format(to)}`;
  }
  if (from) {
    return `From ${formatter.format(from)}`;
  }
  if (to) {
    return `Until ${formatter.format(to)}`;
  }
  return 'All dates';
}

function clampedPair(start: Date, end: Date, minDate: Date | null, maxDate: Date | null): { startDate: Date; endDate: Date } {
  const safeStart = clampDate(startOfDay(start), minDate, maxDate);
  const safeEnd = clampDate(startOfDay(end), minDate, maxDate);
  if (safeEnd < safeStart) {
    return { startDate: safeEnd, endDate: safeStart };
  }
  return { startDate: safeStart, endDate: safeEnd };
}

function isSameRange(range: Range, other: { startDate: Date; endDate: Date }): boolean {
  if (!range.startDate || !range.endDate) {
    return false;
  }
  return isSameDay(range.startDate, other.startDate) && isSameDay(range.endDate, other.endDate);
}

export function DateRangeField({
  idPrefix,
  label,
  value,
  min,
  max,
  onChange,
}: {
  idPrefix: string;
  label: string;
  value: DateRangeValue;
  min?: string | null;
  max?: string | null;
  onChange: (next: DateRangeValue) => void;
}) {
  const [open, setOpen] = useState(false);
  const minDate = useMemo(() => parseIso(min), [min]);
  const maxDate = useMemo(() => parseIso(max), [max]);
  const [draft, setDraft] = useState<Range>(() => valueToRange(value, minDate, maxDate));
  const [compact, setCompact] = useState(() => window.matchMedia('(max-width: 1080px)').matches);
  const rootRef = useRef<HTMLDivElement | null>(null);

  const triggerId = `${idPrefix}-trigger`;
  const popoverId = `${idPrefix}-popover`;
  const summary = useMemo(() => summarizeRange(value, min, max), [max, min, value]);

  const staticRanges = useMemo(() => {
    const anchor = maxDate ?? startOfDay(new Date());
    const today = clampedPair(anchor, anchor, minDate, maxDate);
    const yesterday = clampedPair(subDays(anchor, 1), subDays(anchor, 1), minDate, maxDate);
    const last7 = clampedPair(subDays(anchor, 6), anchor, minDate, maxDate);
    const last30 = clampedPair(subDays(anchor, 29), anchor, minDate, maxDate);
    const thisMonth = clampedPair(startOfMonth(anchor), anchor, minDate, maxDate);
    const previousMonthDay = subDays(startOfMonth(anchor), 1);
    const lastMonth = clampedPair(startOfMonth(previousMonthDay), endOfMonth(previousMonthDay), minDate, maxDate);

    return createStaticRanges([
      {
        label: 'Today',
        range: () => today,
        isSelected: (range: Range) => isSameRange(range, today),
      },
      {
        label: 'Yesterday',
        range: () => yesterday,
        isSelected: (range: Range) => isSameRange(range, yesterday),
      },
      {
        label: 'Last 7 Days',
        range: () => last7,
        isSelected: (range: Range) => isSameRange(range, last7),
      },
      {
        label: 'Last 30 Days',
        range: () => last30,
        isSelected: (range: Range) => isSameRange(range, last30),
      },
      {
        label: 'This Month',
        range: () => thisMonth,
        isSelected: (range: Range) => isSameRange(range, thisMonth),
      },
      {
        label: 'Last Month',
        range: () => lastMonth,
        isSelected: (range: Range) => isSameRange(range, lastMonth),
      },
    ]);
  }, [maxDate, minDate]);

  useEffect(() => {
    function handleOutside(event: MouseEvent) {
      if (!rootRef.current) {
        return;
      }
      if (!rootRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    }

    window.addEventListener('mousedown', handleOutside);
    return () => window.removeEventListener('mousedown', handleOutside);
  }, []);

  useEffect(() => {
    const media = window.matchMedia('(max-width: 1080px)');
    const onResize = () => setCompact(media.matches);
    onResize();
    media.addEventListener('change', onResize);
    return () => media.removeEventListener('change', onResize);
  }, []);

  useEffect(() => {
    if (open) {
      setDraft(valueToRange(value, minDate, maxDate));
    }
  }, [maxDate, minDate, open, value]);

  function applyChanges() {
    onChange(rangeToValue(normalizeRange(draft.startDate, draft.endDate, minDate, maxDate)));
    setOpen(false);
  }

  function cancelChanges() {
    setDraft(valueToRange(value, minDate, maxDate));
    setOpen(false);
  }

  function clearSelection() {
    const empty: DateRangeValue = { from: '', to: '' };
    onChange(empty);
    setDraft(valueToRange(empty, minDate, maxDate));
  }

  function handlePickerChange(payload: { selection?: Range }) {
    const selection = payload.selection;
    if (!selection) {
      return;
    }
    setDraft(
      normalizeRange(
        selection.startDate ?? draft.startDate,
        selection.endDate ?? selection.startDate ?? draft.endDate,
        minDate,
        maxDate,
      ),
    );
  }

  const selectedRange = useMemo(
    () => normalizeRange(draft.startDate, draft.endDate, minDate, maxDate),
    [draft.endDate, draft.startDate, maxDate, minDate],
  );

  return (
    <div className="filter-field">
      <label htmlFor={triggerId}>{label}</label>
      <div className="date-range-native" ref={rootRef}>
        <div className="date-range-native-trigger-row">
          <button
            id={triggerId}
            type="button"
            className="date-range-native-trigger"
            aria-expanded={open}
            aria-controls={popoverId}
            onClick={() => setOpen((prev) => !prev)}
          >
            <span className={value.from || value.to ? '' : 'muted'}>{summary}</span>
          </button>
          {value.from || value.to ? (
            <button
              type="button"
              className="date-range-native-clear"
              aria-label="Clear date range"
              onClick={clearSelection}
            >
              x
            </button>
          ) : null}
        </div>

        {open ? (
          <div id={popoverId} className="date-range-native-popover">
            <DateRangePicker
              ranges={[selectedRange]}
              onChange={handlePickerChange}
              minDate={minDate ?? undefined}
              maxDate={maxDate ?? undefined}
              staticRanges={staticRanges}
              inputRanges={[]}
              months={compact ? 1 : 2}
              direction={compact ? 'vertical' : 'horizontal'}
              showDateDisplay={false}
              editableDateInputs
              moveRangeOnFirstSelection={false}
              rangeColors={['#5f6de6']}
            />
            <div className="date-range-native-footer">
              <button type="button" className="ghost" onClick={cancelChanges}>
                Cancel
              </button>
              <button type="button" className="primary" onClick={applyChanges}>
                Apply
              </button>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
