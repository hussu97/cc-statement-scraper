// @vitest-environment jsdom
import { act, useEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { usePager } from "./shared";

// The Rules and Merchants lists page in memory; a new filter must start again at page 1,
// or a narrower result lands on an empty page past its end (WEB-55).
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

type Pager = ReturnType<typeof usePager>;
function Probe({ resetKey, onRender }: { resetKey: string; onRender: (p: Pager) => void }) {
  const p = usePager(resetKey);
  useEffect(() => onRender(p));
  return null;
}

let pager: Pager;
let root: Root;
const render = (resetKey: string) =>
  act(() =>
    root.render(
      <Probe
        resetKey={resetKey}
        onRender={(p) => {
          pager = p;
        }}
      />,
    ),
  );

beforeEach(() => {
  root = createRoot(document.createElement("div"));
});
afterEach(() => act(() => root.unmount()));

describe("usePager", () => {
  it("starts on page 1 at the default size", () => {
    render("q=|cat=");
    expect(pager.page).toBe(1);
    expect(pager.size).toBe(100);
  });

  it("goes back to page 1 when the filter key changes, and keeps the page size", () => {
    render("q=|cat=");
    act(() => pager.setSize(200));
    act(() => pager.setPage(3));
    expect([pager.page, pager.size]).toEqual([3, 200]);

    render("q=coffee|cat=");
    expect([pager.page, pager.size]).toEqual([1, 200]);

    // Paging under the new filter works, and the old filter's page doesn't come back.
    act(() => pager.setPage(2));
    expect(pager.page).toBe(2);
    render("q=|cat=");
    expect(pager.page).toBe(1);
  });

  it("keeps the page while the key is unchanged", () => {
    render("q=|cat=");
    act(() => pager.setPage(4));
    render("q=|cat=");
    expect(pager.page).toBe(4);
  });

  it("goes back to page 1 when the page size changes", () => {
    render("q=|cat=");
    act(() => pager.setPage(5));
    act(() => pager.setSize(500));
    expect([pager.page, pager.size]).toEqual([1, 500]);
  });
});
