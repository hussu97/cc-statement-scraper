import { useEffect, useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';

export function StatementsPage() {
  const [statements, setStatements] = useState<any[]>([]);
  const [selected, setSelected] = useState<any | null>(null);
  const [lines, setLines] = useState<any[]>([]);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    try {
      setError(null);
      const data = await api.get<any>('/statements?page_size=100');
      setStatements(data.items || []);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function openStatement(statement: any) {
    try {
      setSelected(statement);
      const lineResp = await api.get<any>(`/statements/${statement.id}/lines?page_size=400`);
      setLines(lineResp.items || []);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function reparse(statementId: number) {
    try {
      const job = await api.post<any>(`/statements/${statementId}/reparse`);
      setSelected((prev: any) => (prev ? { ...prev, reparseJob: job } : prev));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function deleteStatement(statementId: number) {
    try {
      await api.delete(`/statements/${statementId}`);
      setStatements((prev) => prev.filter((s) => s.id !== statementId));
      if (selected?.id === statementId) {
        setSelected(null);
        setLines([]);
      }
    } catch (err) {
      setError((err as Error).message);
    }
  }

  function downloadPdf(statementId: number) {
    const anchor = document.createElement('a');
    anchor.href = `/api/v1/statements/${statementId}/pdf`;
    anchor.setAttribute('download', '');
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <div className="grid">
      <Panel title="Statements">
        {error && <p className="error">{error}</p>}
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <span className="muted">Canonical statement headers with replace-on-identity semantics.</span>
          <button className="ghost" onClick={load}>Refresh</button>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Bank</th>
                <th>Reference</th>
                <th>Date</th>
                <th>Lines</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {statements.map((statement) => (
                <tr key={statement.id}>
                  <td>{statement.id}</td>
                  <td>{statement.bank_code}</td>
                  <td>{statement.statement_reference}</td>
                  <td>{statement.statement_date}</td>
                  <td>{statement.line_count}</td>
                  <td>
                    <button className="ghost" onClick={() => openStatement(statement)}>View</button>{' '}
                    {statement.pdf_file_id ? (
                      <button className="ghost" onClick={() => downloadPdf(statement.id)}>PDF</button>
                    ) : null}{' '}
                    <button className="ghost" onClick={() => reparse(statement.id)}>Reparse</button>{' '}
                    <button className="ghost" onClick={() => deleteStatement(statement.id)}>Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>

      <Panel title="Statement Detail">
        {selected ? (
          <>
            <div className="row" style={{ justifyContent: 'space-between', marginBottom: '0.65rem' }}>
              <span className="muted">Statement metadata and parsed line items</span>
            </div>
            <JsonView value={selected} />
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Date</th>
                    <th>Merchant</th>
                    <th>Amount AED</th>
                    <th>Direction</th>
                    <th>Category</th>
                  </tr>
                </thead>
                <tbody>
                  {lines.map((line) => (
                    <tr key={line.id}>
                      <td>{line.line_no}</td>
                      <td>{line.transaction_date} {line.transaction_time}</td>
                      <td>{line.merchant_normalized}</td>
                      <td>{line.amount_aed}</td>
                      <td>{line.direction}</td>
                      <td>{line.category}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        ) : (
          <p className="muted">Select a statement to inspect lines.</p>
        )}
      </Panel>
    </div>
  );
}
