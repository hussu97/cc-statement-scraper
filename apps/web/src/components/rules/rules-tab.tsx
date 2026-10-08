import { useMemo, useState } from "react";
import { ListFilter, MoreHorizontal, Pencil, Plus, Search, Trash2 } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import { useFilterMeta } from "@/data/overview";
import {
  RULE_SOURCES,
  describeMatch,
  emptyRuleDraft,
  filterRules,
  orderCategories,
  parseConditions,
  ruleToDraft,
  slicePage,
  summarizeConditions,
  useCategories,
  useDeleteRule,
  useRules,
  useToggleRule,
  type Rule,
  type RuleDraft,
} from "@/data/rules";
import { errorMessage } from "@/data/api";
import { formatCount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, Dot, type Tone } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ANY, Select } from "@/components/ui/select";
import { Menu, MenuContent, MenuItem, MenuTrigger, Switch } from "@/components/ui/primitives";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ConfirmDialog, Pager, ViewerNote, usePager } from "./shared";
import { RuleEditor } from "./rule-editor";

const SOURCE_TONE: Record<string, Tone> = { seed: "neutral", user: "accent", llm_promoted: "info", legacy: "neutral" };

export function RulesTab() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const rules = useRules(profileCode);
  const categories = useCategories(profileCode);
  const meta = useFilterMeta(profileCode);
  const toggle = useToggleRule(profileCode);
  const del = useDeleteRule(profileCode);
  const toast = useToast();
  const [q, setQ] = useState("");
  const [cat, setCat] = useState<string>(ANY);
  const [editing, setEditing] = useState<RuleDraft | null>(null);
  const [deleting, setDeleting] = useState<Rule | null>(null);
  const pager = usePager(`${q}|${cat}`);
  const onToggle = (r: Rule, active: boolean) =>
    toggle.mutate(
      { ruleCode: r.rule_code, active },
      {
        onSuccess: () => toast({ title: active ? "Rule turned on" : "Rule turned off" }),
        onError: (e) => toast({ title: "Couldn't change the rule", description: errorMessage(e), tone: "danger" }),
      },
    );

  const catByCode = useMemo(() => new Map((categories.data ?? []).map((c) => [c.category_code, c])), [categories.data]);
  const bankName = useMemo(() => {
    const m = new Map((meta.data?.banks ?? []).map((b) => [b.bank_code, b.name]));
    return (code: string) => m.get(code) ?? code;
  }, [meta.data]);
  const catOptions = useMemo(
    () => [
      { value: ANY, label: "All categories" },
      ...orderCategories((categories.data ?? []).filter((c) => !c.archived_at)).map((c) => ({
        value: c.category_code,
        label: c.depth ? `· ${c.name}` : c.name,
      })),
    ],
    [categories.data],
  );

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-xl text-sm text-muted">
          Rules decide a category from the description. Lower priority numbers are checked first. Your own choices always win.
        </p>
        {isOwner ? (
          <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setEditing(emptyRuleDraft())}>
            New rule
          </Button>
        ) : (
          <ViewerNote />
        )}
      </div>

      <div className="flex flex-wrap gap-2">
        <div className="relative min-w-0 flex-1 basis-56">
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-subtle" aria-hidden />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Find a rule" aria-label="Find a rule" className="pl-9" />
        </div>
        <Select ariaLabel="Filter by category" value={cat} onValueChange={setCat} options={catOptions} className="w-full sm:w-56" />
      </div>

      <Card>
        <QueryView
          query={rules}
          isEmpty={(d) => d.length === 0}
          empty={
            <EmptyState icon={<ListFilter />} title="No rules yet">
              {isOwner ? "Add a rule to categorise transactions by their description." : "An owner of this ledger can add rules."}
            </EmptyState>
          }
        >
          {(list) => {
            const filtered = filterRules(list, { q, categoryCode: cat === ANY ? null : cat });
            if (filtered.length === 0) {
              return (
                <EmptyState icon={<Search />} title="No rules match" action={<Button size="sm" onClick={() => { setQ(""); setCat(ANY); }}>Clear filters</Button>}>
                  Nothing matches “{q || catByCode.get(cat)?.name}”.
                </EmptyState>
              );
            }
            const page = slicePage(filtered, pager.page, pager.size);
            return (
              <>
                <div className="hidden grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)_4rem_6.5rem_2.5rem_2rem] items-center gap-3 border-b border-border px-5 py-2.5 text-[11px] font-medium tracking-[0.08em] text-subtle uppercase md:grid">
                  <span>Match</span>
                  <span>Category</span>
                  <span className="text-right">Priority</span>
                  <span>Source</span>
                  <span className="text-center">On</span>
                  <span />
                </div>
                <ul className="divide-y divide-border">
                  {page.map((r) => {
                    const c = catByCode.get(r.category_code);
                    const conds = summarizeConditions(parseConditions(r.conditions), bankName);
                    return (
                      <li
                        key={r.rule_code}
                        className={cn(
                          "grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-3 gap-y-1.5 px-5 py-3 md:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)_4rem_6.5rem_2.5rem_2rem]",
                          !r.active && "text-muted",
                        )}
                      >
                        <div className="min-w-0">
                          <p className={cn("truncate font-mono text-[13px]", r.active ? "text-ink" : "text-muted")}>{describeMatch(r.match_type, r.pattern)}</p>
                          {(conds.length > 0 || (r.name && !r.name.startsWith("seed:"))) && (
                            <p className="mt-0.5 truncate text-[12px] text-muted">
                              {[r.name && !r.name.startsWith("seed:") ? r.name : null, ...conds].filter(Boolean).join(" · ")}
                            </p>
                          )}
                        </div>
                        <div className="col-start-2 row-start-1 flex items-center gap-2 md:hidden">
                          <Switch checked={r.active} disabled={!isOwner} onCheckedChange={(v) => onToggle(r, v)} aria-label={r.active ? "Turn rule off" : "Turn rule on"} />
                          {isOwner && <RuleMenu onEdit={() => setEditing(ruleToDraft(r))} onDelete={() => setDeleting(r)} />}
                        </div>
                        <span className="flex min-w-0 items-center gap-2 text-[13px] text-ink-2">
                          <Dot token={c?.color_token} />
                          <span className="truncate">{c?.name ?? "Unknown category"}</span>
                          {c?.archived_at && <Badge>archived</Badge>}
                          <span className="ml-auto text-[12px] text-subtle tabular md:hidden">#{r.priority}</span>
                        </span>
                        <span className="hidden text-right text-[13px] text-ink-2 tabular md:block">{r.priority}</span>
                        <span className="hidden md:block">
                          <Badge tone={SOURCE_TONE[r.source] ?? "neutral"}>{RULE_SOURCES[r.source] ?? r.source}</Badge>
                        </span>
                        <span className="hidden justify-center md:flex">
                          <Switch
                            checked={r.active}
                            disabled={!isOwner}
                            onCheckedChange={(v) => onToggle(r, v)}
                            aria-label={r.active ? "Turn rule off" : "Turn rule on"}
                          />
                        </span>
                        <span className="hidden md:block">{isOwner && <RuleMenu onEdit={() => setEditing(ruleToDraft(r))} onDelete={() => setDeleting(r)} />}</span>
                      </li>
                    );
                  })}
                </ul>
                <Pager total={filtered.length} page={pager.page} size={pager.size} onPage={pager.setPage} onSize={pager.setSize} noun="rules" />
                {filtered.length <= 100 && (
                  <p className="border-t border-border px-5 py-2.5 text-[12px] text-subtle tabular">
                    {formatCount(filtered.length)} {filtered.length === 1 ? "rule" : "rules"}
                  </p>
                )}
              </>
            );
          }}
        </QueryView>
      </Card>

      {editing && <RuleEditor key={editing.rule_code ?? "new"} initial={editing} onClose={() => setEditing(null)} />}
      <ConfirmDialog
        open={!!deleting}
        onOpenChange={(o) => {
          if (!o) {
            setDeleting(null);
            del.reset();
          }
        }}
        title="Delete this rule?"
        confirmLabel="Delete rule"
        pending={del.isPending}
        error={del.error}
        onConfirm={() =>
          deleting &&
          del.mutate(deleting.rule_code, {
            onSuccess: () => {
              toast({ title: "Rule deleted", tone: "positive" });
              setDeleting(null);
            },
          })
        }
      >
        {deleting && (
          <>
            <span className="font-mono text-[13px]">{describeMatch(deleting.match_type, deleting.pattern)}</span> will stop categorising transactions. Transactions it
            set will fall back to other rules or stay uncategorised. To pause it instead, switch it off.
          </>
        )}
      </ConfirmDialog>
    </div>
  );
}

function RuleMenu({ onEdit, onDelete }: { onEdit: () => void; onDelete: () => void }) {
  return (
    <Menu>
      <MenuTrigger asChild>
        <Button size="icon-sm" variant="ghost" aria-label="Rule actions">
          <MoreHorizontal className="size-4" />
        </Button>
      </MenuTrigger>
      <MenuContent>
        <MenuItem onSelect={onEdit}>
          <Pencil className="size-3.5" /> Edit
        </MenuItem>
        <MenuItem tone="danger" onSelect={onDelete}>
          <Trash2 className="size-3.5" /> Delete
        </MenuItem>
      </MenuContent>
    </Menu>
  );
}
