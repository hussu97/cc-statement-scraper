import { ChevronLeft, ChevronRight } from "lucide-react";
import { PAGE_SIZES, pageCount, type PageSize } from "@/lib/pagination";
import { formatCount } from "@/lib/money";
import { Button } from "./ui/button";
import { Select } from "./ui/select";

export function Pagination({ page, size, total, onPage, onSize }: { page: number; size: PageSize; total: number; onPage: (p: number) => void; onSize: (s: PageSize) => void }) {
  const pages = pageCount(total, size);
  const from = total === 0 ? 0 : (page - 1) * size + 1;
  const to = Math.min(total, page * size);
  return (
    <nav aria-label="Pagination" className="flex flex-wrap items-center justify-between gap-3 px-1 py-3 text-[13px] text-muted">
      <span className="tabular">
        {formatCount(from)}–{formatCount(to)} of {formatCount(total)}
      </span>
      <div className="flex items-center gap-2">
        <Select
          size="sm"
          ariaLabel="Rows per page"
          value={String(size)}
          onValueChange={(v) => onSize(Number(v) as PageSize)}
          options={PAGE_SIZES.map((s) => ({ value: String(s), label: `${s} / page` }))}
          className="w-[116px]"
        />
        <Button size="icon-sm" variant="secondary" aria-label="Previous page" disabled={page <= 1} onClick={() => onPage(page - 1)}>
          <ChevronLeft className="size-4" />
        </Button>
        <span className="tabular min-w-14 text-center">
          {page} / {pages}
        </span>
        <Button size="icon-sm" variant="secondary" aria-label="Next page" disabled={page >= pages} onClick={() => onPage(page + 1)}>
          <ChevronRight className="size-4" />
        </Button>
      </div>
    </nav>
  );
}
