import { PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { settingsTab } from "@/data/settings";
import { useTabParam } from "@/components/rules/shared";
import { HealthSection } from "@/components/settings/health-section";
import { EmailSection } from "@/components/settings/email-section";
import { TokensSection } from "@/components/settings/tokens-section";
import { SecretsSection } from "@/components/settings/secrets-section";
import { MembersTab } from "@/components/settings/members-tab";
import { SmsGuideTab } from "@/components/settings/sms-guide-tab";
import { AppearanceTab, LedgerTab } from "@/components/settings/ledger-tab";

export function SettingsPage() {
  const [raw, setTab] = useTabParam("/settings");
  const tab = settingsTab(raw);
  return (
    <div className="mx-auto w-full max-w-5xl">
      <PageHeader title="Settings" description="Where your data comes from, who can see it, and how Ledger looks." />
      <Tabs value={tab} onValueChange={setTab}>
        <TabsList className="mb-6">
          <TabsTrigger value="sources">Sources & health</TabsTrigger>
          <TabsTrigger value="members">Members</TabsTrigger>
          <TabsTrigger value="sms">iPhone SMS</TabsTrigger>
          <TabsTrigger value="appearance">Appearance</TabsTrigger>
          <TabsTrigger value="ledger">Ledger</TabsTrigger>
        </TabsList>
        <TabsContent value="sources" className="flex flex-col gap-4">
          <HealthSection />
          <EmailSection />
          <TokensSection />
          <SecretsSection />
        </TabsContent>
        <TabsContent value="members">
          <MembersTab />
        </TabsContent>
        <TabsContent value="sms">
          <SmsGuideTab />
        </TabsContent>
        <TabsContent value="appearance">
          <AppearanceTab />
        </TabsContent>
        <TabsContent value="ledger">
          <LedgerTab />
        </TabsContent>
      </Tabs>
    </div>
  );
}
