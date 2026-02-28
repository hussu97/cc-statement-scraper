export type NavItem = {
  path: string;
  label: string;
};

export type NavSection = {
  title: string;
  items: NavItem[];
};

export const NAV_SECTIONS: NavSection[] = [
  {
    title: 'Analytics',
    items: [{ path: '/dashboard', label: 'Dashboard' }],
  },
  {
    title: 'Operations',
    items: [
      { path: '/jobs', label: 'Scrape Runs' },
      { path: '/upload', label: 'PDF Upload' },
      { path: '/lines', label: 'Raw Lines' },
      { path: '/statements', label: 'Statements' },
    ],
  },
  {
    title: 'Configuration',
    items: [
      { path: '/email-ingestion', label: 'Email Ingestion' },
      { path: '/runtime-settings', label: 'Runtime Variables' },
      { path: '/rules', label: 'Categories & Rules' },
      { path: '/schedules', label: 'Schedules' },
      { path: '/ops', label: 'Exports & Diagnostics' },
    ],
  },
];

export const DEFAULT_ROUTE = '/dashboard';

export function routeLabel(pathname: string): string {
  for (const section of NAV_SECTIONS) {
    for (const item of section.items) {
      if (pathname === item.path || pathname.startsWith(`${item.path}/`)) {
        return item.label;
      }
    }
  }
  return 'Dashboard';
}
