import { Dialog as D } from "radix-ui";
import { X } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

interface BaseProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: ReactNode;
  description?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  className?: string;
  /** Where focus goes when it closes (default: the trigger, if Radix knows it). */
  onCloseAutoFocus?: (e: Event) => void;
}

const OVERLAY = "fixed inset-0 z-40 bg-bg/70 animate-fade-in backdrop-blur-[2px]";

/** Title row shared by Dialog and Sheet: long titles wrap, never push the close button out. */
function Header({ title, description, fallback }: { title: ReactNode; description?: ReactNode; fallback: ReactNode }) {
  return (
    <header className="flex items-start justify-between gap-3 border-b border-border py-3 pr-3 pl-5 md:py-4">
      <div className="min-w-0 flex-1 pt-1">
        <D.Title className="font-display text-xl leading-snug text-ink [overflow-wrap:anywhere]">{title}</D.Title>
        {description ? (
          <D.Description className="mt-1 text-sm text-muted [overflow-wrap:anywhere]">{description}</D.Description>
        ) : (
          <D.Description className="sr-only">{fallback}</D.Description>
        )}
      </div>
      {/* 40px box (44px hit area via `tap`) so it is easy to hit on a phone. */}
      <D.Close className="tap flex size-10 shrink-0 items-center justify-center rounded-md text-muted hover:bg-surface-2 hover:text-ink" aria-label="Close">
        <X className="size-4" />
      </D.Close>
    </header>
  );
}

/** Centered modal dialog. Sized against the viewport box (%), never 100vw. */
export function Dialog({ open, onOpenChange, title, description, children, footer, className, onCloseAutoFocus }: BaseProps) {
  return (
    <D.Root open={open} onOpenChange={onOpenChange}>
      <D.Portal>
        <D.Overlay className={OVERLAY} />
        <D.Content
          onCloseAutoFocus={onCloseAutoFocus}
          className={cn(
            "fixed top-1/2 left-1/2 z-50 flex max-h-[calc(100dvh-32px)] w-[calc(100%-32px)] max-w-lg -translate-x-1/2 -translate-y-1/2 flex-col rounded-lg border border-border bg-surface animate-rise focus:outline-none",
            className,
          )}
        >
          <Header title={title} description={description} fallback={title} />
          <div className="min-w-0 overflow-x-hidden overflow-y-auto overscroll-contain px-5 py-4">{children}</div>
          {footer && <footer className="flex flex-wrap justify-end gap-2 border-t border-border px-5 py-3">{footer}</footer>}
        </D.Content>
      </D.Portal>
    </D.Root>
  );
}

/**
 * Side drawer on desktop (md+), bottom sheet on small screens. The sheet is
 * pinned to both viewport edges (never translated), its body clips sideways
 * so wide content scrolls inside it, and it clears the home indicator.
 */
export function Sheet({ open, onOpenChange, title, description, children, footer, className, onCloseAutoFocus }: BaseProps) {
  return (
    <D.Root open={open} onOpenChange={onOpenChange}>
      <D.Portal>
        <D.Overlay className={OVERLAY} />
        <D.Content
          onCloseAutoFocus={onCloseAutoFocus}
          className={cn(
            "fixed z-50 flex min-w-0 flex-col border-border bg-surface focus:outline-none",
            "inset-x-0 bottom-0 max-h-[92dvh] rounded-t-lg border-t animate-slide-in-up",
            "md:inset-y-0 md:right-0 md:left-auto md:max-h-none md:w-[480px] md:max-w-full md:rounded-none md:border-t-0 md:border-l md:animate-slide-in-right",
            className,
          )}
        >
          <Header title={title} description={description} fallback="Details" />
          <div
            className={cn(
              "min-w-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain px-5 pt-4",
              footer ? "pb-4" : "pb-[calc(1rem+env(safe-area-inset-bottom))]",
            )}
          >
            {children}
          </div>
          {footer && (
            <footer className="flex flex-wrap justify-end gap-2 border-t border-border px-5 pt-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))]">{footer}</footer>
          )}
        </D.Content>
      </D.Portal>
    </D.Root>
  );
}
