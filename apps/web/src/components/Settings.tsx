import { FolderOpen, Lock, Monitor, Smartphone } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { Api, setToken, type Pairing } from "../lib/api.ts";
import { deviceLabel } from "../lib/env.ts";
import { notify, useApp } from "../lib/store.ts";
import { Sheet } from "../ui/Sheet.tsx";

function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-3 py-5" style={{ boxShadow: "0 1px 0 var(--hairline)" }}>
      <h3 className="t-section">{title}</h3>
      {children}
    </section>
  );
}

/** Secondary by design: where files land, who's paired, how to connect, and the privacy promise. */
export function HostSettings({ onClose }: { onClose: () => void }) {
  const destination = useApp((s) => s.destination);
  const devices = useApp((s) => s.devices);
  const [busy, setBusy] = useState(false);
  const [pairing, setPairing] = useState<Pairing | null>(null);
  useEffect(() => void Api.pairing().then(setPairing).catch(() => undefined), []);

  return (
    <Sheet title="Settings" onClose={onClose}>
      <Group title="Download location">
        <p className="t-body break-all" style={{ color: "var(--text)" }}>
          {destination || "…"}
        </p>
        <div className="flex flex-wrap gap-2">
          <button
            className="btn btn-secondary btn-sm"
            disabled={busy}
            onClick={async () => {
              setBusy(true);
              try {
                const r = await Api.chooseFolder();
                if (r.changed) notify("New files will be saved there.");
              } catch (e) {
                notify((e as Error).message, "error");
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "Choose in the window…" : "Change…"}
          </button>
          <button className="btn btn-ghost btn-sm" onClick={() => void Api.openFolder().catch((e: Error) => notify(e.message, "error"))}>
            <FolderOpen size={15} strokeWidth={1.75} /> Open folder
          </button>
        </div>
      </Group>

      <Group title="Devices">
        {devices.length === 0 ? (
          <p className="t-small">No paired devices yet.</p>
        ) : (
          <div>
            {devices.map((d) => (
              <div key={d.id} className="row" style={{ gridTemplateColumns: "32px 1fr auto" }}>
                <Smartphone size={18} strokeWidth={1.5} style={{ color: "var(--text-3)" }} />
                <div>
                  <div style={{ fontWeight: 500 }}>{d.name}</div>
                  <div className="t-small flex items-center gap-2">
                    <span className="dot" data-state={d.online ? "live" : undefined} /> {d.online ? "Connected" : "Paired"}
                  </div>
                </div>
                <button className="btn btn-danger btn-sm" onClick={() => void Api.forgetDevice(d.id)}>
                  Forget
                </button>
              </div>
            ))}
          </div>
        )}
      </Group>

      <Group title="Connection">
        <p className="t-small">Phones reach this PC at</p>
        {pairing?.addresses.length ? (
          <select
            className="field w-full"
            value={pairing.address ?? ""}
            onChange={(e) => void Api.pairing(e.target.value).then(setPairing)}
            aria-label="Network the phone uses"
          >
            {pairing.addresses.map((a) => (
              <option key={a.address} value={a.address}>
                {a.address} — {a.interfaceName}
                {a.virtual ? " (virtual)" : ""}
              </option>
            ))}
          </select>
        ) : (
          <p className="t-body">This PC isn't on a network right now.</p>
        )}
        <p className="t-small">If the phone can't connect, allow SwiftDrop (Node.js) through Windows Firewall on private networks.</p>
      </Group>

      <Group title="Privacy">
        <div className="flex gap-3">
          <Lock size={18} strokeWidth={1.5} style={{ color: "var(--accent)", flex: "none", marginTop: 3 }} />
          <p className="t-body">
            Private by default. Files travel straight from one device to the other over your own network. Nothing is uploaded, and new devices only connect after you allow them here.
          </p>
        </div>
      </Group>
    </Sheet>
  );
}

export function GuestSettings({ onClose, onForget }: { onClose: () => void; onForget: () => void }) {
  const folder = useApp((s) => s.folderName);
  return (
    <Sheet title="Settings" onClose={onClose}>
      <Group title="Connected to">
        <div className="flex items-center gap-3">
          <Monitor size={18} strokeWidth={1.5} style={{ color: "var(--text-3)" }} />
          <div>
            <div style={{ fontWeight: 500 }}>Your PC</div>
            <div className="t-small">{folder ? `Saves into “${folder}”` : "Saves into the folder chosen on the PC"}</div>
          </div>
        </div>
        <button
          className="btn btn-danger btn-sm self-start"
          onClick={() => {
            setToken(null);
            onForget();
          }}
        >
          Disconnect this {deviceLabel() === "This device" ? "device" : deviceLabel()}
        </button>
      </Group>
      <Group title="Privacy">
        <p className="t-body">Your files move over your local Wi-Fi only. Nothing is uploaded to the internet.</p>
      </Group>
    </Sheet>
  );
}
