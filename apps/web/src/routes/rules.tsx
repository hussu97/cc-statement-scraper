import { PageHeader } from "@/components/ui/display";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/primitives";
import { ruleTab } from "@/data/rules";
import { useTabParam } from "@/components/rules/shared";
import { CategoriesTab } from "@/components/rules/categories-tab";
import { RulesTab } from "@/components/rules/rules-tab";
import { MerchantsTab } from "@/components/rules/merchants-tab";

export function RulesPage() {
  const [raw, setTab] = useTabParam("/rules");
  const tab = ruleTab(raw);
  return (
    <div className="mx-auto w-full max-w-5xl">
      <PageHeader title="Rules" description="How Bank Ledger decides a category. Your own choices always win over rules and suggestions." />
      <Tabs value={tab} onValueChange={setTab}>
        <TabsList className="mb-6">
          <TabsTrigger value="categories">Categories</TabsTrigger>
          <TabsTrigger value="rules">Rules</TabsTrigger>
          <TabsTrigger value="merchants">Merchants</TabsTrigger>
        </TabsList>
        <TabsContent value="categories">
          <CategoriesTab />
        </TabsContent>
        <TabsContent value="rules">
          <RulesTab />
        </TabsContent>
        <TabsContent value="merchants">
          <MerchantsTab />
        </TabsContent>
      </Tabs>
    </div>
  );
}
