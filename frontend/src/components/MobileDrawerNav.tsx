import { SidebarNav } from './SidebarNav';

export function MobileDrawerNav({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <div className={`mobile-drawer${open ? ' open' : ''}`}>
      <button type="button" aria-label="Close navigation" className="mobile-drawer-backdrop" onClick={onClose} />
      <aside className="mobile-drawer-panel" aria-label="Mobile navigation">
        <div className="mobile-drawer-header">
          <strong>Navigation</strong>
          <button type="button" className="ghost" onClick={onClose}>
            Close
          </button>
        </div>
        <SidebarNav onNavigate={onClose} />
      </aside>
    </div>
  );
}
