declare module "@ledger/tokens/chart" {
  export const chart: { light: Record<string, string>; dark: Record<string, string> };
  export const categoryTokens: string[];
  /** CSS variable for a category colour token, falling back to "uncategorized". */
  export function categoryVar(token: string | null | undefined): string;
}
