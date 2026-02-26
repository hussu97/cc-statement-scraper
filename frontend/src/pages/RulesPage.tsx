import { useEffect, useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';

export function RulesPage() {
  const [categories, setCategories] = useState<any[]>([]);
  const [rules, setRules] = useState<any[]>([]);
  const [categoryName, setCategoryName] = useState('');
  const [newRule, setNewRule] = useState({
    name: '',
    category_name: '',
    match_type: 'contains',
    pattern: '',
    bank_code: '',
    card_last4: '',
    priority: 100,
    active: true,
  });
  const [ruleTest, setRuleTest] = useState({ bank_code: 'FAB', card_last4: '', merchant_normalized: '' });
  const [ruleTestResult, setRuleTestResult] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    try {
      setError(null);
      const [catRows, ruleRows] = await Promise.all([
        api.get<any[]>('/categories'),
        api.get<any[]>('/category-rules'),
      ]);
      setCategories(catRows);
      setRules(ruleRows);
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
      await api.post('/category-rules', {
        ...newRule,
        bank_code: newRule.bank_code.trim() || null,
        card_last4: newRule.card_last4.trim() || null,
      });
      setNewRule({
        name: '',
        category_name: '',
        match_type: 'contains',
        pattern: '',
        bank_code: '',
        card_last4: '',
        priority: 100,
        active: true,
      });
      load();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function testRule() {
    try {
      const result = await api.post('/category-rules/test', {
        ...ruleTest,
        bank_code: ruleTest.bank_code.toUpperCase(),
        card_last4: ruleTest.card_last4.trim() || null,
      });
      setRuleTestResult(result);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <div className="grid">
      <Panel title="Categories">
        {error && <p className="error">{error}</p>}
        <div className="row">
          <input value={categoryName} onChange={(e) => setCategoryName(e.target.value)} placeholder="New category" />
          <button className="primary" onClick={createCategory}>Add Category</button>
          <button className="ghost" onClick={load}>Refresh</button>
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
          <input value={newRule.bank_code} onChange={(e) => setNewRule((p) => ({ ...p, bank_code: e.target.value.toUpperCase() }))} placeholder="Bank (optional)" />
          <input value={newRule.card_last4} onChange={(e) => setNewRule((p) => ({ ...p, card_last4: e.target.value }))} placeholder="Card last4 (optional)" />
          <input
            type="number"
            value={newRule.priority}
            onChange={(e) => setNewRule((p) => ({ ...p, priority: Number(e.target.value) }))}
            style={{ width: '90px' }}
          />
          <button className="primary" onClick={createRule}>Add Rule</button>
        </div>
      </Panel>

      <Panel title="Rules">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Category</th>
                <th>Match</th>
                <th>Pattern</th>
                <th>Scope</th>
                <th>Priority</th>
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
                  <td>{rule.bank_code || '*'} / {rule.card_last4 || '*'}</td>
                  <td>{rule.priority}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>

      <Panel title="Rule Test">
        <div className="row">
          <input value={ruleTest.bank_code} onChange={(e) => setRuleTest((p) => ({ ...p, bank_code: e.target.value }))} placeholder="Bank" />
          <input value={ruleTest.card_last4} onChange={(e) => setRuleTest((p) => ({ ...p, card_last4: e.target.value }))} placeholder="Card last4 (optional)" />
          <input value={ruleTest.merchant_normalized} onChange={(e) => setRuleTest((p) => ({ ...p, merchant_normalized: e.target.value }))} placeholder="Merchant normalized" />
          <button className="primary" onClick={testRule}>Test</button>
        </div>
        {ruleTestResult ? <JsonView value={ruleTestResult} /> : null}
      </Panel>
    </div>
  );
}
