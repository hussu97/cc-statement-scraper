import { useEffect, useMemo, useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';

import { routeLabel } from '../navigation';
import { clearAdminToken, setAdminToken, useAdminToken } from '../authStore';
import { useActiveProfileKey } from '../profileStore';
import { MobileDrawerNav } from './MobileDrawerNav';
import { SidebarNav } from './SidebarNav';

export function AppShell() {
  const location = useLocation();
  const activeProfileKey = useActiveProfileKey();
  const token = useAdminToken();
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [tokenDraft, setTokenDraft] = useState(token);

  useEffect(() => {
    setDrawerOpen(false);
  }, [location.pathname]);

  useEffect(() => {
    setTokenDraft(token);
  }, [token]);

  const title = useMemo(() => routeLabel(location.pathname), [location.pathname]);

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
            <input
              type="password"
              value={tokenDraft}
              onChange={(event) => setTokenDraft(event.target.value)}
              placeholder="Admin API token"
              className="token-input"
            />
            <button
              type="button"
              className="ghost"
              onClick={() => setAdminToken(tokenDraft)}
            >
              Save Token
            </button>
            <button
              type="button"
              className="ghost"
              onClick={() => clearAdminToken()}
              disabled={!token}
            >
              Clear
            </button>
            <span className="badge">{token ? 'API token set' : 'No API token'}</span>
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
