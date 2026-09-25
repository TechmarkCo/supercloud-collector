import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { renameSync, unlinkSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import net from "node:net";

export const VERSION = "1.2.0";
export const MASTER = "https://supercloud.techmarkcompany.com";
export const DEFAULT_HUB = `${MASTER}/collector/v1`;

export function cmpVer(a, b) {
  const pa = String(a || "0").split(".").map((n) => parseInt(n, 10) || 0);
  const pb = String(b || "0").split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

export function originFromHub(hubUrl) {
  try {
    const u = new URL(hubUrl);
    return `${u.protocol}//${u.host}`;
  } catch {
    return MASTER;
  }
}

export function tcpProbe(ip, port, timeoutMs = 2500) {
  return new Promise((resolve) => {
    if (!ip || !port) return resolve({ ok: false, err: "no target" });
    const sock = net.connect({ host: ip, port: Number(port) });
    const t = setTimeout(() => {
      sock.destroy();
      resolve({ ok: false, err: "timeout" });
    }, timeoutMs);
    sock.on("connect", () => {
      clearTimeout(t);
      sock.end();
      resolve({ ok: true });
    });
    sock.on("error", (e) => {
      clearTimeout(t);
      resolve({ ok: false, err: e.message });
    });
  });
}

export async function maybeUpgrade(cfg, hint, selfUrl) {
  if (cfg.autoUpgrade === false) return false;
  const origin = originFromHub(cfg.hubUrl || DEFAULT_HUB);
  let info = hint && (hint.version || hint.agentVersion) ? hint : null;
  if (!info) {
    const res = await fetch(`${(cfg.hubUrl || DEFAULT_HUB).replace(/\/+$/, "")}/version`);
    info = await res.json().catch(() => ({}));
  }
  const next = info.version || info.agentVersion;
  if (!next || cmpVer(next, VERSION) <= 0) return false;
  const url = info.agentUrl || `${origin}/collector/bastion-collector.mjs`;
  console.log(`upgrade ${VERSION} -> ${next} from ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const sha = createHash("sha256").update(buf).digest("hex");
  if (info.sha256 && info.sha256 !== sha) throw new Error("upgrade sha256 mismatch");
  const self = selfUrl || fileURLToPath(import.meta.url);
  const tmp = `${self}.new`;
  writeFileSync(tmp, buf, { mode: 0o755 });
  try {
    renameSync(tmp, self);
  } catch {
    writeFileSync(self, buf, { mode: 0o755 });
    try {
      unlinkSync(tmp);
    } catch {
      /* ignore */
    }
  }
  const child = spawn(process.execPath, [self, ...process.argv.slice(2)], {
    detached: true,
    stdio: "inherit",
  });
  child.unref();
  process.exit(0);
}
