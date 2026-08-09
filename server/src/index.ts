#!/usr/bin/env node
/**
 * makit — desktop server CLI.
 *
 * Usage:
 *   makit serve [--host H] [--lan] [--port 7777] [--project P]... [--no-auth]
 *   makit pair  [--host H] [--port P]                  # prints a QR + URL
 *
 * Default host (secure by default): Tailscale IP if online, else loopback
 * only. makit does NOT expose the local network by default — on public Wi-Fi
 * that would leave the port reachable by untrusted co-tenants. Pass `--lan`
 * to opt into binding the LAN IPv4 (trusted networks only), or `--host
 * 0.0.0.0` to bind every interface. The recommended transport is Tailscale.
 * A loopback listener is added automatically when host is a specific IP,
 * so the loopback HTTP bridge and the flutter dev loop keep working.
 *
 * `makit serve` is the long-running server. `makit pair` is meant to be run
 * from a second terminal (or as a hotkey on an already-running server) to
 * mint a fresh pairing token. For M1 we co-locate both — `makit pair`
 * connects to the running server over a unix socket would be cleaner; for
 * now `makit serve` accepts a SIGUSR1 to print a new QR, and `makit pair`
 * works only if the user runs it as a one-shot _instead of_ `serve`.
 *
 * Simplest current UX: at startup, `makit serve` automatically prints one
 * QR with a fresh pair token. The user scans it; subsequent connects use
 * the persistent bearer.
 */

import { fileURLToPath } from "node:url";
import { resolve as resolvePath } from "node:path";
import { homedir } from "node:os";
import { openSync } from "node:fs";
import { spawn as childSpawn } from "node:child_process";
import { createDaemon } from "./daemon/service.js";
import { connectControlClient } from "./daemon/control-client.js";
import { controlSocketPath, pidFilePath, logFilePath, ensureMakitHome } from "./daemon/paths.js";
import { installService, uninstallService } from "./daemon/launchd.js";
import { parseArgs, runServe } from "./serve.js";

/** Build a Daemon wired to real OS primitives (spawn/kill/control socket). */
function makeDaemon() {
  return createDaemon({
    entry: fileURLToPath(import.meta.url),
    execPath: process.execPath,
    socketPath: controlSocketPath(),
    pidPath: pidFilePath(),
    logPath: logFilePath(),
    out: (line) => console.log(line),
    spawn: (cmd, args, logFd) => {
      // Forward the parent's node flags (e.g. tsx's `--require`/`--import`
      // loader, injected via execArgv, not NODE_OPTIONS) so the detached
      // daemon resolves TS-style `.js` imports the same way the CLI does.
      // Without this, plain node can't resolve imports like `./manager.js`.
      const child = childSpawn(cmd, [...process.execArgv, ...args], { detached: true, stdio: ["ignore", logFd, logFd] });
      return { pid: child.pid, unref: () => child.unref() };
    },
    openLogFd: (p) => {
      ensureMakitHome();
      return openSync(p, "w", 0o600);
    },
    kill: (pid, sig) => process.kill(pid, sig),
    isAlive: (pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    },
    connect: (sp) => connectControlClient(sp),
  });
}

