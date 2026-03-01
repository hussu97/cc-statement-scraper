export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}

/**
 * Extract a human-readable message from an unknown error.
 *
 * Handles:
 * - FastAPI error responses: `Error("HTTP 422 …: {"detail":"…"}")`
 * - Generic `Error` objects
 * - Plain strings
 * - Everything else falls back to "An unexpected error occurred"
 */
export function extractErrorMessage(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) {
    // Try to parse a FastAPI JSON body embedded in the message
    const colonIdx = error.message.indexOf(': {');
    if (colonIdx !== -1) {
      try {
        const json = JSON.parse(error.message.slice(colonIdx + 2)) as Record<string, unknown>;
        if (typeof json.detail === 'string') return json.detail;
      } catch {
        // not JSON — fall through
      }
    }
    return error.message;
  }
  return 'An unexpected error occurred';
}
