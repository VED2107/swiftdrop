import { useId } from "react";

/** The SwiftDrop mark: a drop in flight with a swift's forked tail. 256-unit artwork. */
export const SWIFT_PATH =
  "M79.45 204.94 L98.16 150.71 L41.5 159.72 L97.57 75.35 A62.32 62.32 0 1 1 172.27 164.37 Z";

/** App-icon tile: the white mark on a red tile, same as the Windows and Android icons. */
export function Logo({ size = 22 }: { size?: number }) {
  const id = useId();
  return (
    <svg width={size} height={size} viewBox="0 0 256 256" aria-hidden>
      <defs>
        <radialGradient id={id} cx="0.32" cy="0.26" r="0.95">
          <stop offset="0" stopColor="#ef4236" />
          <stop offset="1" stopColor="#a91f18" />
        </radialGradient>
      </defs>
      <rect width="256" height="256" rx="64" fill={`url(#${id})`} />
      <path transform="translate(128 128) scale(0.62) translate(-128 -124)" fill="#fff" d={SWIFT_PATH} />
    </svg>
  );
}
