#!/usr/bin/env node
/**
 * Bastion site collector — run this on a machine at the site that can reach
 * FortiGate, FortiAnalyzer, switches, and domain endpoints.
 *
 *   node bastion-collector.mjs
 *
 * Reads collector.config.json next to this file (or --config path).
 * Inventory YAML holds IPs / usernames / passwords. chmod 600 both files.
 * Outbound HTTPS to the Bastion hub only — nothing inbound required.
 */
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VERSION = "1.1.0";

function arg(name, fallback = "") {
  const i = process.argv.indexOf(`--${name}`);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

function loadJson(file, fallback) {
  if (!existsSync(file)) return fallback;
  return JSON.parse(readFileSync(file, "utf8"));
}

function parseInventory(text) {
  const devices = [];
  let cur = null;
  let section = "";
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/\t/g, "  ");
    const sec = line.match(/^([a-z0-9_]+):\s*$/i);
    if (sec && !line.startsWith(" ")) {
      section = sec[1];
      if (section === "fortianalyzer") {
        cur = { kind: "faz" };
        devices.push(cur);
      } else {
        cur = null;
      }
      continue;
    }
    const item = line.match(/^\s+-\s+id:\s*(.+)$/);
    if (item) {
      const kind =
        section === "fortigate" ? "fg" : section === "switches" ? "sw" : section === "honeypots" ? "hp" : section;
      cur = { kind, id: strip(item[1]) };
      devices.push(cur);
      continue;
    }
    const kv = line.match(/^\s{2,}([a-z_]+):\s*(.*)$/i);
    if (kv && cur) cur[kv[1]] = strip(kv[2]);
  }
  const faz = devices.find((d) => d.kind === "faz");
  if (faz && !faz.id) faz.id = "faz";
  return devices;
}

function strip(v) {
  const s = String(v ?? "").trim();
  if (s === '""') return "";
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    try {
      return JSON.parse(s);
    } catch {
      return s.slice(1, -1);
    }
  }
  return s;
}

function run(cmd, args, { input, timeoutMs = 20000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const t = setTimeout(() => {
      child.kill("SIGKILL");
      resolve({ ok: false, out, err: err || "timeout" });
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      out += d.toString();
    });
    child.stderr.on("data", (d) => {
      err += d.toString();
    });
    child.on("close", (code) => {
      clearTimeout(t);
      resolve({ ok: code === 0, out, err });
    });
    child.on("error", (e) => {
      clearTimeout(t);
      resolve({ ok: false, out, err: e.message });
    });
    if (input) child.stdin.end(input);
    else child.stdin.end();
  });
}

async function sshExec({ ip, username, password, commands }) {
  if (!ip) return { ok: false, out: "", err: "no ip" };
  const script = Array.isArray(commands) ? commands.join("\n") : String(commands);
  if (process.env.SSH_ASKPASS_REQUIRE) {
    /* keep */
  }
  const sshpass = existsSync("/usr/bin/sshpass") ? "/usr/bin/sshpass" : "sshpass";
  const args = [
    "-p",
    password || "",
    "ssh",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "ConnectTimeout=8",
    "-o",
    "PreferredAuthentications=password",
    `${username}@${ip}`,
  ];
  let res = await run(sshpass, args, { input: script + "\n" });
  if (!res.ok && /sshpass|ENOENT|not found/i.test(res.err)) {
    res = await run(
      "ssh",
      [
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "ConnectTimeout=8",
        `${username}@${ip}`,
      ],
      { input: script + "\n" },
    );
  }
  return res;
}

