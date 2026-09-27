import { useMemo } from "react";

/**
 * The server's QR matrix drawn as an object, not a utility: rounded data modules and
 * softened finder eyes. Module size stays ≥ 88% so every phone camera still reads it.
 */
export function QrCode({ size, bits, label }: { size: number; bits: string; label: string }) {
  const paths = useMemo(() => {
    const raw = atob(bits);
    const at = (x: number, y: number) => raw.charCodeAt(y * size + x) === 1;
    const inFinder = (x: number, y: number) => (x < 7 && y < 7) || (x >= size - 7 && y < 7) || (x < 7 && y >= size - 7);
    let d = "";
    for (let y = 0; y < size; y++)
      for (let x = 0; x < size; x++) {
        if (!at(x, y) || inFinder(x, y)) continue;
        // 0.92 module, 0.26 corner radius
        d += `M${x + 0.3} ${y + 0.04}h0.4a0.26 0.26 0 0 1 0.26 0.26v0.4a0.26 0.26 0 0 1-0.26 0.26h-0.4a0.26 0.26 0 0 1-0.26-0.26v-0.4a0.26 0.26 0 0 1 0.26-0.26z`;
      }
    return d;
  }, [size, bits]);

  const eyes = [
    [0, 0],
    [size - 7, 0],
    [0, size - 7],
  ] as const;

  return (
    <svg viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label} className="block w-full h-full">
      <path d={paths} fill="oklch(0.19 0.01 260)" />
      {eyes.map(([x, y]) => (
        <g key={`${x}-${y}`}>
          <rect x={x + 0.5} y={y + 0.5} width={6} height={6} rx={1.9} fill="none" stroke="oklch(0.19 0.01 260)" strokeWidth={1} />
          <rect x={x + 2} y={y + 2} width={3} height={3} rx={0.9} fill="oklch(0.19 0.01 260)" />
        </g>
      ))}
    </svg>
  );
}
