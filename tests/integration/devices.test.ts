import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { cleanup, startServer, type TestServer } from "./helpers.ts";

let s: TestServer;
beforeAll(async () => {
  s = await startServer();
});
afterAll(async () => {
  await s.stop();
  await cleanup(s);
});

const json = { "content-type": "application/json" };

async function pair(deviceName: string, installId?: string): Promise<{ token: string; returning: boolean }> {
  const { code } = (await (await s.hostFetch("/api/host/pairing")).json()) as { code: string };
  const { requestId } = (await (await fetch(`${s.base}/api/join`, { method: "POST", headers: json, body: JSON.stringify({ code, deviceName, installId }) })).json()) as { requestId: string };
  const pending = await s.app.auth.pendingJoins().find((j) => j.id === requestId);
  await s.hostFetch(`/api/host/joins/${requestId}`, { method: "POST", headers: json, body: JSON.stringify({ approve: true }) });
  const done = (await (await fetch(`${s.base}/api/join/${requestId}`)).json()) as { token: string };
  return { token: done.token, returning: Boolean(pending?.returning) };
}

const devices = async () => ((await (await s.hostFetch("/api/host/devices")).json()) as { devices: Array<{ id: string; name: string }> }).devices;
const me = async (token: string) => fetch(`${s.base}/api/info`, { headers: { authorization: `Bearer ${token}` } });

describe("paired devices", () => {
  it("re-pairing the same phone replaces its entry, keeps its name, revokes the old token", async () => {
    const install = "install_AAAAAAAAAAAAAAAA";
    const first = await pair("iPhone", install);
    expect(first.returning).toBe(false);
    const [d] = await devices();
    const renamed = await fetch(`${s.base}/api/device`, { method: "PATCH", headers: { ...json, authorization: `Bearer ${first.token}` }, body: JSON.stringify({ name: "Ved's iPhone" }) });
    expect(renamed.status).toBe(200);

    const second = await pair("iPhone", install);
    expect(second.returning).toBe(true);
    const list = await devices();
    expect(list).toHaveLength(1);
    expect(list[0]!.id).toBe(d!.id);
    expect(list[0]!.name).toBe("Ved's iPhone");
    expect((await me(first.token)).status).toBe(401);
    expect(((await (await me(second.token)).json()) as { deviceName: string }).deviceName).toBe("Ved's iPhone");
  });

  it("gives a second phone with the same model name a distinct name, and refuses duplicate renames", async () => {
    await pair("iPhone", "install_BBBBBBBBBBBBBBBB");
    await pair("iPhone", "install_CCCCCCCCCCCCCCCC");
    const names = (await devices()).map((d) => d.name).sort();
    expect(names).toEqual(["Ved's iPhone", "iPhone", "iPhone 2"]);

    const target = (await devices()).find((d) => d.name === "iPhone 2")!;
    const clash = await s.hostFetch(`/api/host/devices/${target.id}`, { method: "PATCH", headers: json, body: JSON.stringify({ name: "ved's IPHONE" }) });
    expect(clash.status).toBe(409);
    expect(((await clash.json()) as { code: string }).code).toBe("NAME_TAKEN");
    const ok = await s.hostFetch(`/api/host/devices/${target.id}`, { method: "PATCH", headers: json, body: JSON.stringify({ name: "  Kitchen‮ iPad  " }) });
    expect(((await ok.json()) as { name: string }).name).toBe("Kitchen iPad");
  });

  it("guests can't rename other devices", async () => {
    const { token } = await pair("Pixel", "install_DDDDDDDDDDDDDDDD");
    const other = (await devices()).find((d) => d.name === "Kitchen iPad")!;
    const res = await fetch(`${s.base}/api/host/devices/${other.id}`, { method: "PATCH", headers: { ...json, authorization: `Bearer ${token}` }, body: JSON.stringify({ name: "mine" }) });
    expect(res.status).toBe(403);
  });
});
