import { useEffect, useRef } from "react";
import { AlertTriangle, Loader2, RotateCw } from "lucide-react";
import { errorMessage } from "@/data/api";
import { formatCount } from "@/lib/money";
import { Button } from "./ui/button";

/**
 * The end of an infinite list: an invisible sentinel that loads the next page
 * when it nears the viewport, a spinner while it loads, a retry row when it
 * fails, and an end-of-list note. Loading only starts from the sentinel or the
 * retry button, never in a loop.
 */
export function InfiniteFooter({
  hasNextPage,
  isFetchingNextPage,
  isFetchNextPageError,
  error,
  fetchNextPage,
  loaded,
  noun = "items",
}: {
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  isFetchNextPageError: boolean;
  error: unknown;
  fetchNextPage: () => unknown;
  loaded: number;
  noun?: string;
}) {
  const sentinel = useRef<HTMLDivElement>(null);
  const canAutoLoad = hasNextPage && !isFetchingNextPage && !isFetchNextPageError;
  const load = useRef(fetchNextPage);
  useEffect(() => {
    load.current = fetchNextPage;
  });

  useEffect(() => {
    const el = sentinel.current;
    if (!el || !canAutoLoad || typeof IntersectionObserver === "undefined") return;
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) void load.current();
    }, { rootMargin: "600px 0px" });
    io.observe(el);
    return () => io.disconnect();
  }, [canAutoLoad, loaded]);

  return (
    <div className="px-4 py-4 text-center text-[13px] text-muted" aria-live="polite">
      <div ref={sentinel} aria-hidden className="h-px" />
      {isFetchingNextPage ? (
        <span role="status" className="inline-flex items-center gap-2">
          <Loader2 className="size-4 animate-spin" aria-hidden /> Loading more…
        </span>
      ) : isFetchNextPageError ? (
        <div role="alert" className="flex flex-col items-center gap-2">
          <span className="inline-flex items-center gap-1.5 text-danger">
            <AlertTriangle className="size-4" aria-hidden /> Couldn't load more. {errorMessage(error)}
          </span>
          <Button size="sm" variant="secondary" icon={<RotateCw className="size-3.5" />} onClick={() => void fetchNextPage()}>
            Try again
          </Button>
        </div>
      ) : hasNextPage ? (
        <Button size="sm" variant="ghost" onClick={() => void fetchNextPage()}>
          Load more
        </Button>
      ) : (
        <span className="tabular">
          {loaded > 0 ? `End of list · ${formatCount(loaded)} ${noun}` : "End of list"}        </span>
      )}
    </div>
  );
}
