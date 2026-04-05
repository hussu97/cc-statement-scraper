import { useState } from 'react';

import { api, ApiError } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';
import type { Job } from '../types/statements';

export function UploadPage() {
  const [files, setFiles] = useState<FileList | null>(null);
  const [response, setResponse] = useState<Job | null>(null);
  const [error, setError] = useState<{ message: string; data?: unknown } | null>(null);

  async function upload() {
    if (!files || files.length === 0) {
      setError({ message: 'Select one or more PDF files first.' });
      return;
    }

    const form = new FormData();
    Array.from(files).forEach((file) => form.append('files', file));

    try {
      setError(null);
      const job = await api.upload<Job>('/jobs/upload', form);
      setResponse(job);
    } catch (err) {
      if (err instanceof ApiError) {
        setError({ message: err.message, data: err.data });
      } else {
        setError({ message: (err as Error).message });
      }
    }
  }

  return (
    <div className="grid">
      <Panel title="Manual PDF Upload">
        <p className="muted">
          Upload one or more statement PDFs. Bank is detected automatically from PDF contents.
        </p>
        {error && (
          <div className="error">
            <p>{error.message}</p>
            {error.data !== undefined && (
              <pre style={{ marginTop: '0.5rem', fontSize: '0.8em', whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
                {typeof error.data === 'string' ? error.data : JSON.stringify(error.data, null, 2)}
              </pre>
            )}
          </div>
        )}
        <div className="row">
          <input type="file" accept="application/pdf" multiple onChange={(e) => setFiles(e.target.files)} />
          <button className="primary" onClick={upload}>Upload & Ingest</button>
        </div>
      </Panel>

      <Panel title="Latest Upload Job">
        {response ? <JsonView value={response} /> : <p className="muted">No upload job submitted yet.</p>}
      </Panel>
    </div>
  );
}
