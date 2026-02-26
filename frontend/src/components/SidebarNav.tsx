import { NavLink } from 'react-router-dom';

import { NAV_SECTIONS } from '../navigation';
import { ProfileSwitcher } from './ProfileSwitcher';

export function SidebarNav({ onNavigate }: { onNavigate?: () => void }) {
  return (
    <div className="sidebar-panel">
      <div className="sidebar-brand">
        <h1>CC Statements</h1>
        <p className="muted">Admin Console</p>
      </div>

      <nav aria-label="Primary navigation">
        {NAV_SECTIONS.map((section) => (
          <section className="nav-section" key={section.title}>
            <h2>{section.title}</h2>
            <div className="nav-links">
              {section.items.map((item) => (
                <NavLink
                  key={item.path}
                  to={item.path}
                  className={({ isActive }) => `nav-link${isActive ? ' active' : ''}`}
                  onClick={onNavigate}
                >
                  {item.label}
                </NavLink>
              ))}
            </div>
          </section>
        ))}
      </nav>

      <ProfileSwitcher />
    </div>
  );
}
