import { lazy, Suspense, useEffect, useState } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';

import { api } from './api';
import { AppShell } from './components/AppShell';
import { RequireAuth } from './components/RequireAuth';
import { clearAuthUser, setAuthUser } from './authStore';
import { DEFAULT_ROUTE } from './navigation';
import { hasStoredProfileKey, setActiveProfileKey } from './profileStore';
import type { LoginResponse } from './types/auth';

const DashboardPage = lazy(() => import('./pages/DashboardPage').then(m => ({ default: m.DashboardPage })));
const EmailIngestionActivityPage = lazy(() => import('./pages/EmailIngestionActivityPage').then(m => ({ default: m.EmailIngestionActivityPage })));
const EmailIngestionPage = lazy(() => import('./pages/EmailIngestionPage').then(m => ({ default: m.EmailIngestionPage })));
const ExportsDiagnosticsPage = lazy(() => import('./pages/ExportsDiagnosticsPage').then(m => ({ default: m.ExportsDiagnosticsPage })));
const JobsPage = lazy(() => import('./pages/JobsPage').then(m => ({ default: m.JobsPage })));
const LoginPage = lazy(() => import('./pages/LoginPage').then(m => ({ default: m.LoginPage })));
const RawLinesPage = lazy(() => import('./pages/RawLinesPage').then(m => ({ default: m.RawLinesPage })));
const RuntimeSettingsPage = lazy(() => import('./pages/RuntimeSettingsPage').then(m => ({ default: m.RuntimeSettingsPage })));
const RulesPage = lazy(() => import('./pages/RulesPage').then(m => ({ default: m.RulesPage })));
const SchedulesPage = lazy(() => import('./pages/SchedulesPage').then(m => ({ default: m.SchedulesPage })));
const StatementsPage = lazy(() => import('./pages/StatementsPage').then(m => ({ default: m.StatementsPage })));
const UploadPage = lazy(() => import('./pages/UploadPage').then(m => ({ default: m.UploadPage })));

export default function App() {
  const [bootstrapped, setBootstrapped] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function bootstrapAuth() {
      try {
        const payload = await api.get<LoginResponse>('/auth/me');
        if (cancelled) {
          return;
        }
        setAuthUser(payload.user);
        // Only apply the account default on first-ever load; preserve the
        // user's stored choice on every subsequent refresh.
        if (!hasStoredProfileKey()) {
          setActiveProfileKey(payload.user.default_profile_key);
        }
      } catch {
        if (!cancelled) {
          clearAuthUser();
        }
      } finally {
        if (!cancelled) {
          setBootstrapped(true);
        }
      }
    }

    bootstrapAuth();
    return () => {
      cancelled = true;
    };
  }, []);

  if (!bootstrapped) {
    return (
      <div className="login-shell">
        <section className="login-card">
          <p className="muted">Loading...</p>
        </section>
      </div>
    );
  }

  return (
    <Suspense fallback={null}>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route element={<RequireAuth />}>
          <Route element={<AppShell />}>
            <Route path="/" element={<Navigate to={DEFAULT_ROUTE} replace />} />
            <Route path="/dashboard" element={<DashboardPage />} />
            <Route path="/jobs" element={<JobsPage />} />
            <Route path="/upload" element={<UploadPage />} />
            <Route path="/lines" element={<RawLinesPage />} />
            <Route path="/statements" element={<StatementsPage />} />
            <Route path="/runtime-settings" element={<RuntimeSettingsPage />} />
            <Route path="/email-ingestion" element={<EmailIngestionPage />} />
            <Route path="/ingestion-activity" element={<EmailIngestionActivityPage />} />
            <Route path="/rules" element={<RulesPage />} />
            <Route path="/schedules" element={<SchedulesPage />} />
            <Route path="/ops" element={<ExportsDiagnosticsPage />} />
            <Route path="*" element={<Navigate to={DEFAULT_ROUTE} replace />} />
          </Route>
        </Route>
      </Routes>
    </Suspense>
  );
}
