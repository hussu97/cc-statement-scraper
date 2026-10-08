import { useState, type ReactNode } from "react";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Eye } from "lucide-react";
import { PAGE_SIZES, normalizePageSize, pageCount, type PageSize } from "@/lib/pagination";
import { formatCount } from "@/lib/money";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Select } from "@/components/ui/select";
import { errorMessage } from "@/data/api";
import { cn } from "@/lib/cn";

/** Read and write `?tab=` on a tabbed screen. */
export function useTabParam(to: "/rules" | "/settings"): [string | undefined, (tab: string) => void] {
  const search = useSearch({ strict: false }) as { tab?: string };
  const navigate = useNavigate();
  return [search.tab, (tab: string) => void navigate({ to, search: { tab }, replace: true })];
}

/** Client-side page state with the standard sizes. Resets to page 1 when `resetKey` changes. */
export function usePager(resetKey: string) {
  const [state, setState] = useState<{ key: string; page: number; size: PageSize }>({ key: resetKey, page: 1, size: 100 });
  const page = state.key === resetKey ? state.page : 1;
  return {
    page,
    size: state.size,
    setPage: (p: number) => setState((s) => ({ ...s, key: resetKey, page: p })),
    setSize: (n: PageSize) => setState({ key: resetKey, page: 1, size: n }),
  };
}

export function Pager({
  total,
  page,
  size,
  onPage,
  onSize,
  noun = "rows",
}: {
  total: number;
  page: number;
  size: PageSize;
  onPage: (p: number) => void;
  onSize: (s: PageSize) => void;
  noun?: string;
}) {
  const pages = pageCount(total, size);
  if (total <= PAGE_SIZES[0]) return null;
  const from = (page - 1) * size + 1;
  const to = Math.min(total, page * size);
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border px-4 py-3 text-[13px] text-muted">
      <span className="tabular">
        {formatCount(from)}–{formatCount(to)} of {formatCount(total)} {noun}
      </span>
      <div className="flex items-center gap-2">
        <Select
          size="sm"
          ariaLabel="Rows per page"
          value={String(size)}
          onValueChange={(v) => onSize(normalizePageSize(v))}
          options={PAGE_SIZES.map((n) => ({ value: String(n), label: `${n} / page` }))}
          className="w-[7.5rem]"
        />
        <Button size="icon-sm" variant="ghost" aria-label="Previous page" disabled={page <= 1} onClick={() => onPage(page - 1)}>
          <ChevronLeft className="size-4" />
        </Button>
        <span className="tabular">
          {page} / {pages}
        </span>
        <Button size="icon-sm" variant="ghost" aria-label="Next page" disabled={page >= pages} onClick={() => onPage(page + 1)}>
          <ChevronRight className="size-4" />
        </Button>
      </div>
    </div>
  );
}

/** Confirmation for destructive or irreversible actions. */
export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  children,
  confirmLabel,
  onConfirm,
  pending,
  error,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: ReactNode;
  confirmLabel: string;
  onConfirm: () => void;
  pending?: boolean;
  error?: unknown;
}) {
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={title}
      className="max-w-md"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button variant="danger" loading={pending} onClick={onConfirm}>
            {confirmLabel}
          </Button>
        </>
      }
    >
      <div className="text-sm text-ink-2">{children}</div>
      {error ? <p className="mt-3 text-[13px] text-danger">{errorMessage(error)}</p> : null}
    </Dialog>
  );
}

/** Shown to viewers in place of write actions. */
export function ViewerNote({ children, className }: { children?: ReactNode; className?: string }) {
  return (
    <p className={cn("flex items-center gap-2 text-[13px] text-muted", className)}>
      <Eye className="size-3.5 shrink-0" aria-hidden />
      {children ?? "You can view this ledger. Only owners can make changes."}
    </p>
  );
}

/** Small labelled value used in list rows. */
export function Meta({ label, children, className }: { label: string; children: ReactNode; className?: string }) {
  return (
    <span className={cn("inline-flex items-baseline gap-1 text-[12px] text-muted", className)}>
      <span className="text-subtle">{label}</span>
      <span className="text-ink-2">{children}</span>
    </span>
  );
}