async function fgRestStatus(ip, username, password) {
  if (!ip) return { ok: false };
  try {
    const login = await fetch(`https://${ip}/logincheck`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: `username=${encodeURIComponent(username)}&secretkey=${encodeURIComponent(password)}&ajax=1`,
    });
    const cookie = login.headers.get("set-cookie") ?? "";
    const status = await fetch(`https://${ip}/api/v2/monitor/system/status`, {
      headers: { cookie },
    });
    if (!status.ok) return { ok: false, err: `http ${status.status}` };
    const data = await status.json();
    const results = data.results ?? data;
    return {
      ok: true,
      model: results.model_name || results.hostname,
      version: results.version,
    };
  } catch (e) {
    return { ok: false, err: e.message };
  }
}

async function isolateFortigate(dev, ip) {
  const cmd = [
    `diagnose user quarantine add src4 ${ip} 86400`,
    `config firewall address`,
    `edit BASTION-${ip.replace(/\./g, "-")}`,
    `set subnet ${ip} 255.255.255.255`,
    `next`,
    `end`,
  ];
  return sshExec({ ...dev, commands: cmd });
}

async function shutdownPort(dev, portName) {
  if (!portName) return { ok: false, err: "no port" };
  const family = (dev.family || "").toLowerCase();
  const vendor = (dev.vendor || "").toLowerCase();
  if (family === "mikrotik-swos" || family === "unifi") {
    return { ok: false, err: `${dev.hostname || dev.ip} is ${family}; access-port SSH shutdown is not used on this family` };
  }
  const cmds =
    family === "cisco-sb" || vendor.includes("cisco")
      ? [`configure`, `interface ${portName}`, `shutdown`, `exit`, `exit`]
      : vendor.includes("hp") || vendor.includes("aruba")
        ? [`configure`, `interface ${portName}`, `disable`, `exit`, `save`]
        : [`configure`, `interface ${portName}`, `shutdown`, `exit`, `exit`];
  return sshExec({ ip: dev.ip, username: dev.username, password: dev.password, commands: cmds });
}

function normMac(mac) {
  const hex = String(mac || "").toLowerCase().replace(/[^0-9a-f]/g, "");
  if (hex.length !== 12) return "";
  return hex.match(/.{2}/g).join(":");
}

function isUplink(port) {
  const p = String(port || "").toLowerCase();
  return p.startsWith("te") || p.startsWith("po") || p.includes("trunk") || p.includes("lag") || p.includes("bond");
}

function portFromTable(output, mac) {
  const want = normMac(mac);
  if (!want) return "";
  const compact = want.replace(/:/g, "");
  for (const line of String(output || "").split(/\r?\n/)) {
    const low = line.toLowerCase();
    if (!low.includes(want) && !low.includes(compact)) continue;
    const hit = line.match(/\b((?:GigabitEthernet|FastEthernet|TenGigabitEthernet|gi|fa|te)\s*\d[\w/.]*)\b/i);
    if (hit) return hit[1].replace(/\s+/g, "");
  }
  return "";
}

async function macFromFortigate(fg, ip) {
  if (!fg?.ip || !ip) return "";
  const r = await sshExec({
    ip: fg.ip,
    username: fg.username,
    password: fg.password,
    commands: "diagnose ip arp list",
  });
  const line = r.out.split(/\r?\n/).find((l) => l.includes(ip));
  const mac = line?.match(/[0-9a-f]{2}(?::[0-9a-f]{2}){5}/i);
  return mac ? normMac(mac[0]) : "";
}

async function lastResortPortShutdown(inventory, { ip, mac, hostname }) {
  const fg = inventory.find((d) => d.kind === "fg");
  const resolved = normMac(mac) || (await macFromFortigate(fg, ip));
  if (!resolved) {
    return `switch last resort held: no MAC for ${ip || hostname}. No port was shut.`;
  }
  const switches = inventory.filter(
    (d) => d.kind === "sw" && d.ip && d.username && d.password && d.family !== "mikrotik-swos" && d.family !== "unifi",
  );
  if (!switches.length) return "switch last resort held: no SSH-capable switch with a password";
  for (const sw of switches) {
    const table = await sshExec({
      ip: sw.ip,
      username: sw.username,
      password: sw.password,
      commands: "show mac address-table",
    });
    const port = portFromTable(table.out, resolved);
    if (!port) continue;
    if (isUplink(port)) {
      return `switch last resort held: ${resolved} is on uplink ${port} of ${sw.hostname || sw.ip}`;
    }
    const shut = await shutdownPort(sw, port);
    if (!shut.ok) return `switch ${sw.hostname || sw.ip} failed to shut ${port}: ${shut.err || shut.out || "ssh failed"}`;
    return `last resort: ${sw.hostname || sw.ip} shut ${port} for ${hostname || ip} mac ${resolved}`;
  }
  return `switch last resort held: MAC ${resolved} was not on an access port. No port was shut.`;
}

