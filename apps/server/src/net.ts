import { networkInterfaces } from "node:os";

export interface LanAddress {
  address: string;
  interfaceName: string;
  /** VPN / VM / container adapters the phone can't reach. */
  virtual: boolean;
}

const VIRTUAL = /vEthernet|VirtualBox|VMware|Hyper-V|WSL|Loopback|Tailscale|ZeroTier|docker|vbox|utun|Bluetooth|Npcap|TAP|Wintun|Hamachi/i;

/**
 * IPv4 addresses the phone might reach us on, best first.
 * Real Wi-Fi/Ethernet adapters beat virtual ones; private ranges beat everything else.
 * An iPhone hotspot hands out 172.20.10.x — that's a normal private address here.
 */
export function lanAddresses(): LanAddress[] {
  const out: LanAddress[] = [];
  for (const [name, list] of Object.entries(networkInterfaces())) {
    for (const info of list ?? []) {
      if (info.family !== "IPv4" || info.internal) continue;
      if (info.address.startsWith("169.254.")) continue; // link-local: no DHCP, unreachable
      out.push({ address: info.address, interfaceName: name, virtual: VIRTUAL.test(name) || isVirtualBoxDefault(info.address) });
    }
  }
  return out.sort((a, b) => score(b) - score(a));
}

function isVirtualBoxDefault(ip: string) {
  return ip === "192.168.56.1";
}

function score(a: LanAddress): number {
  let s = 0;
  if (!a.virtual) s += 100;
  if (/wi-?fi|wlan|wireless/i.test(a.interfaceName)) s += 20;
  if (/ethernet|^en|^eth/i.test(a.interfaceName)) s += 10;
  if (a.address.startsWith("192.168.") || a.address.startsWith("10.") || /^172\.(1[6-9]|2\d|3[01])\./.test(a.address)) s += 5;
  return s;
}

/** Every address that belongs to this machine, including loopback. */
export function localAddressSet(): Set<string> {
  const set = new Set<string>(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
  for (const list of Object.values(networkInterfaces())) {
    for (const info of list ?? []) {
      set.add(info.address);
      if (info.family === "IPv4") set.add(`::ffff:${info.address}`);
    }
  }
  return set;
}
