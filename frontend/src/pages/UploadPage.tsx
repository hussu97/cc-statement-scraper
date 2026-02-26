import { useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';

export function UploadPage() {
  const [files, setFiles] = useState<FileList | null>(null);
  const [response, setResponse] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);

  async function upload() {
    if (!files || files.length === 0) {
      setError('Select one or more PDF files first.');
      return;
    }

    const form = new FormData();
    Array.from(files).forEach((file) => form.append('files', file));

    try {
      setError(null);
      const job = await api.upload<any>('/jobs/upload', form);
      setResponse(job);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  return (
    <div className="grid">
      <Panel title="Manual PDF Upload">
        <p className="muted">
          Upload one or more statement PDFs. Bank is detected automatically from PDF contents.
        </p>
        {error && <p className="error">{error}</p>}
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
