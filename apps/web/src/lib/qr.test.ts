import { describe, expect, it } from "vitest";
import { qrPath } from "./qr";

describe("qrPath", () => {
  it("encodes a URL as module squares with the three finder patterns", () => {
    const { size, path } = qrPath("https://example.com/settings?tab=sms");
    expect(size).toBeGreaterThanOrEqual(21);
    expect((size - 17) % 4).toBe(0); // a valid QR version: 17 + 4v modules
    // Finder pattern corners are dark: top-left, top-right, bottom-left.
    expect(path).toContain("M0 0h1v1h-1z");
    expect(path).toContain(`M${size - 1} 0h1v1h-1z`);
    expect(path).toContain(`M0 ${size - 1}h1v1h-1z`);
    // …and the bottom-right corner never is.
    expect(path).not.toContain(`M${size - 1} ${size - 1}h1v1h-1z`);
  });

  it("is deterministic and grows with the payload", () => {
    expect(qrPath("abc")).toEqual(qrPath("abc"));
    expect(qrPath("x".repeat(200)).size).toBeGreaterThan(qrPath("x").size);
  });
});
