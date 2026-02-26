import { useEffect, useMemo, useState } from 'react';
import { Outlet, useLocation } from 'react-router-dom';

import { routeLabel } from '../navigation';
import { useActiveProfileKey } from '../profileStore';
import { MobileDrawerNav } from './MobileDrawerNav';
import { SidebarNav } from './SidebarNav';

export function AppShell() {
  const location = useLocation();
  const activeProfileKey = useActiveProfileKey();
  const [drawerOpen, setDrawerOpen] = useState(false);

  useEffect(() => {
    setDrawerOpen(false);
  }, [location.pathname]);

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
        </header>

        <main className="app-content" key={activeProfileKey}>
          <Outlet />
        </main>
      </div>

      <MobileDrawerNav open={drawerOpen} onClose={() => setDrawerOpen(false)} />
    </div>
  );
}
