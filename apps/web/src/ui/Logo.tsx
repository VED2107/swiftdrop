/** Two devices and the line between them; the accent end is always "where it's going". */
export function Logo({ size = 22 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden>
      <rect x="1" y="1" width="22" height="22" rx="7" fill="var(--surface-2)" />
      <path d="M7.5 12h9" stroke="var(--text-3)" strokeWidth="1.5" strokeLinecap="round" />
      <circle cx="7" cy="12" r="2.4" fill="var(--text)" />
      <circle cx="17" cy="12" r="2.4" fill="var(--accent)" />
    </svg>
  );
}