async function winrmIsolate(hostname) {
  if (!hostname) return { ok: false, err: "no host" };
  const ps = `Invoke-Command -ComputerName ${hostname} -ScriptBlock { Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual } | Disable-NetAdapter -Confirm:$false; Stop-Computer -Force -ErrorAction SilentlyContinue }`;
  return run("powershell.exe", ["-NoProfile", "-Command", ps]);
}

function startHoneypot(cfg, onTrip) {
  const services = cfg.services ?? [];
  const bind = cfg.bind || "0.0.0.0";
  const servers = [];
  for (const svc of services) {
    const server = net.createServer((socket) => {
      const src = socket.remoteAddress?.replace(/^::ffff:/, "") || "unknown";
      onTrip({
        service: svc.name,
        port: svc.port,
        src,
      });
      if (svc.name === "SSH") {
        socket.write(`${svc.banner || "SSH-2.0-OpenSSH_8.4"}\r\n`);
      } else if (svc.name === "HTTP") {
        socket.write(
          "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"NAS\"\r\nContent-Length: 0\r\n\r\n",
        );
      }
      setTimeout(() => socket.destroy(), 1200);
    });
    server.on("error", (e) => {
      console.error(`honeypot ${svc.name}/${svc.port}: ${e.message}`);
    });
    server.listen(svc.port, bind, () => {
      console.log(`honeypot ${svc.name} on ${bind}:${svc.port}`);
    });
    servers.push(server);
  }
  return servers;
}

