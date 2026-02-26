import { DashboardFilterMeta, DashboardFiltersValue } from '../types/dashboard';
import { DateRangeField } from './DateRangeField';
import { MultiSelectDropdown } from './MultiSelectDropdown';

export function DashboardFilters({
  value,
  meta,
  onChange,
}: {
  value: DashboardFiltersValue;
  meta: DashboardFilterMeta;
  onChange: (value: DashboardFiltersValue) => void;
}) {
  return (
    <div className="dashboard-filters">
      <DateRangeField
        idPrefix="dashboard-date-range"
        label="Transaction Date Range"
        value={{ from: value.dateFrom, to: value.dateTo }}
        min={meta.min_date}
        max={meta.max_date}
        onChange={(range) => onChange({ ...value, dateFrom: range.from, dateTo: range.to })}
      />

      <MultiSelectDropdown
        id="bank-codes"
        label="Banks"
        options={meta.banks}
        value={value.bankCodes}
        placeholder="All banks"
        onChange={(bankCodes) => onChange({ ...value, bankCodes })}
      />

      <MultiSelectDropdown
        id="categories"
        label="Categories"
        options={meta.categories}
        value={value.categories}
        placeholder="All categories"
        onChange={(categories) => onChange({ ...value, categories })}
      />

      <div className="filter-field filter-search">
        <label htmlFor="merchant-search">Merchant search</label>
        <input
          id="merchant-search"
          type="search"
          value={value.merchantSearch}
          placeholder="Search merchant text"
          onChange={(event) => onChange({ ...value, merchantSearch: event.target.value })}
        />
      </div>
    </div>
  );
}
