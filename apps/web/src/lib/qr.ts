import { encode } from "uqr";

/**
 * A QR code as one SVG path of 1×1 module squares (no quiet zone; the caller
 * pads it). Rendered with token colours by the page, so no image or canvas.
 */
export function qrPath(text: string): { size: number; path: string } {
  const { size, data } = encode(text, { ecc: "M", border: 0 });
  let path = "";
  data.forEach((row, y) =>
    row.forEach((dark, x) => {
      if (dark) path += `M${x} ${y}h1v1h-1z`;
    }),
  );
  return { size, path };
}
