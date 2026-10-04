import { useEffect, useState } from "react";
import { latencyReports, onLatency, type LatencyReport } from "../lib/latency.ts";

const ROWS: Array<[keyof LatencyReport, string]> = [
  ["tapToPickedMs", "Tap → picker returned (iOS export + choosing)"],
  ["pickedToSendMs", "Picker → Send tapped (reviewing)"],
  ["sendToUiMs", "Send → transfer screen"],
  ["hasherMs", "Hasher ready"],
  ["createMs", "Manifest round trip"],
  ["sendToFirstReadMs", "Send → first bytes read"],
  ["sendToFirstByteMs", "Send → first byte leaves phone"],
  ["sendToFirstAckMs", "Send → PC confirmed first bytes"],
  ["sendToFirstFileMs", "Send → first file verified on PC"],
];

/** Time-to-first-byte readout for real-device testing. Only with ?debug=1 in the address. */
export function LatencyCard() {
  const [r, setR] = useState<LatencyReport | null>(() => latencyReports().at(-1) ?? null);
  useEffect(() => onLatency(() => setR(latencyReports().at(-1) ?? null)), []);
  if (!r) return <p className="t-small" data-testid="latency">Latency: send something to measure.</p>;
  return (
    <section className="flex flex-col gap-1 t-small num" data-testid="latency" aria-label="Send latency">
      <p style={{ color: "var(--text)" }}>
        Last send · {r.files} files · {(r.bytes / 1e6).toFixed(1)} MB
      </p>
      {ROWS.map(([k, label]) => (
        <div key={k} className="flex justify-between gap-4">
          <span>{label}</span>
          <span style={{ color: "var(--text)" }}>{r[k] === null ? "—" : `${r[k]} ms`}</span>
        </div>
      ))}
    </section>
  );
}
