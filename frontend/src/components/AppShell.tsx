import { useEffect, useMemo, useState } from 'react';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';

import { api } from '../api';
import { routeLabel } from '../navigation';
import { clearAuthUser, useAuthUser } from '../authStore';
import { useActiveProfileKey } from '../profileStore';
import { MobileDrawerNav } from './MobileDrawerNav';
import { SidebarNav } from './SidebarNav';

export function AppShell() {
  const navigate = useNavigate();
  const location = useLocation();
  const activeProfileKey = useActiveProfileKey();
  const authUser = useAuthUser();
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    setDrawerOpen(false);
  }, [location.pathname]);

  const title = useMemo(() => routeLabel(location.pathname), [location.pathname]);

  async function logout() {
    try {
      await api.post<void>('/auth/logout');
    } catch {
      // Ignore logout transport errors and clear local session state.
    } finally {
      clearAuthUser();
      navigate('/login', { replace: true });
    }
  }

  return (
    <div className="app-shell">
      <aside className="desktop-sidebar">
        <SidebarNav />
      </aside>

      <div className="app-main">
        <header className="app-bar">
          <div className="app-bar-left">
            <button type="button" className="menu-button" onClick={() => setDrawerOpen(true)}>
              Menu
            </button>
            <div>
              <strong>{title}</strong>
              <p className="muted">Credit card statement platform</p>
            </div>
          </div>

          <div className="app-bar-right">
            <span className="badge">{authUser?.email || 'Unknown user'}</span>
            <button type="button" className="ghost" onClick={logout}>
              Log out
            </button>
          </div>
        </header>

        <main className="app-content" key={activeProfileKey}>
          <Outlet />
        </main>
      </div>

      <MobileDrawerNav open={drawerOpen} onClose={() => setDrawerOpen(false)} />
    </div>
  );
}
