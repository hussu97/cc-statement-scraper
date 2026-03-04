import { useEffect, useRef, useState } from 'react';

import { api, ApiError } from '../api';
import { JsonView } from '../components/JsonView';
import { MultiSelectDropdown } from '../components/MultiSelectDropdown';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';
import type { Category, Job, PagedResponse, Statement, StatementLine } from '../types/statements';

export function StatementsPage() {
  const activeProfileKey = useActiveProfileKey();
  const detailPanelRef = useRef<HTMLDivElement | null>(null);
  const [statements, setStatements] = useState<Statement[]>([]);
  const [statementsPage, setStatementsPage] = useState(1);
  const [statementsPageSize, setStatementsPageSize] = useState(100);
  const [statementsTotal, setStatementsTotal] = useState(0);
  const [bankOptions, setBankOptions] = useState<string[]>([]);
  const [bankCodes, setBankCodes] = useState<string[]>([]);
  const [selected, setSelected] = useState<(Statement & { reparseJob?: Job; reparseAllJob?: Job }) | null>(null);
  const [lines, setLines] = useState<StatementLine[]>([]);
  const [linesPage, setLinesPage] = useState(1);
  const [linesPageSize, setLinesPageSize] = useState(100);
  const [linesTotal, setLinesTotal] = useState(0);
  const [allCategories, setAllCategories] = useState<Category[]>([]);
  const [overridePending, setOverridePending] = useState<Record<number, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [reparseAllRunning, setReparseAllRunning] = useState(false);
  const [editingStatementDate, setEditingStatementDate] = useState('');
  const [savingStatementDate, setSavingStatementDate] = useState(false);
  const [dateConflict, setDateConflict] = useState<{ conflicting: Statement; pendingDate: string } | null>(null);
  const [resolvingConflict, setResolvingConflict] = useState(false);

  async function loadBanks() {
    try {
      const rows = await api.get<{ code: string }[]>('/banks');
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
      const data = await api.get<PagedResponse<Statement>>(`/statements?${params.toString()}`);
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
      const lineResp = await api.get<PagedResponse<StatementLine>>(
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

  async function loadCategories() {
    try {
      const cats = await api.get<Category[]>('/categories');
      setAllCategories(cats);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function pinOverride(lineId: number) {
    const category = overridePending[lineId];
    if (!category) return;
    try {
      const updated = await api.put<StatementLine>(`/transactions/${lineId}/category-override`, { category });
      setLines((prev) => prev.map((line) => (line.id === lineId ? { ...line, category: updated.category, category_override: updated.category_override } : line)));
      setOverridePending((prev) => {
        const next = { ...prev };
        delete next[lineId];
        return next;
      });
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function clearOverride(lineId: number) {
    try {
      const updated = await api.delete<StatementLine>(`/transactions/${lineId}/category-override`);
      setLines((prev) => prev.map((line) => (line.id === lineId ? { ...line, category: updated.category, category_override: updated.category_override } : line)));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  function openStatement(statement: Statement) {
    setSelected(statement);
    setEditingStatementDate(String(statement.statement_date || ''));
    setLinesPage(1);
    setLinesTotal(0);
    loadCategories();
    window.requestAnimationFrame(() => {
      detailPanelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  async function reparse(statementId: number) {
    try {
      const job = await api.post<Job>(`/statements/${statementId}/reparse`);
      setSelected((prev) => (prev ? { ...prev, reparseJob: job } : prev));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function reparseAll() {
    try {
      setError(null);
      setReparseAllRunning(true);
      const job = await api.post<Job>('/statements/reparse-all');
      setSelected((prev) => (prev ? { ...prev, reparseAllJob: job } : prev));
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
      const updated = await api.patch<Statement>(`/statements/${selected.id}`, {
        statement_date: editingStatementDate,
      });
      setSelected(updated);
      setEditingStatementDate(String(updated.statement_date || ''));
      setStatements((prev) => prev.map((row) => (row.id === updated.id ? { ...row, ...updated } : row)));
      await load();
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        const body = err.data as { detail?: { code?: string; conflicting_statement?: Statement } };
        if (body?.detail?.code === 'DATE_CONFLICT' && body.detail.conflicting_statement) {
          setDateConflict({ conflicting: body.detail.conflicting_statement, pendingDate: editingStatementDate });
          return;
        }
      }
      setError((err as Error).message);
    } finally {
      setSavingStatementDate(false);
    }
  }

  async function resolveConflict(deleteId: number) {
    if (!dateConflict || !selected) return;
    const survivorId = deleteId === selected.id ? dateConflict.conflicting.id : selected.id;
    try {
      setResolvingConflict(true);
      setError(null);
      await api.delete(`/statements/${deleteId}`);
      await api.patch(`/statements/${survivorId}`, { statement_date: dateConflict.pendingDate });
      if (deleteId === selected.id) {
        setSelected(null);
        setEditingStatementDate('');
        setLines([]);
        setLinesTotal(0);
      } else {
        setEditingStatementDate(dateConflict.pendingDate);
      }
      setDateConflict(null);
      await load();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setResolvingConflict(false);
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
    <>
    {dateConflict && selected && (
      <div
        style={{
          position: 'fixed',
          inset: 0,
          backgroundColor: 'rgba(0,0,0,0.45)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 1000,
        }}
        onClick={() => setDateConflict(null)}
      >
        <div
          style={{
            background: 'var(--surface, #1e1e2e)',
            border: '1px solid var(--border, #3a3a4a)',
            borderRadius: '8px',
            padding: '1.5rem',
            maxWidth: '720px',
            width: '95%',
            boxShadow: '0 8px 32px rgba(0,0,0,0.5)',
          }}
          onClick={(e) => e.stopPropagation()}
        >
          <h4 style={{ margin: '0 0 0.35rem' }}>Date Conflict</h4>
          <p className="muted" style={{ margin: '0 0 1.25rem', lineHeight: 1.5 }}>
            Another statement shares the same bank and reference with date <strong>{dateConflict.pendingDate}</strong>.
            Choose which statement to delete — the survivor will be set to <strong>{dateConflict.pendingDate}</strong>.
          </p>
          <div className="row" style={{ gap: '1rem', alignItems: 'stretch' }}>
            {([
              { stmt: selected, label: 'Current statement (being edited)' },
              { stmt: dateConflict.conflicting, label: 'Conflicting statement' },
            ] as { stmt: Statement; label: string }[]).map(({ stmt, label }) => (
              <div
                key={stmt.id}
                style={{
                  flex: 1,
                  border: '1px solid var(--border, #3a3a4a)',
                  borderRadius: '6px',
                  padding: '1rem',
                  display: 'flex',
                  flexDirection: 'column',
                  gap: '0.35rem',
                }}
              >
                <span className="muted" style={{ fontSize: '0.75rem' }}>{label}</span>
                <div><strong>ID:</strong> {stmt.id}</div>
                <div><strong>Bank:</strong> {stmt.bank_code}</div>
                <div><strong>Reference:</strong> {stmt.statement_reference}</div>
                <div><strong>Date:</strong> {stmt.statement_date}</div>
                <div><strong>Lines:</strong> {stmt.line_count}</div>
                <div><strong>Uploaded:</strong> {stmt.ingested_at ? formatLocalDateTime(stmt.ingested_at) : '—'}</div>
                <button
                  className="ghost"
                  style={{ marginTop: '0.75rem', color: 'var(--error, #e06c75)' }}
                  disabled={resolvingConflict}
                  onClick={() => resolveConflict(stmt.id)}
                >
                  {resolvingConflict ? 'Working...' : 'Delete this one'}
                </button>
              </div>
            ))}
          </div>
          <div className="row" style={{ justifyContent: 'flex-end', marginTop: '1rem' }}>
            <button className="ghost" onClick={() => setDateConflict(null)} disabled={resolvingConflict}>
              Cancel
            </button>
          </div>
        </div>
      </div>
    )}
    <div className="grid">
      <div ref={detailPanelRef} style={{ scrollMarginTop: '5rem' }}>
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
                    <th>Override</th>
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
                      <td>
                        {line.category_override ? (
                          <span title="Category pinned">{line.category} &#x229D;</span>
                        ) : (
                          line.category
                        )}
                      </td>
                      <td>
                        <div className="row" style={{ flexWrap: 'nowrap', gap: '0.25rem' }}>
                          <select
                            value={overridePending[line.id] ?? line.category ?? ''}
                            onChange={(event) =>
                              setOverridePending((prev) => ({ ...prev, [line.id]: event.target.value }))
                            }
                            style={{ minWidth: '130px' }}
                          >
                            {allCategories.map((cat) => (
                              <option key={cat.id} value={cat.name}>{cat.name}</option>
                            ))}
                          </select>
                          <button className="ghost" onClick={() => pinOverride(line.id)}>Pin</button>
                          {line.category_override && (
                            <button className="ghost" onClick={() => clearOverride(line.id)}>Clear</button>
                          )}
                        </div>
                      </td>
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
                <th>Statement Date</th>
                <th>Upload Date</th>
                <th>Lines</th>
                <th>Debit AED</th>
                <th>Credit AED</th>
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
                  <td>{statement.ingested_at ? formatLocalDateTime(statement.ingested_at) : '—'}</td>
                  <td>{statement.line_count}</td>
                  <td>{statement.total_debit_aed.toFixed(2)}</td>
                  <td>{statement.total_credit_aed.toFixed(2)}</td>
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
    </div>
    </>
  );
}
