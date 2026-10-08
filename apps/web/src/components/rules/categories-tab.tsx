import { useMemo, useState } from "react";
import { Archive, ArchiveRestore, ChevronRight, MoreHorizontal, Pencil, Plus, Shapes } from "lucide-react";
import { useActiveProfile } from "@/data/profile";
import {
  CATEGORY_KINDS,
  COLOR_TOKENS,
  countRulesByCategory,
  groupCategories,
  useArchiveCategory,
  useCategories,
  useRules,
  useSaveCategory,
  type Category,
} from "@/data/rules";
import { errorMessage } from "@/data/api";
import { formatCount } from "@/lib/money";
import { cn } from "@/lib/cn";
import { Badge, Card, Dot } from "@/components/ui/display";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field, Input } from "@/components/ui/input";
import { Select } from "@/components/ui/select";
import { Menu, MenuContent, MenuItem, MenuTrigger } from "@/components/ui/primitives";
import { EmptyState, QueryView } from "@/components/ui/states";
import { useToast } from "@/components/ui/toast";
import { ViewerNote } from "./shared";

const NO_PARENT = "__none";
const kindLabel = (k: string) => CATEGORY_KINDS.find((x) => x.value === k)?.label ?? k;

export function CategoriesTab() {
  const { profile_code: profileCode, isOwner } = useActiveProfile();
  const categories = useCategories(profileCode);
  const rules = useRules(profileCode);
  const archive = useArchiveCategory(profileCode);
  const toast = useToast();
  const [editing, setEditing] = useState<Category | "new" | null>(null);
  const [showArchived, setShowArchived] = useState(false);
  const ruleCounts = useMemo(() => countRulesByCategory(rules.data ?? []), [rules.data]);

  const setArchived = (c: Category, archived: boolean) =>
    archive.mutate(
      { categoryCode: c.category_code, archived },
      {
        onSuccess: () => toast({ title: archived ? `“${c.name}” archived` : `“${c.name}” restored`, tone: "positive" }),
        onError: (e) => toast({ title: archived ? "Couldn't archive" : "Couldn't restore", description: errorMessage(e), tone: "danger" }),
      },
    );

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="max-w-xl text-sm text-muted">
          Categories group your spending. Archived ones stay on past transactions but can't be picked for new ones.
        </p>
        {isOwner ? (
          <Button variant="primary" icon={<Plus className="size-4" />} onClick={() => setEditing("new")}>
            New category
          </Button>
        ) : (
          <ViewerNote />
        )}
      </div>

      <Card>
        <QueryView
          query={categories}
          isEmpty={(d) => d.length === 0}
          empty={
            <EmptyState icon={<Shapes />} title="No categories yet">
              {isOwner ? "Create one to start sorting your spending." : "An owner of this ledger can add them."}
            </EmptyState>
          }
        >
          {(list) => {
            const { active, archived } = groupCategories(list);
            return (
              <>
                <ul className="divide-y divide-border">
                  {active.map((c) => (
                    <CategoryRow
                      key={c.category_code}
                      category={c}
                      depth={c.depth}
                      rules={ruleCounts.get(c.category_code) ?? 0}
                      isOwner={isOwner}
                      onEdit={() => setEditing(c)}
                      onArchive={() => setArchived(c, true)}
                    />
                  ))}
                  {active.length === 0 && <li className="px-5 py-6 text-center text-[13px] text-muted">Every category is archived.</li>}
                </ul>
                {archived.length > 0 && (
                  <div className="border-t border-border">
                    <button
                      type="button"
                      onClick={() => setShowArchived((v) => !v)}
                      aria-expanded={showArchived}
                      className="flex w-full items-center gap-2 px-5 py-3 text-left text-[13px] text-muted hover:text-ink"
                    >
                      <ChevronRight className={cn("size-3.5 transition-transform", showArchived && "rotate-90")} aria-hidden />
                      Archived <span className="tabular text-subtle">{formatCount(archived.length)}</span>
                    </button>
                    {showArchived && (
                      <ul className="divide-y divide-border border-t border-border">
                        {archived.map((c) => (
                          <CategoryRow
                            key={c.category_code}
                            category={c}
                            depth={0}
                            muted
                            rules={ruleCounts.get(c.category_code) ?? 0}
                            isOwner={isOwner}
                            onEdit={() => setEditing(c)}
                            onRestore={() => setArchived(c, false)}
                          />
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </>
            );
          }}
        </QueryView>
      </Card>

      {editing && (
        <CategoryDialog
          key={editing === "new" ? "new" : editing.category_code}
          category={editing === "new" ? null : editing}
          all={categories.data ?? []}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function CategoryRow({
  category: c,
  depth,
  rules,
  muted,
  isOwner,
  onEdit,
  onArchive,
  onRestore,
}: {
  category: Category;
  depth: number;
  rules: number;
  muted?: boolean;
  isOwner: boolean;
  onEdit: () => void;
  onArchive?: () => void;
  onRestore?: () => void;
}) {
  return (
    <li className={cn("flex min-h-12 items-center gap-3 px-5 py-2.5", depth > 0 && "pl-11", muted && "opacity-60")}>
      <Dot token={c.color_token} className="size-2.5" />
      <span className="min-w-0 flex-1 truncate text-sm text-ink">{c.name}</span>
      {c.kind !== "spend" && <Badge>{kindLabel(c.kind)}</Badge>}
      <span className="hidden w-20 text-right text-[12px] text-muted tabular sm:inline">
        {rules === 0 ? "No rules" : `${formatCount(rules)} ${rules === 1 ? "rule" : "rules"}`}
      </span>
      {isOwner && (
        <Menu>
          <MenuTrigger asChild>
            <Button size="icon-sm" variant="ghost" aria-label={`Actions for ${c.name}`}>
              <MoreHorizontal className="size-4" />
            </Button>
          </MenuTrigger>
          <MenuContent>
            <MenuItem onSelect={onEdit}>
              <Pencil className="size-3.5" /> Edit
            </MenuItem>
            {onArchive && (
              <MenuItem onSelect={onArchive}>
                <Archive className="size-3.5" /> Archive
              </MenuItem>
            )}
            {onRestore && (
              <MenuItem onSelect={onRestore}>
                <ArchiveRestore className="size-3.5" /> Restore
              </MenuItem>
            )}
          </MenuContent>
        </Menu>
      )}
    </li>
  );
}

function CategoryDialog({ category, all, onClose }: { category: Category | null; all: Category[]; onClose: () => void }) {
  const { profile_code: profileCode } = useActiveProfile();
  const save = useSaveCategory(profileCode);
  const toast = useToast();
  const [name, setName] = useState(category?.name ?? "");
  const [kind, setKind] = useState(category?.kind ?? "spend");
  const [color, setColor] = useState<string | null>(category?.color_token ?? COLOR_TOKENS[0] ?? null);
  const [parent, setParent] = useState(category?.parent_code ?? NO_PARENT);
  const [touched, setTouched] = useState(false);

  const hasChildren = !!category && all.some((c) => c.parent_code === category.category_code);
  const parents = all.filter((c) => !c.parent_code && !c.archived_at && c.category_code !== category?.category_code);
  const nameError = !name.trim()
    ? "Give it a name."
    : name.trim().length > 60
      ? "Keep it under 60 characters."
      : all.some((c) => c.category_code !== category?.category_code && c.name.toLowerCase() === name.trim().toLowerCase())
        ? "A category with that name already exists."
        : null;

  const submit = () => {
    setTouched(true);
    if (nameError) return;
    save.mutate(
      { category_code: category?.category_code, name, kind, color_token: color, parent_code: parent === NO_PARENT ? null : parent },
      {
        onSuccess: () => {
          toast({ title: category ? "Category saved" : "Category created", tone: "positive" });
          onClose();
        },
      },
    );
  };

  return (
    <Dialog
      open
      onOpenChange={(o) => !o && onClose()}
      title={category ? "Edit category" : "New category"}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={save.isPending} onClick={submit}>
            {category ? "Save" : "Create"}
          </Button>
        </>
      }
    >
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <Field label="Name" error={touched ? nameError : null}>
          {(id, d) => (
            <Input id={id} aria-describedby={d} aria-invalid={touched && !!nameError} value={name} onChange={(e) => setName(e.target.value)} autoFocus maxLength={60} />
          )}
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Counts as" hint={kind === "spend" ? "Included in spending totals." : "Left out of spending totals."}>
            {() => <Select ariaLabel="Counts as" value={kind} onValueChange={setKind} options={CATEGORY_KINDS.map((k) => ({ value: k.value, label: k.label }))} className="w-full" />}
          </Field>
          <Field label="Inside" hint={hasChildren ? "It has its own subcategories, so it stays top-level." : undefined}>
            {() => (
              <Select
                ariaLabel="Parent category"
                value={parent}
                onValueChange={setParent}
                disabled={hasChildren}
                options={[{ value: NO_PARENT, label: "Top level" }, ...parents.map((p) => ({ value: p.category_code, label: p.name }))]}
                className="w-full"
              />
            )}
          </Field>
        </div>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1.5 text-[13px] font-medium text-ink-2">Colour</legend>
          <div role="radiogroup" aria-label="Colour" className="flex flex-wrap gap-2">
            {COLOR_TOKENS.map((t) => (
              <button
                key={t}
                type="button"
                role="radio"
                aria-checked={color === t}
                aria-label={`Colour ${t.replace("cat-", "")}`}
                onClick={() => setColor(t)}
                className={cn(
                  "flex size-8 items-center justify-center rounded-pill border transition-colors",
                  color === t ? "border-ink" : "border-transparent hover:border-border-strong",
                )}
              >
                <span className="size-5 rounded-pill" style={{ background: `var(--chart-${t})` }} />
              </button>
            ))}
          </div>
        </fieldset>
        {save.error ? <p className="text-[13px] text-danger">{errorMessage(save.error)}</p> : null}
        <button type="submit" hidden />
      </form>
    </Dialog>
  );
}
