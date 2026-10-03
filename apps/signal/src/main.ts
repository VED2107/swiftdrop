import { createSignalServer } from "./server.ts";

const port = Number(process.env.SWIFTDROP_SIGNAL_PORT ?? 8790);
const host = process.env.SWIFTDROP_SIGNAL_HOST ?? "0.0.0.0";
createSignalServer().listen(port, host, () => console.log(`swiftdrop signal listening on http://${host}:${port} (SDP relay only)`));
