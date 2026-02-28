import { useEffect, useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import type { Category, CategoryRule, PagedResponse, RuleTestResult } from '../types/statements';

export function RulesPage() {
  const [categories, setCategories] = useState<Category[]>([]);
  const [rules, setRules] = useState<CategoryRule[]>([]);
  const [rulesPage, setRulesPage] = useState(1);
  const [rulesPageSize, setRulesPageSize] = useState(100);
  const [rulesTotal, setRulesTotal] = useState(0);
  const [rulesSearch, setRulesSearch] = useState('');
  const [categoryName, setCategoryName] = useState('');
  const [newRule, setNewRule] = useState({
    name: '',
    category_name: '',
    match_type: 'contains',
    pattern: '',
    active: true,
  });
  const [ruleTest, setRuleTest] = useState({ merchant_normalized: '' });
  const [ruleTestResult, setRuleTestResult] = useState<RuleTestResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function load(nextPage = rulesPage, nextPageSize = rulesPageSize, nextSearch = rulesSearch) {
    try {
      setError(null);
      const ruleParams = new URLSearchParams();
      ruleParams.set('page', String(nextPage));
      ruleParams.set('page_size', String(nextPageSize));
      if (nextSearch.trim()) {
        ruleParams.set('search', nextSearch.trim());
      }
      const [catRows, ruleRows] = await Promise.all([
        api.get<Category[]>('/categories'),
        api.get<PagedResponse<CategoryRule>>(`/category-rules?${ruleParams.toString()}`),
      ]);
      setCategories(catRows);
      const nextTotal = Number(ruleRows.total || 0);
      setRulesTotal(nextTotal);
      setRules(ruleRows.items || []);
      const totalPages = Math.max(1, Math.ceil(nextTotal / Math.max(nextPageSize, 1)));
      if (nextPage > totalPages) {
        setRulesPage(totalPages);
      }
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function createCategory() {
    if (!categoryName.trim()) return;
    try {
      await api.post('/categories', { name: categoryName.trim() });
      setCategoryName('');
      load();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function createRule() {
    try {
      await api.post('/category-rules', newRule);
      setNewRule({
        name: '',
        category_name: '',
        match_type: 'contains',
        pattern: '',
        active: true,
      });
      setRulesPage(1);
      load(1, rulesPageSize, rulesSearch);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function testRule() {
    try {
      const result = await api.post<RuleTestResult>('/category-rules/test', ruleTest);
      setRuleTestResult(result);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, [rulesPage, rulesPageSize, rulesSearch]);

  return (
    <div className="grid">
      <Panel title="Categories">
        {error && <p className="error">{error}</p>}
        <div className="row">
          <input value={categoryName} onChange={(e) => setCategoryName(e.target.value)} placeholder="New category" />
          <button className="primary" onClick={createCategory}>Add Category</button>
          <button className="ghost" onClick={() => load()}>Refresh</button>
        </div>
        <div className="row" style={{ marginTop: '0.6rem' }}>
          {categories.map((cat) => <span key={cat.id} className="badge">{cat.name}</span>)}
        </div>
      </Panel>

      <Panel title="Create Rule">
        <div className="row">
          <input value={newRule.name} onChange={(e) => setNewRule((p) => ({ ...p, name: e.target.value }))} placeholder="Rule name" />
          <input value={newRule.category_name} onChange={(e) => setNewRule((p) => ({ ...p, category_name: e.target.value }))} placeholder="Category" />
          <select value={newRule.match_type} onChange={(e) => setNewRule((p) => ({ ...p, match_type: e.target.value }))}>
            <option value="contains">contains</option>
            <option value="exact">exact</option>
            <option value="regex">regex</option>
          </select>
          <input value={newRule.pattern} onChange={(e) => setNewRule((p) => ({ ...p, pattern: e.target.value }))} placeholder="Pattern" />
          <button className="primary" onClick={createRule}>Add Rule</button>
        </div>
        <p className="muted" style={{ marginTop: '0.55rem' }}>
          Matching is automatic: the most specific matching pattern (longest keyword) wins.
        </p>
      </Panel>

      <Panel title="Rules">
        <div className="row" style={{ justifyContent: 'space-between', marginBottom: '0.6rem' }}>
          <input
            value={rulesSearch}
            onChange={(event) => {
              setRulesPage(1);
              setRulesSearch(event.target.value);
            }}
            placeholder="Search rules"
          />
          <button className="ghost" onClick={() => load()}>Refresh</button>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Category</th>
                <th>Match</th>
                <th>Pattern</th>
              </tr>
            </thead>
            <tbody>
              {rules.map((rule) => (
                <tr key={rule.id}>
                  <td>{rule.id}</td>
                  <td>{rule.name}</td>
                  <td>{rule.category_name}</td>
                  <td>{rule.match_type}</td>
                  <td>{rule.pattern}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <TablePagination
          page={rulesPage}
          pageSize={rulesPageSize}
          total={rulesTotal}
          itemLabel="rules"
          onPageChange={setRulesPage}
          onPageSizeChange={(next) => {
            setRulesPageSize(next);
            setRulesPage(1);
          }}
        />
      </Panel>

      <Panel title="Rule Test">
        <div className="row">
          <input value={ruleTest.merchant_normalized} onChange={(e) => setRuleTest((p) => ({ ...p, merchant_normalized: e.target.value }))} placeholder="Merchant normalized" />
          <button className="primary" onClick={testRule}>Test</button>
        </div>
        {ruleTestResult ? <JsonView value={ruleTestResult} /> : null}
      </Panel>
    </div>
  );
}
