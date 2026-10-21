// Public Supabase Storage objects (bank logos, investment images): the object endpoint URL.
// Pure, unit-tested. The object name must match the caller's pattern (a bare file name), so a row
// can never point an <img> somewhere unexpected; CSP img-src already allows the Supabase host.

/** `<supabaseUrl>/storage/v1/object/public/<bucket>/<name>`, or null when either is missing or the name fails `pattern`. */
export function publicObjectUrl(bucket: string, name: string | null | undefined, supabaseUrl: string | null | undefined, pattern: RegExp): string | null {
  if (!name || !supabaseUrl || !pattern.test(name)) return null;
  return `${supabaseUrl.replace(/\/+$/, "")}/storage/v1/object/public/${bucket}/${name}`;
}
