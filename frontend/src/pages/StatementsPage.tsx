import { useEffect, useRef, useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { MultiSelectDropdown } from '../components/MultiSelectDropdown';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';

export function StatementsPage() {
  const activeProfileKey = useActiveProfileKey();
  const detailPanelRef = useRef<HTMLDivElement | null>(null);
  const [statements, setStatements] = useState<any[]>([]);
  const [statementsPage, setStatementsPage] = useState(1);
  const [statementsPageSize, setStatementsPageSize] = useState(100);
  const [statementsTotal, setStatementsTotal] = useState(0);
  const [bankOptions, setBankOptions] = useState<string[]>([]);
  const [bankCodes, setBankCodes] = useState<string[]>([]);
  const [selected, setSelected] = useState<any | null>(null);
  const [lines, setLines] = useState<any[]>([]);
  const [linesPage, setLinesPage] = useState(1);
  const [linesPageSize, setLinesPageSize] = useState(100);
  const [linesTotal, setLinesTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [reparseAllRunning, setReparseAllRunning] = useState(false);
  const [editingStatementDate, setEditingStatementDate] = useState('');
  const [savingStatementDate, setSavingStatementDate] = useState(false);

  async function loadBanks() {
    try {
      const rows = await api.get<any[]>('/banks');
      const options = rows
        .map((row) => String(row.code || '').toUpperCase().trim())
        .filter((value, index, array) => value && array.indexOf(value) === index)
        .sort();
      setBankOptions(options);
      setBankCodes((prev) => prev.filter((code) => options.includes(code)));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function load() {
    try {
      setError(null);
      const params = new URLSearchParams();
      params.set('page', String(statementsPage));
      params.set('page_size', String(statementsPageSize));
      bankCodes.forEach((code) => params.append('bank_codes', code.toUpperCase()));
      const data = await api.get<any>(`/statements?${params.toString()}`);
      const total = Number(data.total || 0);
      setStatementsTotal(total);
      setStatements(data.items || []);
      const totalPages = Math.max(1, Math.ceil(total / Math.max(statementsPageSize, 1)));
      if (statementsPage > totalPages) {
        setStatementsPage(totalPages);
      }
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function loadStatementLines(statementId: number) {
    try {
      const lineResp = await api.get<any>(
        `/statements/${statementId}/lines?page=${linesPage}&page_size=${linesPageSize}`,
      );
      const total = Number(lineResp.total || 0);
      setLinesTotal(total);
      setLines(lineResp.items || []);
      const totalPages = Math.max(1, Math.ceil(total / Math.max(linesPageSize, 1)));
      if (linesPage > totalPages) {
        setLinesPage(totalPages);
      }
    } catch (err) {
      setError((err as Error).message);
    }
  }

  function openStatement(statement: any) {
    setSelected(statement);
    setEditingStatementDate(String(statement.statement_date || ''));
    setLinesPage(1);
    setLinesTotal(0);
    window.requestAnimationFrame(() => {
      detailPanelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  async function reparse(statementId: number) {
    try {
      const job = await api.post<any>(`/statements/${statementId}/reparse`);
      setSelected((prev: any) => (prev ? { ...prev, reparseJob: job } : prev));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function reparseAll() {
    try {
      setError(null);
      setReparseAllRunning(true);
      const job = await api.post<any>('/statements/reparse-all');
      setSelected((prev: any) => (prev ? { ...prev, reparseAllJob: job } : prev));
      await load();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setReparseAllRunning(false);
    }
  }

  async function deleteStatement(statementId: number) {
    try {
      await api.delete(`/statements/${statementId}`);
      await load();
      if (selected?.id === statementId) {
        setSelected(null);
        setEditingStatementDate('');
        setLines([]);
        setLinesTotal(0);
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

  async function saveStatementDate() {
    if (!selected?.id || !editingStatementDate) {
      return;
    }
    try {
      setError(null);
      setSavingStatementDate(true);
      const updated = await api.patch<any>(`/statements/${selected.id}`, {
        statement_date: editingStatementDate,
      });
      setSelected(updated);
      setEditingStatementDate(String(updated.statement_date || ''));
      setStatements((prev) => prev.map((row) => (row.id === updated.id ? { ...row, ...updated } : row)));
      await load();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setSavingStatementDate(false);
    }
  }

  useEffect(() => {
    loadBanks();
    setSelected(null);
    setEditingStatementDate('');
    setLines([]);
    setLinesTotal(0);
    setStatementsPage(1);
    setLinesPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    load();
  }, [activeProfileKey, bankCodes, statementsPage, statementsPageSize]);

  useEffect(() => {
    if (!selected?.id) {
      return;
    }
    loadStatementLines(selected.id);
  }, [activeProfileKey, selected?.id, linesPage, linesPageSize]);

  return (
    <div className="grid">
      <Panel title="Statements">
        {error && <p className="error">{error}</p>}
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <span className="muted">Canonical statement headers with replace-on-identity semantics.</span>
          <div className="row">
            <button className="ghost" onClick={load}>Refresh</button>
            <button className="ghost" onClick={reparseAll} disabled={reparseAllRunning}>
              {reparseAllRunning ? 'Queueing...' : 'Reparse All'}
            </button>
          </div>
        </div>
        <div className="dashboard-filters" style={{ marginTop: '0.75rem' }}>
          <MultiSelectDropdown
            id="statements-banks"
            label="Banks"
            options={bankOptions}
            value={bankCodes}
            placeholder="All banks"
            onChange={(nextCodes) => {
              setStatementsPage(1);
              setBankCodes(nextCodes);
            }}
          />
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
        <TablePagination
          page={statementsPage}
          pageSize={statementsPageSize}
          total={statementsTotal}
          itemLabel="statements"
          onPageChange={setStatementsPage}
          onPageSizeChange={(next) => {
            setStatementsPageSize(next);
            setStatementsPage(1);
          }}
        />
      </Panel>

      <div ref={detailPanelRef}>
        <Panel title="Statement Detail">
          {selected ? (
            <>
            <div className="row" style={{ justifyContent: 'space-between', marginBottom: '0.65rem' }}>
              <span className="muted">Statement metadata and parsed line items</span>
              <div className="row" style={{ alignItems: 'center' }}>
                <span className="muted">Statement date</span>
                <input
                  type="date"
                  value={editingStatementDate}
                  onChange={(event) => setEditingStatementDate(event.target.value)}
                />
                <button
                  className="primary"
                  onClick={saveStatementDate}
                  disabled={
                    savingStatementDate
                    || !editingStatementDate
                    || editingStatementDate === selected.statement_date
                  }
                >
                  {savingStatementDate ? 'Saving...' : 'Save Date'}
                </button>
              </div>
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
            <TablePagination
              page={linesPage}
              pageSize={linesPageSize}
              total={linesTotal}
              itemLabel="lines"
              onPageChange={setLinesPage}
              onPageSizeChange={(next) => {
                setLinesPageSize(next);
                setLinesPage(1);
              }}
            />
            </>
          ) : (
            <p className="muted">Select a statement to inspect lines.</p>
          )}
        </Panel>
      </div>
    </div>
  );
}
