import { useEffect, useState } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';

import { api } from './api';
import { AppShell } from './components/AppShell';
import { RequireAuth } from './components/RequireAuth';
import { clearAuthUser, setAuthUser } from './authStore';
import { DEFAULT_ROUTE } from './navigation';
import { DashboardPage } from './pages/DashboardPage';
import { EmailIngestionPage } from './pages/EmailIngestionPage';
import { ExportsDiagnosticsPage } from './pages/ExportsDiagnosticsPage';
import { JobsPage } from './pages/JobsPage';
import { LoginPage } from './pages/LoginPage';
import { RawLinesPage } from './pages/RawLinesPage';
import { RuntimeSettingsPage } from './pages/RuntimeSettingsPage';
import { RulesPage } from './pages/RulesPage';
import { SchedulesPage } from './pages/SchedulesPage';
import { StatementsPage } from './pages/StatementsPage';
import { UploadPage } from './pages/UploadPage';
import { setActiveProfileKey } from './profileStore';

type LoginResponse = {
  user: {
    email: string;
    display_name: string;
    default_profile_key: string;
    role: string;
  };
};

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
        setActiveProfileKey(payload.user.default_profile_key);
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
          <Route path="/rules" element={<RulesPage />} />
          <Route path="/schedules" element={<SchedulesPage />} />
          <Route path="/ops" element={<ExportsDiagnosticsPage />} />
          <Route path="*" element={<Navigate to={DEFAULT_ROUTE} replace />} />
        </Route>
      </Route>
    </Routes>
  );
}