async function main() {
  const cmd = process.argv[2];
  const LIFECYCLE = new Set(["start", "stop", "restart", "status", "logs", "service"]);
  const KNOWN = new Set(["serve", "pair", "qr", "devices", "ls", "sessions", "new", "send", "tail", "resume", "rm", "attach", ...LIFECYCLE]);
  if (cmd && !KNOWN.has(cmd)) {
    console.error(
      `unknown command: ${cmd}\n` +
        `usage: makit serve|start|stop|restart|status|logs|service|pair|qr|devices|ls|new|send|tail|resume|rm|attach [...]`,
    );
    process.exit(2);
  }

  // --- SPEC-02 thin-client subcommands: drive the running daemon via the
  // control socket. requireDaemon() handles "not running" uniformly. ---
  if (cmd === "qr" || cmd === "pair") {
    const { runQr } = await import("./cli/qr.js");
    // `makit pair` is an alias for `makit qr --refresh` (daemon required).
    const argv = cmd === "pair" ? ["--refresh", ...process.argv.slice(3)] : process.argv.slice(3);
    await runQr(argv);
    return;
  }

  if (cmd === "devices") {
    const { runDevices } = await import("./cli/devices.js");
    await runDevices(process.argv.slice(3));
    return;
  }

  // `ls` lists sessions over WSS — the app's own `sessions.snapshot` (SPEC-46
  // D1), so the terminal cannot drift from the phone. `sessions` is the
  // deprecated control-socket spelling, kept for one release.
  if (cmd === "ls" || cmd === "sessions") {
    if (cmd === "sessions") console.error("[makit] `makit sessions` is deprecated — use `makit ls`");
    const { runLs } = await import("./cli/ls.js");
    await runLs(process.argv.slice(3));
    return;
  }

  // `new` starts a session from the terminal: a worktree, a draft session, and
  // (with -m) the first message that promotes it (SPEC-46 D4/D15).
  if (cmd === "new") {
    const { runNew } = await import("./cli/new.js");
    await runNew(process.argv.slice(3));
    return;
  }

  // `send` posts a message to a session (SPEC-46 T14) — a thin client of
  // `send.message`.
  if (cmd === "send") {
    const { runSend } = await import("./cli/send.js");
    await runSend(process.argv.slice(3));
    return;
  }
  // `tail` replays a session's events and, with -f, keeps streaming (T14).
  if (cmd === "tail") {
    const { runTail } = await import("./cli/tail.js");
    await runTail(process.argv.slice(3));
    return;
  }
  // `resume` brings a cold, resumable session back to a live agent (T14).
  if (cmd === "resume") {
    const { runResume } = await import("./cli/resume.js");
    await runResume(process.argv.slice(3));
    return;
  }
  // `rm` ends a session: archive by default (recoverable), kill only with --kill.
  if (cmd === "rm") {
    const { runRm } = await import("./cli/rm.js");
    await runRm(process.argv.slice(3));
    return;
  }

  // `attach` is a client, not a server: connect to a running makit and drive
  // one session from the terminal. No cert/registry/manager needed here.
  if (cmd === "attach") {
    const { runAttach } = await import("./cli/attach.js");
    await runAttach(process.argv.slice(3));
    return;
  }

  // --- background service lifecycle (SPEC-01) — thin clients of the control
  // socket / process management. These do not need cert/manager. ---
  if (LIFECYCLE.has(cmd!) && cmd !== "service") {
    const daemon = makeDaemon();
    const a = parseArgs(process.argv.slice(3));
    const serveOpts = {
      host: a.host,
      port: a.port,
      projects: a.projects,
      noAuth: a.noAuth,
      advertise: a.advertise,
    };
    let code = 0;
    if (cmd === "start") code = await daemon.start(serveOpts);
    else if (cmd === "stop") code = await daemon.stop();
    else if (cmd === "restart") code = await daemon.restart(serveOpts);
    else if (cmd === "status") code = await daemon.status();
    else if (cmd === "logs") {
      const rest = process.argv.slice(3);
      const follow = rest.includes("--follow") || rest.includes("-f");
      const li = rest.indexOf("--lines");
      const lines = li >= 0 ? Number(rest[li + 1]) : undefined;
      code = await daemon.logs({ follow, lines });
    }
    process.exit(code);
  }

  if (cmd === "service") {
    const sub = process.argv[3];
    const entry = fileURLToPath(import.meta.url);
    const plistPath = resolvePath(homedir(), "Library", "LaunchAgents", "dev.makit.plist");
    if (sub === "install") {
      installService({
        label: "dev.makit",
        execPath: process.execPath,
        entry,
        logPath: logFilePath(),
        plistPath,
      });
      console.log(`[makit] launchd agent installed: ${plistPath}`);
      console.log(`[makit] it does NOT auto-start. Load it with: launchctl load ${plistPath}`);
    } else if (sub === "uninstall") {
      const removed = uninstallService({ plistPath });
      console.log(removed ? `[makit] launchd agent removed: ${plistPath}` : `[makit] no launchd agent installed`);
    } else {
      console.error("usage: makit service install|uninstall");
      process.exit(2);
    }
    return;
  }

  await runServe(parseArgs(process.argv.slice(3)));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
