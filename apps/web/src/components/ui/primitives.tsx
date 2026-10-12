import { Checkbox as C, DropdownMenu as DM, Popover as P, Switch as SW, Tabs as T, Tooltip as TT } from "radix-ui";
import { Check, Minus } from "lucide-react";
import type { ComponentProps, ReactNode } from "react";
import { cn } from "@/lib/cn";
import { useScrollEdges } from "@/lib/hooks";

const MENU =
  "z-50 min-w-44 overflow-hidden rounded-md border border-border bg-surface p-1 shadow-[0_8px_24px_-12px_var(--color-border-strong)] animate-fade-in";

// ── Popover ─────────────────────────────────────────────────────────────────
export const Popover = P.Root;
export const PopoverTrigger = P.Trigger;
export const PopoverClose = P.Close;
export function PopoverContent({ className, align = "start", ...rest }: ComponentProps<typeof P.Content>) {
  return (
    <P.Portal>
      <P.Content
        align={align}
        sideOffset={6}
        collisionPadding={12}
        className={cn(MENU, "max-w-[var(--radix-popover-content-available-width)] p-3", className)}
        {...rest}
      />
    </P.Portal>
  );
}

// ── Dropdown menu ───────────────────────────────────────────────────────────
export const Menu = DM.Root;
export const MenuTrigger = DM.Trigger;
export function MenuContent({ className, align = "end", ...rest }: ComponentProps<typeof DM.Content>) {
  return (
    <DM.Portal>
      <DM.Content
        align={align}
        sideOffset={6}
        collisionPadding={12}
        className={cn(MENU, "max-w-[var(--radix-dropdown-menu-content-available-width)]", className)}
        {...rest}
      />
    </DM.Portal>
  );
}
export function MenuItem({ className, tone, ...rest }: ComponentProps<typeof DM.Item> & { tone?: "danger" }) {
  return (
    <DM.Item
      className={cn(
        "flex h-10 cursor-pointer items-center gap-2 rounded-sm px-2 text-sm outline-none lg:h-8 lg:text-[13px] select-none data-[disabled]:opacity-50 data-[highlighted]:bg-surface-2",
        tone === "danger" ? "text-danger" : "text-ink",
        className,
      )}
      {...rest}
    />
  );
}
export function MenuLabel({ children }: { children: ReactNode }) {
  return <DM.Label className="px-2 pt-1.5 pb-1 text-[11px] font-medium tracking-wide text-subtle uppercase">{children}</DM.Label>;
}
export function MenuSeparator() {
  return <DM.Separator className="my-1 h-px bg-border" />;
}

// ── Tabs ────────────────────────────────────────────────────────────────────
export const Tabs = T.Root;
export const TabsContent = T.Content;
/** Tab strip: scrolls sideways on phones, with an edge fade where tabs are hidden (WEB-44). */
export function TabsList({ className, ...rest }: ComponentProps<typeof T.List>) {
  const ref = useScrollEdges<HTMLDivElement>();
  return (
    <T.List
      ref={ref}
      className={cn("scroll-fade relative -mx-1 flex gap-1 overflow-x-auto border-b border-border px-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden", className)}
      {...rest}
    />
  );
}
export function TabsTrigger({ className, ...rest }: ComponentProps<typeof T.Trigger>) {
  return (
    <T.Trigger
      className={cn(
        "relative -mb-px h-10 shrink-0 border-b-2 border-transparent px-3 text-sm whitespace-nowrap text-muted transition-colors hover:text-ink data-[state=active]:border-accent data-[state=active]:text-ink",
        className,
      )}
      {...rest}
    />
  );
}

export { Segmented } from "./segmented";

// ── Switch / Checkbox ───────────────────────────────────────────────────────
export function Switch({ className, ...rest }: ComponentProps<typeof SW.Root>) {
  return (
    <SW.Root
      className={cn(
        "tap inline-flex h-5 w-9 shrink-0 items-center rounded-pill border border-border-strong bg-surface-3 transition-colors data-[state=checked]:border-accent data-[state=checked]:bg-accent disabled:opacity-50",
        className,
      )}
      {...rest}
    >
      <SW.Thumb className="block size-3.5 translate-x-0.5 rounded-pill bg-surface transition-transform data-[state=checked]:translate-x-[18px]" />
    </SW.Root>
  );
}

export function Checkbox({ className, ...rest }: ComponentProps<typeof C.Root>) {
  return (
    <C.Root
      className={cn(
        "tap flex size-4 shrink-0 items-center justify-center rounded-[4px] border border-border-strong bg-surface transition-colors data-[state=checked]:border-accent data-[state=checked]:bg-accent data-[state=indeterminate]:border-accent data-[state=indeterminate]:bg-accent",
        className,
      )}
      {...rest}
    >
      <C.Indicator className="text-accent-ink">
        {rest.checked === "indeterminate" ? <Minus className="size-3" strokeWidth={3} /> : <Check className="size-3" strokeWidth={3} />}
      </C.Indicator>
    </C.Root>
  );
}

// ── Tooltip ─────────────────────────────────────────────────────────────────
export const TooltipProvider = TT.Provider;
export function Tooltip({ content, children }: { content: ReactNode; children: ReactNode }) {
  return (
    <TT.Root delayDuration={250}>
      <TT.Trigger asChild>{children}</TT.Trigger>
      <TT.Portal>
        <TT.Content sideOffset={6} className="z-50 max-w-64 rounded-sm bg-ink px-2 py-1 text-xs text-bg animate-fade-in">
          {content}
        </TT.Content>
      </TT.Portal>
    </TT.Root>
  );
}
