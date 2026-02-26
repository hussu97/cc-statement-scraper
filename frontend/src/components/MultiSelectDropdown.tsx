import { useEffect, useMemo, useRef, useState } from 'react';

type MultiSelectOption = {
  value: string;
  label: string;
};

function normalizeOptions(options: Array<string | MultiSelectOption>): MultiSelectOption[] {
  return options.map((option) => {
    if (typeof option === 'string') {
      return { value: option, label: option };
    }
    return option;
  });
}

export function MultiSelectDropdown({
  id,
  label,
  options,
  value,
  placeholder = 'Select one or more',
  onChange,
}: {
  id: string;
  label: string;
  options: Array<string | MultiSelectOption>;
  value: string[];
  placeholder?: string;
  onChange: (next: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);
  const normalizedOptions = useMemo(() => normalizeOptions(options), [options]);
  const selectedSet = useMemo(() => new Set(value), [value]);
  const selectedOptions = useMemo(
    () => normalizedOptions.filter((option) => selectedSet.has(option.value)),
    [normalizedOptions, selectedSet],
  );

  useEffect(() => {
    function onWindowClick(event: MouseEvent) {
      if (!rootRef.current) {
        return;
      }
      if (!rootRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    }

    window.addEventListener('mousedown', onWindowClick);
    return () => window.removeEventListener('mousedown', onWindowClick);
  }, []);

  function toggleValue(nextValue: string) {
    if (selectedSet.has(nextValue)) {
      onChange(value.filter((current) => current !== nextValue));
      return;
    }
    onChange([...value, nextValue]);
  }

  const summary =
    selectedOptions.length === 0
      ? placeholder
      : selectedOptions.length <= 2
        ? selectedOptions.map((item) => item.label).join(', ')
        : `${selectedOptions.slice(0, 2).map((item) => item.label).join(', ')} +${selectedOptions.length - 2}`;

  return (
    <div className="filter-field">
      <label htmlFor={id}>{label}</label>
      <div className="multi-dropdown" ref={rootRef}>
        <button
          id={id}
          type="button"
          className="multi-dropdown-trigger"
          onClick={() => setOpen((prev) => !prev)}
          aria-expanded={open}
          aria-haspopup="listbox"
        >
          <span className={selectedOptions.length ? '' : 'muted'}>{summary}</span>
          <span aria-hidden="true">{open ? '^' : 'v'}</span>
        </button>

        {open ? (
          <div className="multi-dropdown-menu" role="listbox" aria-multiselectable="true">
            {normalizedOptions.length === 0 ? (
              <p className="muted">No options</p>
            ) : (
              normalizedOptions.map((option) => (
                <label key={option.value} className="multi-dropdown-option">
                  <input
                    type="checkbox"
                    checked={selectedSet.has(option.value)}
                    onChange={() => toggleValue(option.value)}
                  />
                  <span>{option.label}</span>
                </label>
              ))
            )}
          </div>
        ) : null}
      </div>

      {selectedOptions.length ? (
        <div className="selected-chips">
          {selectedOptions.map((option) => (
            <button
              key={option.value}
              type="button"
              className="chip"
              onClick={() => toggleValue(option.value)}
            >
              {option.label} x
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}