async function hubCall(cfg, pathname, { method = "GET", body } = {}) {
  const url = cfg.hubUrl.replace(/\/+$/, "") + pathname;
  const res = await fetch(url, {
    method,
    headers: {
      authorization: `Bearer ${cfg.token}`,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `hub ${res.status}`);
  return data;
}

async function runJob(job, inventory) {
  const fg = inventory.find((d) => d.kind === "fg");
  const p = job.payload || {};
  if (job.type === "isolate_ip" || job.type === "ban_src") {
    const r = await isolateFortigate(
      { ip: fg?.ip, username: fg?.username, password: fg?.password },
      p.ip,
    );
    return r.ok ? `quarantine ${p.ip}` : r.err || r.out || "fortigate failed";
  }
  if (job.type === "shutdown_port") {
    if (p.port || p.portName) {
      const sw =
        inventory.find((d) => d.kind === "sw" && (d.id === p.switchId || d.ip === p.switchIp)) ||
        inventory.find((d) => d.kind === "sw" && d.password);
      const r = await shutdownPort(
        { ...sw, ip: sw?.ip || p.switchIp, vendor: sw?.vendor, family: sw?.family, hostname: sw?.hostname },
        p.port || p.portName,
      );
      return r.ok ? `shutdown ${p.port || p.portName} on ${sw?.hostname || sw?.ip}` : r.err || r.out || "switch failed";
    }
    return lastResortPortShutdown(inventory, p);
  }
  if (job.type === "winrm_isolate") {
    const r = await winrmIsolate(p.hostname);
    return r.ok ? `winrm ${p.hostname}` : r.err || r.out || "winrm failed";
  }
  if (job.type === "release_ip") {
    return "release queued on FortiGate (manual expiry or delete quarantine)";
  }
  return `unhandled ${job.type}`;
}

async function main() {
  const configPath = path.resolve(arg("config", path.join(__dirname, "collector.config.json")));
  const cfg = loadJson(configPath, {});
  cfg.siteId = arg("site", cfg.siteId || "bkk");
  cfg.hubUrl = arg("hub", cfg.hubUrl || "");
  cfg.token = arg("token", cfg.token || process.env.BASTION_TOKEN || "");
  cfg.inventoryPath = path.resolve(
    path.dirname(configPath),
    cfg.inventoryPath || "inventory.yaml",
  );
  cfg.pollSeconds = Number(cfg.pollSeconds || 20);
  cfg.honeypot = cfg.honeypot || { enabled: true, bind: "0.0.0.0", services: [] };

  if (!cfg.hubUrl || !cfg.token) {
    console.error("Set hubUrl and token in collector.config.json");
    process.exit(1);
  }

  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

  const inventory = existsSync(cfg.inventoryPath)
    ? parseInventory(readFileSync(cfg.inventoryPath, "utf8"))
    : [];
  const fg = inventory.find((d) => d.kind === "fg");
  const faz = inventory.find((d) => d.kind === "faz");

  const pendingEvents = [];
  if (cfg.honeypot.enabled) {
    startHoneypot(cfg.honeypot, (trip) => {
      console.log(`TRIP ${trip.service} from ${trip.src}`);
      pendingEvents.push({
        kind: "honeypot",
        title: `Honeypot ${trip.service} trip`,
        severity: "high",
        src: trip.src,
        detail: `${trip.src} hit ${trip.service}/${trip.port} on collector ${cfg.siteId}`,
        payload: { service: trip.service, port: String(trip.port) },
      });
    });
  }

  async function tick() {
    const events = pendingEvents.splice(0, 20);
    let fgInfo = { ok: false, ip: fg?.ip };
    if (fg?.ip) {
      const rest = await fgRestStatus(fg.ip, fg.username || "admin", fg.password || "");
      if (rest.ok) fgInfo = { ok: true, ip: fg.ip, model: rest.model, version: rest.version };
      else {
        const ssh = await sshExec({
          ip: fg.ip,
          username: fg.username || "admin",
          password: fg.password || "",
          commands: "get system status",
        });
        fgInfo = {
          ok: ssh.ok,
          ip: fg.ip,
          model: (ssh.out.match(/Version:\s*(\S+)/) || [])[1],
        };
      }
    }
    const fazInfo = faz?.ip ? { ok: true, ip: faz.ip } : undefined;
    const data = await hubCall(cfg, "/heartbeat", {
      method: "POST",
      body: {
        siteId: cfg.siteId,
        hostname: cfg.hostname || process.env.COMPUTERNAME || process.env.HOSTNAME || "collector",
        version: VERSION,
        fg: fgInfo,
        faz: fazInfo,
        honeypot: {
          armed: Boolean(cfg.honeypot.enabled),
          services: (cfg.honeypot.services || []).map((s) => s.name),
        },
        events,
      },
    });
    const jobs = data.jobs || [];
    for (const job of jobs) {
      console.log(`job ${job.id} ${job.type}`);
      let result = "";
      let status = "done";
      try {
        result = await runJob(job, inventory);
      } catch (e) {
        status = "failed";
        result = e.message;
      }
      await hubCall(cfg, `/jobs/${job.id}/result`, {
        method: "POST",
        body: { status, result: String(result).slice(0, 2000) },
      });
    }
  }

  console.log(`Bastion collector ${VERSION} site=${cfg.siteId} hub=${cfg.hubUrl}`);
  for (;;) {
    try {
      await tick();
    } catch (e) {
      console.error("tick failed:", e.message);
    }
    await new Promise((r) => setTimeout(r, cfg.pollSeconds * 1000));
  }
}

process.on("unhandledRejection", (e) => console.error(e));
main();
