import { Toast as T } from "radix-ui";
import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import { X } from "lucide-react";
import { cn } from "@/lib/cn";

type ToastTone = "neutral" | "positive" | "danger";
interface ToastItem {
  id: number;
  title: string;
  description?: string;
  tone: ToastTone;
}

const ToastContext = createContext<(t: Omit<ToastItem, "id" | "tone"> & { tone?: ToastTone }) => void>(() => {});

export function Toaster({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const push = useCallback((t: Omit<ToastItem, "id" | "tone"> & { tone?: ToastTone }) => {
    setItems((l) => [...l.slice(-3), { id: Date.now() + Math.random(), tone: "neutral", ...t }]);
  }, []);
  return (
    <ToastContext.Provider value={push}>
      <T.Provider swipeDirection="right" duration={4500}>
        {children}
        {items.map((t) => (
          <T.Root
            key={t.id}
            onOpenChange={(open) => !open && setItems((l) => l.filter((x) => x.id !== t.id))}
            className={cn(
              "flex items-start gap-3 rounded-md border bg-surface px-4 py-3 shadow-[0_12px_32px_-16px_var(--color-border-strong)] animate-rise",
              t.tone === "danger" ? "border-danger" : t.tone === "positive" ? "border-positive" : "border-border",
            )}
          >
            <div className="min-w-0 flex-1">
              <T.Title className="text-sm font-medium text-ink [overflow-wrap:anywhere]">{t.title}</T.Title>
              {t.description && <T.Description className="mt-0.5 text-[13px] text-muted [overflow-wrap:anywhere]">{t.description}</T.Description>}
            </div>
            <T.Close aria-label="Dismiss" className="tap -m-1 rounded-sm p-1 text-muted hover:text-ink">
              <X className="size-4" />
            </T.Close>
          </T.Root>
        ))}
        {/* Phones: full width above the tab bar and the home indicator. Desktop: bottom-right, 360px. */}
        <T.Viewport className="fixed inset-x-4 bottom-[calc(4.5rem+env(safe-area-inset-bottom))] z-[60] flex flex-col gap-2 outline-none md:left-auto md:w-[360px] lg:bottom-4" />
      </T.Provider>
    </ToastContext.Provider>
  );
}

export function useToast() {
  return useContext(ToastContext);
}
