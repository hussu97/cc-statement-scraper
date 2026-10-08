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
              <T.Title className="text-sm font-medium text-ink">{t.title}</T.Title>
              {t.description && <T.Description className="mt-0.5 text-[13px] text-muted">{t.description}</T.Description>}
            </div>
            <T.Close aria-label="Dismiss" className="text-muted hover:text-ink">
              <X className="size-4" />
            </T.Close>
          </T.Root>
        ))}
        <T.Viewport className="fixed right-4 bottom-20 z-[60] flex w-[min(360px,calc(100vw-32px))] flex-col gap-2 outline-none md:bottom-4" />
      </T.Provider>
    </ToastContext.Provider>
  );
}

export function useToast() {
  return useContext(ToastContext);
}
