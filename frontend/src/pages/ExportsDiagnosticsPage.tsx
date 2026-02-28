import { useEffect, useState } from 'react';

import { api } from '../api';
import { isAbortError } from '../lib/errors';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';

type BankOut = {
  code: string;
  name: string;
};

export function ExportsDiagnosticsPage() {
  const [year, setYear] = useState<number>(new Date().getFullYear());
  const [samplesDir, setSamplesDir] = useState('');
  const [banks, setBanks] = useState<BankOut[]>([]);
  const [banksLoading, setBanksLoading] = useState(true);
  const [bankCode, setBankCode] = useState('');
  const [result, setResult] = useState<unknown>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();

    async function loadBanks() {
      try {
        const rows = await api.get<BankOut[]>('/banks', { signal: controller.signal });
        setBanks(rows);
        if (rows.length > 0 && !bankCode) {
          setBankCode(rows[0].code);
        }
      } catch (err) {
        if (!isAbortError(err)) {
          setError((err as Error).message);
        }
      } finally {
        setBanksLoading(false);
      }
    }

    loadBanks();
    return () => controller.abort();
  }, []);

  async function requestWorkbookExport() {
    try {
      setError(null);
      const resp = await api.post('/exports/workbook', { year });
      setResult(resp);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function runParserValidate() {
    try {
      setError(null);
      const resp = await api.post('/diagnostics/parser-validate', {
        samples_dir: samplesDir,
        strict: true,
      });
      setResult(resp);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function runBankConnectionTest() {
    try {
      setError(null);
      const resp = await api.post('/diagnostics/bank-connection-test', {
        bank_code: bankCode,
      });
      setResult(resp);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <div className="grid">
      <Panel title="Workbook Export">
        {error && <p className="error">{error}</p>}
        <div className="row">
          <input type="number" value={year} onChange={(e) => setYear(Number(e.target.value))} />
          <button className="primary" onClick={requestWorkbookExport}>Queue Export Job</button>
        </div>
      </Panel>

      <Panel title="Parser Validation">
        <p className="muted">Runs bank parser checks against local samples folder.</p>
        <div className="row">
          <input value={samplesDir} onChange={(e) => setSamplesDir(e.target.value)} placeholder="Samples directory path" />
          <button className="primary" onClick={runParserValidate}>Queue Validation Job</button>
        </div>
      </Panel>

      <Panel title="Bank Connection Test">
        <div className="row">
          {banksLoading ? (
            <span className="muted">Loading banks...</span>
          ) : (
            <select value={bankCode} onChange={(e) => setBankCode(e.target.value)}>
              {banks.map((bank) => (
                <option key={bank.code} value={bank.code}>{bank.code}</option>
              ))}
            </select>
          )}
          <button className="primary" onClick={runBankConnectionTest} disabled={banksLoading || !bankCode}>
            Queue Connection Test
          </button>
        </div>
      </Panel>

      <Panel title="Latest Action Response">
        {result ? <JsonView value={result} /> : <p className="muted">No actions executed yet.</p>}
      </Panel>
    </div>
  );
}
