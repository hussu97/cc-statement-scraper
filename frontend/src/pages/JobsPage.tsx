import { useEffect, useMemo, useState } from 'react';

import { api } from '../api';
import { JsonView } from '../components/JsonView';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';
import type { Bank, Job, PagedResponse } from '../types/statements';

type MonthOption = {
  value: string;
  label: string;
};

const MIN_MONTH_YEAR = 2024;
const MIN_MONTH_INDEX = 1;

function dubaiCurrentYearMonth() {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Dubai',
    year: 'numeric',
    month: '2-digit',
  }).formatToParts(new Date());

  const yearPart = parts.find((part) => part.type === 'year')?.value;
  const monthPart = parts.find((part) => part.type === 'month')?.value;

  const year = Number(yearPart || new Date().getFullYear());
  const month = Number(monthPart || new Date().getMonth() + 1);
  return { year, month };
}

function buildMonthOptions(): MonthOption[] {
  const { year: maxYear, month: maxMonth } = dubaiCurrentYearMonth();
  const options: MonthOption[] = [];

  for (let year = MIN_MONTH_YEAR; year <= maxYear; year += 1) {
    const startMonth = year === MIN_MONTH_YEAR ? MIN_MONTH_INDEX : 1;
    const endMonth = year === maxYear ? maxMonth : 12;

    for (let month = startMonth; month <= endMonth; month += 1) {
      const value = `${year}-${String(month).padStart(2, '0')}`;
      const label = new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString('en-US', {
        month: 'short',
        year: 'numeric',
        timeZone: 'UTC',
      });
      options.push({ value, label });
    }
  }

  return options;
}

export function JobsPage() {
  const activeProfileKey = useActiveProfileKey();
  const monthOptions = useMemo(() => buildMonthOptions(), []);
  const defaultMonth = monthOptions[monthOptions.length - 1]?.value ?? `${MIN_MONTH_YEAR}-01`;

  const [banks, setBanks] = useState<Bank[]>([]);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [jobsPage, setJobsPage] = useState(1);
  const [jobsPageSize, setJobsPageSize] = useState(100);
  const [jobsTotal, setJobsTotal] = useState(0);
  const [selectedBanks, setSelectedBanks] = useState<string[]>([]);
  const [monthFrom, setMonthFrom] = useState(defaultMonth);
  const [monthTo, setMonthTo] = useState(defaultMonth);
  const [download, setDownload] = useState(true);
  const [headless, setHeadless] = useState(false);
  const [timeout, setTimeoutMinutes] = useState(20);
  const [activeJob, setActiveJob] = useState<Job | null>(null);
  const [error, setError] = useState<string | null>(null);

  const fromIndex = monthOptions.findIndex((item) => item.value === monthFrom);
  const toIndex = monthOptions.findIndex((item) => item.value === monthTo);
  const monthCount =
    fromIndex >= 0 && toIndex >= 0 && toIndex >= fromIndex
      ? toIndex - fromIndex + 1
      : 0;

  async function loadBanks() {
    const rows = await api.get<Bank[]>('/banks');
    setBanks(rows);
  }

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

  async function createScrapeJob() {
    try {
      setError(null);
      if (monthFrom > monthTo) {
        setError('Month From must be earlier than or equal to Month To.');
        return;
      }

      const payload = {
        banks: selectedBanks,
        month_from: monthFrom,
        month_to: monthTo,
        download,
        headless,
        login_timeout_minutes: timeout,
      };
      const job = await api.post<Job>('/jobs/scrape', payload);
      setActiveJob(job);
      setJobsPage(1);
      await loadJobs(1, jobsPageSize);
    } catch (err) {
      const message = (err as Error).message || '';
      if (message.includes('HTTP 409')) {
        setError('An identical scrape job is already queued/running.');
        return;
      }
      setError(message);
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

  useEffect(() => {
    loadBanks();
    setJobsPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    loadJobs();
    const timer = setInterval(loadJobs, 5000);
    return () => clearInterval(timer);
  }, [activeProfileKey, jobsPage, jobsPageSize]);

  return (
    <div className="grid">
      <Panel title="Scrape Statements">
        <p className="muted">Select banks and a month-year range (from Jan 2024 to current month), then run scraper job.</p>
        {error && <p className="error">{error}</p>}
        <div className="row">
          {banks.map((bank) => (
            <label key={bank.code} style={{ display: 'flex', gap: '0.3rem', alignItems: 'center' }}>
              <input
                type="checkbox"
                checked={selectedBanks.includes(bank.code)}
                onChange={(e) => {
                  setSelectedBanks((prev) => {
                    if (e.target.checked) {
                      return [...prev, bank.code];
                    }
                    return prev.filter((code) => code !== bank.code);
                  });
                }}
              />
              <span>{bank.code}</span>
              <span className="badge">hist: {bank.supports_historical_month_selection ? 'yes' : 'no'}</span>
            </label>
          ))}
        </div>

        <div className="row" style={{ marginTop: '0.75rem' }}>
          <label>
            Month From
            <select value={monthFrom} onChange={(e) => setMonthFrom(e.target.value)}>
              {monthOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <label>
            Month To
            <select value={monthTo} onChange={(e) => setMonthTo(e.target.value)}>
              {monthOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>

          <label>
            <input type="checkbox" checked={download} onChange={(e) => setDownload(e.target.checked)} /> Download
          </label>
          <label>
            <input type="checkbox" checked={headless} onChange={(e) => setHeadless(e.target.checked)} /> Headless
          </label>
          <input
            type="number"
            min={5}
            max={60}
            value={timeout}
            onChange={(e) => setTimeoutMinutes(Number(e.target.value))}
          />
          <button className="primary" onClick={createScrapeJob}>Run Scrape Job</button>
        </div>
        <p className="muted" style={{ marginTop: '0.5rem' }}>
          Requested range: {monthCount} month(s). Unsupported bank/month combinations are marked as MANUAL_REQUIRED.
        </p>
      </Panel>

      <Panel title="Jobs">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <span className="muted">Live status for scrape/upload/reclassify/export/diagnostics jobs across all pages.</span>
          <button className="ghost" onClick={() => loadJobs()}>Refresh</button>
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
                <tr key={job.id}>
                  <td>{job.id}</td>
                  <td>{job.job_type}</td>
                  <td>{job.status}</td>
                  <td>{job.progress_percent}%</td>
                  <td>{formatLocalDateTime(job.created_at)}</td>
                  <td>
                    <button className="ghost" onClick={() => setActiveJob(job)}>View</button>{' '}
                    {job.status === 'queued' || job.status === 'running' ? (
                      <button className="ghost" onClick={() => cancelJob(job.id)}>Cancel</button>
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

      <Panel title="Job Details">
        {activeJob ? <JsonView value={activeJob} /> : <p className="muted">Select a job to inspect payload, items, and result.</p>}
      </Panel>
    </div>
  );
}
