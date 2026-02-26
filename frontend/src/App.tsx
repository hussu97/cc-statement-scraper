import { Navigate, Route, Routes } from 'react-router-dom';

import { AppShell } from './components/AppShell';
import { DEFAULT_ROUTE } from './navigation';
import { DashboardPage } from './pages/DashboardPage';
import { ExportsDiagnosticsPage } from './pages/ExportsDiagnosticsPage';
import { JobsPage } from './pages/JobsPage';
import { RawLinesPage } from './pages/RawLinesPage';
import { RuntimeSettingsPage } from './pages/RuntimeSettingsPage';
import { RulesPage } from './pages/RulesPage';
import { SchedulesPage } from './pages/SchedulesPage';
import { StatementsPage } from './pages/StatementsPage';
import { UploadPage } from './pages/UploadPage';

export default function App() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route path="/" element={<Navigate to={DEFAULT_ROUTE} replace />} />
        <Route path="/dashboard" element={<DashboardPage />} />
        <Route path="/jobs" element={<JobsPage />} />
        <Route path="/upload" element={<UploadPage />} />
        <Route path="/lines" element={<RawLinesPage />} />
        <Route path="/statements" element={<StatementsPage />} />
        <Route path="/runtime-settings" element={<RuntimeSettingsPage />} />
        <Route path="/rules" element={<RulesPage />} />
        <Route path="/schedules" element={<SchedulesPage />} />
        <Route path="/ops" element={<ExportsDiagnosticsPage />} />
        <Route path="*" element={<Navigate to={DEFAULT_ROUTE} replace />} />
      </Route>
    </Routes>
  );
}
