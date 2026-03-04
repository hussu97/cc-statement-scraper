import { useEffect, useRef, useState } from 'react';

import { api } from '../api';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';
import type { Job, JobItem, JobLogEntry, PagedResponse } from '../types/statements';

const ITEM_STATUS_ICON: Record<string, string> = {
  queued: '·',
  running: '▶',
  done: '✓',
  failed: '✗',
  manual_required: '!',
  skipped: '–',
};

const LOG_LEVEL_COLOR: Record<string, string> = {
  info: 'inherit',
  warning: '#f59e0b',
  warn: '#f59e0b',
  error: '#ef4444',
  critical: '#ef4444',
};

const ITEM_STATUS_COLOR: Record<string, string> = {
  queued: 'var(--color-muted, #888)',
  running: 'var(--color-primary, #0070f3)',
  done: '#22c55e',
  failed: '#ef4444',
  manual_required: '#f59e0b',
  skipped: 'var(--color-muted, #888)',
};

function isActiveStatus(status: string) {
  return status === 'queued' || status === 'running';
}

function JobLogPanel({ job, logs }: { job: Job | null; logs: JobLogEntry[] }) {
  if (!job) {
    return <p className="muted">Select a job to view its progress log.</p>;
  }

  const active = isActiveStatus(job.status);
  const items: JobItem[] = Array.isArray(job.items) ? job.items : [];

  return (
    <div>
      <div style={{ display: 'flex', gap: '1rem', alignItems: 'center', marginBottom: '0.5rem', flexWrap: 'wrap' }}>
        <strong>#{job.id}</strong>
        <span className="badge">{job.status.toUpperCase()}</span>
        <span className="muted">{job.job_type}</span>
        {job.progress_percent != null && <span>{job.progress_percent}%</span>}
        {active && <span className="muted" style={{ fontSize: '0.8rem' }}>● live</span>}
        {job.started_at && (
          <span className="muted" style={{ fontSize: '0.8rem' }}>
            started {formatLocalDateTime(job.started_at)}
          </span>
        )}
        {job.finished_at && (
          <span className="muted" style={{ fontSize: '0.8rem' }}>
            finished {formatLocalDateTime(job.finished_at)}
          </span>
        )}
      </div>

      {job.progress_percent != null && (
        <div style={{ background: 'var(--color-border, #e5e7eb)', borderRadius: '4px', height: '6px', marginBottom: '1rem' }}>
          <div
            style={{
              background: job.status === 'failed' ? '#ef4444' : 'var(--color-primary, #0070f3)',
              width: `${job.progress_percent}%`,
              height: '100%',
              borderRadius: '4px',
              transition: 'width 0.4s ease',
            }}
          />
        </div>
      )}

      {items.length > 0 && (
        <div style={{ fontFamily: 'monospace', fontSize: '0.82rem', overflowX: 'auto' }}>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '1.2rem 5rem 7rem 10rem 1fr',
              gap: '0 0.75rem',
              color: 'var(--color-muted, #888)',
              paddingBottom: '0.25rem',
              borderBottom: '1px solid var(--color-border, #e5e7eb)',
              marginBottom: '0.25rem',
              fontWeight: 600,
            }}
          >
            <span />
            <span>Bank</span>
            <span>Month</span>
            <span>Status</span>
            <span>Message</span>
          </div>
          {items.map((item) => (
            <div
              key={item.id}
              style={{
                display: 'grid',
                gridTemplateColumns: '1.2rem 5rem 7rem 10rem 1fr',
                gap: '0 0.75rem',
                padding: '0.2rem 0',
                borderBottom: '1px solid var(--color-border, #e5e7eb)',
              }}
            >
              <span style={{ color: ITEM_STATUS_COLOR[item.status] ?? 'inherit' }}>
                {ITEM_STATUS_ICON[item.status] ?? '?'}
              </span>
              <span>{item.bank_code ?? '—'}</span>
              <span>{item.target_month ?? '—'}</span>
              <span style={{ color: ITEM_STATUS_COLOR[item.status] ?? 'inherit' }}>{item.status}</span>
              <span style={{ color: 'var(--color-muted, #888)', whiteSpace: 'pre-wrap' }}>{item.message ?? ''}</span>
            </div>
          ))}
        </div>
      )}

      {items.length === 0 && (
        <p className="muted" style={{ fontFamily: 'monospace', fontSize: '0.85rem' }}>
          No items yet — job is {job.status}.
        </p>
      )}

      {job.error_message && (
        <p className="error" style={{ marginTop: '0.75rem', fontFamily: 'monospace', fontSize: '0.85rem' }}>
          {job.error_message}
        </p>
      )}

      <div style={{ marginTop: '1.25rem' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.4rem' }}>
          <strong style={{ fontSize: '0.85rem' }}>Terminal output</strong>
          {active && <span className="muted" style={{ fontSize: '0.75rem' }}>● live</span>}
        </div>
        <div
          style={{
            fontFamily: 'monospace',
            fontSize: '0.78rem',
            background: 'var(--color-surface-2, #1a1a1a)',
            color: '#d4d4d4',
            borderRadius: '6px',
            padding: '0.6rem 0.8rem',
            maxHeight: '340px',
            overflowY: 'auto',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
          }}
        >
          {logs.length === 0 ? (
            <span style={{ color: '#666' }}>{active ? 'Waiting for output…' : 'No logs recorded for this job.'}</span>
          ) : (
            logs.map((entry) => (
              <div key={entry.id} style={{ color: LOG_LEVEL_COLOR[entry.level] ?? 'inherit', marginBottom: '0.1rem' }}>
                <span style={{ color: '#666', userSelect: 'none' }}>{entry.created_at.slice(11, 19)} </span>
                {entry.level !== 'info' && (
                  <span style={{ color: LOG_LEVEL_COLOR[entry.level], fontWeight: 600 }}>[{entry.level.toUpperCase()}] </span>
                )}
                {entry.message}
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

export function JobsPage() {
  const activeProfileKey = useActiveProfileKey();

  const [jobs, setJobs] = useState<Job[]>([]);
  const [jobsPage, setJobsPage] = useState(1);
  const [jobsPageSize, setJobsPageSize] = useState(100);
  const [jobsTotal, setJobsTotal] = useState(0);
  const [activeJob, setActiveJob] = useState<Job | null>(null);
  const [liveJob, setLiveJob] = useState<Job | null>(null);
  const [jobLogs, setJobLogs] = useState<JobLogEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const liveJobPollRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const jobLogPanelRef = useRef<HTMLDivElement | null>(null);

  async function loadJobs(nextPage = jobsPage, nextPageSize = jobsPageSize) {
    const params = new URLSearchParams();
    params.set('page', String(nextPage));
    params.set('page_size', String(nextPageSize));
    const data = await api.get<PagedResponse<Job>>(`/jobs?${params.toString()}`);
    const total = Number(data.total || 0);
    setJobsTotal(total);
    setJobs(data.items || []);
    const totalPages = Math.max(1, Math.ceil(total / Math.max(nextPageSize, 1)));
    if (nextPage > totalPages) {
      setJobsPage(totalPages);
    }
  }

  async function cancelJob(id: number) {
    try {
      await api.post(`/jobs/${id}/cancel`);
      await loadJobs();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function cancelAllJobs() {
    try {
      setError(null);
      await api.post('/jobs/cancel-all');
      await loadJobs();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function downloadExport(exportId: number) {
    try {
      setError(null);
      const { blob, filename } = await api.downloadFile(`/exports/${exportId}/download`);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  useEffect(() => {
    setJobsPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    loadJobs();
    const timer = setInterval(loadJobs, 5000);
    return () => clearInterval(timer);
  }, [activeProfileKey, jobsPage, jobsPageSize]);

  // Live-poll the selected job (and its logs) while it is queued or running.
  useEffect(() => {
    if (liveJobPollRef.current) {
      clearTimeout(liveJobPollRef.current);
      liveJobPollRef.current = null;
    }

    if (!activeJob) {
      setLiveJob(null);
      setJobLogs([]);
      return;
    }

    setLiveJob(activeJob);
    setJobLogs([]);

    // Fetch logs once immediately (even for finished jobs).
    api.get<JobLogEntry[]>(`/jobs/${activeJob.id}/logs`).then(setJobLogs).catch(() => {});

    if (!isActiveStatus(activeJob.status)) return;

    let cancelled = false;

    const poll = async () => {
      if (cancelled) return;
      try {
        const [updated, logs] = await Promise.all([
          api.get<Job>(`/jobs/${activeJob.id}`),
          api.get<JobLogEntry[]>(`/jobs/${activeJob.id}/logs`),
        ]);
        if (!cancelled) {
          setLiveJob(updated);
          setJobLogs(logs);
          if (isActiveStatus(updated.status)) {
            liveJobPollRef.current = setTimeout(poll, 3000);
          }
        }
      } catch {
        if (!cancelled) {
          liveJobPollRef.current = setTimeout(poll, 3000);
        }
      }
    };

    liveJobPollRef.current = setTimeout(poll, 3000);

    return () => {
      cancelled = true;
      if (liveJobPollRef.current) {
        clearTimeout(liveJobPollRef.current);
        liveJobPollRef.current = null;
      }
    };
  }, [activeJob]);

  return (
    <div className="grid">
      <div ref={jobLogPanelRef} style={{ scrollMarginTop: '5rem' }}>
        <Panel title={liveJob ? `Job Log — #${liveJob.id}` : 'Job Log'}>
          <JobLogPanel job={liveJob} logs={jobLogs} />
        </Panel>
      </div>

      <Panel title="Jobs">
        {error && <p className="error">{error}</p>}
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <span className="muted">Live status for upload/reclassify/export/diagnostics jobs across all pages.</span>
          <div className="row">
            <button className="ghost" onClick={() => loadJobs()}>Refresh</button>
            <button className="ghost" onClick={cancelAllJobs}>Cancel All Jobs</button>
          </div>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Type</th>
                <th>Status</th>
                <th>Progress</th>
                <th>Created</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {jobs.map((job) => (
                <tr key={job.id} style={activeJob?.id === job.id ? { background: 'var(--color-row-active, #f0f7ff)' } : undefined}>
                  <td>{job.id}</td>
                  <td>{job.job_type}</td>
                  <td>{job.status}</td>
                  <td>{job.progress_percent}%</td>
                  <td>{formatLocalDateTime(job.created_at)}</td>
                  <td>
                    <button className="ghost" onClick={() => {
                      setActiveJob(job);
                      window.requestAnimationFrame(() => {
                        jobLogPanelRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
                      });
                    }}>View</button>{' '}
                    {job.status === 'queued' || job.status === 'running' ? (
                      <button className="ghost" onClick={() => cancelJob(job.id)}>Cancel</button>
                    ) : null}
                    {job.job_type === 'export_workbook' && job.status === 'succeeded' && job.result_json?.export_id ? (
                      <>{' '}<button className="ghost" onClick={() => downloadExport(job.result_json!.export_id as number)}>Download</button></>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <TablePagination
          page={jobsPage}
          pageSize={jobsPageSize}
          total={jobsTotal}
          itemLabel="jobs"
          onPageChange={setJobsPage}
          onPageSizeChange={(next) => {
            setJobsPageSize(next);
            setJobsPage(1);
          }}
        />
      </Panel>
    </div>
  );
}
