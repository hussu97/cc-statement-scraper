import { Link } from "@tanstack/react-router";
import { PiggyBank } from "lucide-react";
import { holdingErrorMessage, useHoldingsValuation, useLinkTransaction } from "@/data/holdings";
import { holdingsForLinking } from "@/lib/investments";
import { cn } from "@/lib/cn";
import { Badge } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { useToast } from "@/components/ui/toast";

const NONE = "__none";

/** A linked payment's chip: the holding it pays into (it counts as saving). */
export function HoldingChip({ name, className }: { name: string | null | undefined; className?: string }) {
  if (!name) return null;
  return (
    <Badge tone="accent" className={cn("max-w-48", className)} title={`Saving into ${name}`}>
      <PiggyBank aria-hidden className="size-3 shrink-0" />
      <span className="truncate">{name}</span>
    </Badge>
  );
}

/**
 * The transaction drawer's "Link to investment": pick an active holding to link the payment to
 * (it becomes saving, not spending), or unlink it (for good: the holding's rule won't link it
 * again). Viewers see the link only.
 */
export function HoldingLinkControl({
  profileCode,
  isOwner,
  txn,
}: {
  profileCode: string;
  isOwner: boolean;
  txn: { txn_code: string; holding_code?: string | null; holding_name?: string | null; amount_aed?: number | string | null; status?: string | null };
}) {
  const holdings = useHoldingsValuation(profileCode);
  const link = useLinkTransaction(profileCode);
  const toast = useToast();
  const linked = txn.holding_code ?? null;
  const priced = txn.amount_aed !== null && txn.amount_aed !== undefined && txn.status !== "void";

  const go = (holdingCode: string | null) => {
    const name = holdingCode ? holdings.data?.holdings.find((h) => h.holding_code === holdingCode)?.name : txn.holding_name;
    link.mutate(
      { txnCode: txn.txn_code, holdingCode },
      {
        onSuccess: () =>
          toast({
            title: holdingCode ? `Linked to ${name ?? "the investment"}` : "Unlinked",
            description: holdingCode ? "It counts as saving now, not spending." : "It counts by its category again; the link rule won't link it again.",
            tone: "positive",
          }),
        onError: (e) => toast({ title: holdingCode ? "Couldn't link it" : "Couldn't unlink it", description: holdingErrorMessage(e), tone: "danger" }),
      },
    );
  };

  if (!isOwner) {
    return linked ? (
      <Link to="/wealth/investments/$holdingCode" params={{ holdingCode: linked }} className="text-accent hover:underline">
        {txn.holding_name ?? "Investment"}
      </Link>
    ) : (
      <span className="text-muted">Not linked</span>
    );
  }

  const active = holdingsForLinking(holdings.data?.holdings ?? []);
  const options = [{ value: NONE, label: "Not linked" }, ...active.map((h) => ({ value: h.holding_code, label: h.name }))];
  // A closed holding still names the link it holds.
  if (linked && !active.some((h) => h.holding_code === linked)) options.push({ value: linked, label: txn.holding_name ?? "Closed holding" });

  return (
    <div className="flex flex-col gap-1">
      <div className="flex flex-wrap items-center gap-2">
        <Select
          ariaLabel="Link to investment"
          size="sm"
          className="w-56 max-w-full"
          value={linked ?? NONE}
          disabled={!priced || link.isPending || holdings.isLoading}
          onValueChange={(v) => go(v === NONE ? null : v)}
          options={options}
        />
        {linked && (
          <>
            <Button size="sm" variant="link" className="text-[12px]" disabled={link.isPending} onClick={() => go(null)}>
              Unlink
            </Button>
            <Link to="/wealth/investments/$holdingCode" params={{ holdingCode: linked }} className="text-[12px] text-accent hover:underline">
              Open
            </Link>
          </>
        )}
      </div>
      <p className="text-[11px] text-subtle">
        {!priced
          ? "It can be linked once it has an AED amount."
          : linked
            ? "Counts as saving into this investment, not spending."
            : holdings.isError
              ? "Couldn't load your investments."
              : active.length === 0
                ? "Add an investment under Wealth to link payments to it."
                : "A payment into a plan, account or deposit counts as saving, not spending."}
      </p>
    </div>
  );
}
