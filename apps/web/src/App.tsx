import { Lock } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { BenchPanel } from "./components/BenchPanel.tsx";
import { ConflictDialog } from "./components/ConflictDialog.tsx";
import { HostScreen } from "./components/HostScreen.tsx";
import { JoinScreen } from "./components/JoinScreen.tsx";
import { PhoneScreen } from "./components/PhoneScreen.tsx";
import { GuestSettings, HostSettings } from "./components/Settings.tsx";
import { Api, getToken, setToken } from "./lib/api.ts";
import { connectEvents, disconnectEvents } from "./lib/socket.ts";
import { app, useApp } from "./lib/store.ts";
import { Logo } from "./ui/Logo.tsx";

/** Pairing token from the QR (`#p=`): read once, then scrubbed from the address bar. */
function takePairToken(): string | null {
  const m = /[#&]p=([A-Za-z0-9_-]{8,64})/.exec(location.hash);
  if (!m) return null;
  history.replaceState(null, "", location.pathname + location.search);
  return m[1]!;
}
const initialPairToken = takePairToken();

export function App() {
  const phase = useApp((s) => s.phase);
  const role = useApp((s) => s.role);
  const conn = useApp((s) => s.conn);
  const devices = useApp((s) => s.devices);
  const notice = useApp((s) => s.notice);
  const [reason, setReason] = useState<string | null>(null);
  const [settings, setSettings] = useState(false);
  const [bench] = useState(() => location.hash === "#/bench");
  const [pairToken, setPairToken] = useState(initialPairToken);

  // A QR scanned while this page is already open only changes the hash.
  useEffect(() => {
    const onHash = () => {
      const t = takePairToken();
      if (t) {
        setToken(null);
        setPairToken(t);
        app.set({ role: null, phase: "join" });
      }
    };
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const boot = useCallback(async () => {
    try {
      const info = await Api.info();
      if (info.role === "host") {
        app.set({ role: "host", phase: "ready" });
        void Api.settings()
          .then((s) => app.set({ destination: s.destination }))
          .catch(() => undefined);
      } else if (info.role === "guest") {
        app.set({ role: "guest", phase: "ready", folderName: info.folderName });
      } else {
        app.set({ role: null, phase: "join" });
      }
    } catch (e) {
      if ((e as { status?: number }).status === 401) {
        setToken(null);
        setReason("This phone isn't paired anymore. Scan the code on your PC again.");
      } else {
        setReason("Can't reach your PC. Is SwiftDrop running there, and are you on the same Wi-Fi?");
      }
      app.set({ role: null, phase: "join" });
    }
  }, []);

  useEffect(() => {
    // A fresh QR scan always wins over an older pairing on this phone.
    if (initialPairToken && getToken()) setToken(null);
    void boot();
  }, [boot]);

  useEffect(() => {
    if (phase !== "ready") return;
    connectEvents({
      onUnauthorized: () => {
        setToken(null);
        disconnectEvents();
        setReason("Your PC removed this phone. Scan its code to connect again.");
        app.set({ role: null, phase: "join" });
      },
    });
    return () => disconnectEvents();
  }, [phase]);

  const online = devices.filter((d) => d.online).length;
  const live = conn === "online" && (role !== "host" || online > 0);
  const status = conn !== "online" && phase === "ready" ? "Reconnecting" : live ? "Connected" : "Local · Private";

  return (
    <div className={`min-h-dvh flex flex-col ${role === "guest" && phase === "ready" && !bench ? "has-dock" : ""}`}>
      <header className="topbar">
        <span className="wordmark">
          <Logo />
          SwiftDrop
        </span>
        <nav className="flex items-center gap-1" aria-label="Main">
          {phase === "ready" && (
            <>
              <button className="navlink hidden sm:inline-flex" onClick={() => document.getElementById("transfers")?.scrollIntoView({ behavior: "smooth", block: "start" })}>
                Transfers
              </button>
              <button className="navlink" onClick={() => setSettings(true)}>
                Settings
              </button>
            </>
          )}
          <span className="pill ml-2" role="status" title="Files never leave your local network">
            <span className="dot" data-state={conn !== "online" && phase === "ready" ? "warn" : live ? "live" : undefined} />
            {status}
          </span>
        </nav>
      </header>

      <main className="w-full max-w-[var(--content)] mx-auto px-[var(--gutter)] grow flex flex-col">
        {bench && phase === "ready" ? (
          <BenchPanel />
        ) : phase === "boot" ? (
          <div className="grow" aria-busy="true" />
        ) : phase === "join" ? (
          <JoinScreen key={pairToken ?? "code"} pairToken={pairToken} reason={reason} onPaired={() => void boot()} />
        ) : role === "host" ? (
          <HostScreen />
        ) : (
          <PhoneScreen />
        )}
      </main>

      {role !== "guest" && (
        <footer className="w-full max-w-[var(--content)] mx-auto px-[var(--gutter)] pt-24 pb-10 flex flex-wrap items-center justify-between gap-4">
          <p className="t-small flex items-center gap-2">
            <Lock size={14} strokeWidth={1.75} style={{ color: "var(--accent)" }} />
            Private by default. Your files stay on your local network.
          </p>
          <p className="t-micro">No cloud upload · No account</p>
        </footer>
      )}

      <ConflictDialog />
      {settings && role === "host" && <HostSettings onClose={() => setSettings(false)} />}
      {settings && role === "guest" && (
        <GuestSettings
          onClose={() => setSettings(false)}
          onForget={() => {
            setSettings(false);
            disconnectEvents();
            setReason(null);
            app.set({ role: null, phase: "join" });
          }}
        />
      )}
      {notice && (
        <div key={notice.text} className="toast" role={notice.tone === "error" ? "alert" : "status"}>
          {notice.tone === "error" && <span className="dot" data-state="warn" />}
          {notice.text}
        </div>
      )}
    </div>
  );
}
