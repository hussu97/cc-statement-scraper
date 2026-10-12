// Session Replay (rrweb), its own chunk: fetched only after the SDK has started (WEB-11).
// Error-only and fully masked; the sample rates are in sentry-client.ts's init options.
import { addIntegration, replayIntegration } from "@sentry/react";

export function startReplay(): void {
  addIntegration(replayIntegration({ maskAllText: true, blockAllMedia: true }));
}
