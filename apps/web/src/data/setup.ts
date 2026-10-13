import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/lib/supabase";
import { setupChecklist, type SetupChecklist } from "@/lib/setup-checklist";
import { keys } from "./keys";
import { mustList, toApiError } from "./api";
import { useMembers, useProfileSecrets } from "./settings";

/**
 * The reads behind the empty-ledger checklist (WEB-27), made only when the
 * checklist is on screen (the ledger is empty). Each read stands alone: a failed one leaves
 * its step unknown instead of failing Overview. Keys sit under their domains,
 * so an upload, a new mailbox, a saved password or an invite refreshes them.
 */
export function useSetupChecklist(profileCode: string, lastSmsAt: string | null): { checklist: SetupChecklist; loading: boolean } {
  const uploads = useQuery({
    queryKey: [...keys.documents(profileCode), "count"],
    queryFn: async () => {
      const res = await supabase.from("documents").select("doc_code", { count: "exact", head: true }).eq("profile_code", profileCode);
      if (res.error) throw toApiError(res.error, res.status);
      return res.count ?? 0;
    },
  });
  const mailboxes = useQuery({
    queryKey: [...keys.mailboxes(profileCode), "setup"],
    queryFn: async () => mustList(await supabase.from("email_mailboxes").select("mailbox_code, enabled").eq("profile_code", profileCode)),
  });
  const secrets = useProfileSecrets(profileCode);
  const members = useMembers(profileCode);

  const value = <T>(q: { isError: boolean; data: T | undefined }): T | null => (q.isError || q.data === undefined ? null : q.data);
  return {
    checklist: setupChecklist({
      lastSmsAt,
      uploads: value(uploads),
      mailboxes: value(mailboxes),
      secrets: value(secrets),
      members: value(members),
    }),
    loading: [uploads, mailboxes, secrets, members].some((q) => q.isLoading),
  };
}
