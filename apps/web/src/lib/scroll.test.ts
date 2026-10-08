import { describe, expect, it } from "vitest";
import { revealScrollLeft, scrollEdges } from "./scroll";

describe("scrollEdges", () => {
  it("shows no fade when everything fits", () => {
    expect(scrollEdges(0, 300, 300)).toEqual({ start: false, end: false });
    expect(scrollEdges(0, 301, 300)).toEqual({ start: false, end: false });
  });
  it("fades the end at the start of a wide strip", () => {
    expect(scrollEdges(0, 900, 300)).toEqual({ start: false, end: true });
  });
  it("fades both edges in the middle", () => {
    expect(scrollEdges(200, 900, 300)).toEqual({ start: true, end: true });
  });
  it("fades only the start at the end (with sub-pixel slack)", () => {
    expect(scrollEdges(599.5, 900, 300)).toEqual({ start: true, end: false });
  });
  it("handles RTL negative scrollLeft", () => {
    expect(scrollEdges(-200, 900, 300)).toEqual({ start: true, end: true });
  });
});

describe("revealScrollLeft", () => {
  it("leaves a visible item alone", () => {
    expect(revealScrollLeft(10, 90, 0, 300)).toBeNull();
  });
  it("scrolls right to reveal an item past the end, with padding", () => {
    expect(revealScrollLeft(500, 600, 0, 300)).toBe(324);
  });
  it("scrolls left to reveal an item before the view", () => {
    expect(revealScrollLeft(100, 180, 400, 300)).toBe(76);
  });
  it("never returns a negative offset", () => {
    expect(revealScrollLeft(10, 60, 50, 300)).toBe(0);
  });
});
