import { useState } from "react";
import { Monitor, Moon, Sun } from "lucide-react";
import { applyTheme, readTheme, type ThemePref } from "@/lib/theme";
import { BRAND_NAME } from "@/lib/brand";
import { Segmented } from "./ui/segmented";
import { BrandMark } from "./brand/brand";

// Pieces the public pages (sign-in, welcome, privacy) share with the app shell. Kept out of
// shell.tsx so those pages don't load the shell, its Radix menus and dialogs (WEB-11).

export function ThemeToggle({ className }: { className?: string }) {
  const [pref, setPref] = useState<ThemePref>(() => readTheme());
  return (
    <Segmented<ThemePref>
      ariaLabel="Theme"
      className={className}
      value={pref}
      onChange={(v) => {
        setPref(v);
        applyTheme(v);
      }}
      options={[
        { value: "light", label: <Sun className="size-3.5" aria-label="Light" /> },
        { value: "system", label: <Monitor className="size-3.5" aria-label="System" /> },
        { value: "dark", label: <Moon className="size-3.5" aria-label="Dark" /> },
      ]}
    />
  );
}

export function Splash() {
  return (
    <div className="flex min-h-dvh items-center justify-center" role="status" aria-label="Loading">
      <span className="flex items-center gap-3 animate-pulse">
        <BrandMark className="size-8" />
        <span className="font-display text-2xl text-subtle">{BRAND_NAME}</span>
      </span>
    </div>
  );
}
