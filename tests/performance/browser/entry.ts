// Bundled into the browser benchmark page: the real engine, nothing else.
import { createBlockHasher } from "@swiftdrop/crypto";
import { DESKTOP_CONTROLLER, HttpTransport, MOBILE_CONTROLLER, TransferJob } from "@swiftdrop/transfer-engine";

(globalThis as Record<string, unknown>).sd = { createBlockHasher, DESKTOP_CONTROLLER, MOBILE_CONTROLLER, HttpTransport, TransferJob };
