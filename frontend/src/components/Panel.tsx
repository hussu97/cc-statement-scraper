import { ReactNode } from 'react';

export function Panel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="panel">
      <h3>{title}</h3>
      <div style={{ marginTop: '0.65rem' }}>{children}</div>
    </section>
  );
}
