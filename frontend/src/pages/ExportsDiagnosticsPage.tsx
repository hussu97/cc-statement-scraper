import { useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';

export function ExportsDiagnosticsPage() {
  const [year, setYear] = useState<number>(new Date().getFullYear());
  const [samplesDir, setSamplesDir] = useState('');
  const [result, setResult] = useState<unknown>(null);
  const [error, setError] = useState<string | null>(null);

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

      <Panel title="Latest Action Response">
        {result ? <JsonView value={result} /> : <p className="muted">No actions executed yet.</p>}
      </Panel>
    </div>
  );
}
