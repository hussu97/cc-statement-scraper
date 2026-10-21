import { describe, expect, it } from "vitest";
import { publicObjectUrl } from "./public-object";

const NAME = /^[a-z]+\.png$/;

describe("publicObjectUrl", () => {
  it("builds the public object URL, trimming the base's trailing slashes", () => {
    expect(publicObjectUrl("b", "x.png", "http://127.0.0.1:54321", NAME)).toBe("http://127.0.0.1:54321/storage/v1/object/public/b/x.png");
    expect(publicObjectUrl("b", "x.png", "https://p.supabase.co//", NAME)).toBe("https://p.supabase.co/storage/v1/object/public/b/x.png");
  });

  it("is null without a name or base, or for a name the pattern refuses", () => {
    expect(publicObjectUrl("b", null, "http://h", NAME)).toBeNull();
    expect(publicObjectUrl("b", "x.png", undefined, NAME)).toBeNull();
    expect(publicObjectUrl("b", "../x.png", "http://h", NAME)).toBeNull();
  });
});
