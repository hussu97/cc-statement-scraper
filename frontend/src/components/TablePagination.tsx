import { ChangeEvent } from 'react';

const PAGE_SIZE_OPTIONS = [100, 200, 500, 1000];

type TablePaginationProps = {
  page: number;
  pageSize: number;
  total: number;
  itemLabel?: string;
  disabled?: boolean;
  onPageChange: (nextPage: number) => void;
  onPageSizeChange: (nextPageSize: number) => void;
};

export function TablePagination({
  page,
  pageSize,
  total,
  itemLabel = 'rows',
  disabled = false,
  onPageChange,
  onPageSizeChange,
}: TablePaginationProps) {
  const totalPages = Math.max(1, Math.ceil(total / Math.max(pageSize, 1)));
  const safePage = Math.min(Math.max(page, 1), totalPages);
  const start = total === 0 ? 0 : (safePage - 1) * pageSize + 1;
  const end = total === 0 ? 0 : Math.min(total, safePage * pageSize);

  function handlePageSizeChange(event: ChangeEvent<HTMLSelectElement>) {
    const nextPageSize = Number(event.target.value);
    onPageSizeChange(nextPageSize);
  }

  return (
    <div className="row" style={{ justifyContent: 'space-between', alignItems: 'center', marginTop: '0.6rem' }}>
      <span className="muted">
        Showing {start}-{end} of {total} {itemLabel}
      </span>

      <div className="row" style={{ alignItems: 'center' }}>
        <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
          <span className="muted">Rows</span>
          <select value={pageSize} onChange={handlePageSizeChange} disabled={disabled}>
            {PAGE_SIZE_OPTIONS.map((size) => (
              <option key={size} value={size}>
                {size}
              </option>
            ))}
          </select>
        </label>

        <button
          className="ghost"
          onClick={() => onPageChange(Math.max(1, safePage - 1))}
          disabled={disabled || safePage <= 1}
        >
          Prev
        </button>
        <span className="muted">
          Page {safePage} / {totalPages}
        </span>
        <button
          className="ghost"
          onClick={() => onPageChange(Math.min(totalPages, safePage + 1))}
          disabled={disabled || safePage >= totalPages}
        >
          Next
        </button>
      </div>
    </div>
  );
}
