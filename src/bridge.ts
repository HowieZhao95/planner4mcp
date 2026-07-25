import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export class BridgeError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "BridgeError";
  }
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
}

const DEFAULT_TIMEOUT_MS = 60_000;

function locateBinary(): string {
  const fromEnv = process.env.PLANNER4MCP_BRIDGE;
  if (fromEnv) {
    if (!existsSync(fromEnv)) {
      throw new BridgeError(
        "bridge_missing",
        `PLANNER4MCP_BRIDGE points at '${fromEnv}' but nothing is there.`,
      );
    }
    return fromEnv;
  }
  const here = dirname(fileURLToPath(import.meta.url));
  const buildDir = resolve(here, "..", "build");
  // Prefer the executable inside the .app bundle: hosts that disclaim TCC
  // responsibility for their children make this process its own responsible
  // process, and tccd only prompts for something it can resolve to a bundle.
  const candidates = [
    resolve(buildDir, "ekbridge.app", "Contents", "MacOS", "ekbridge"),
    resolve(buildDir, "ekbridge"),
  ];
  const found = candidates.find((p) => existsSync(p));
  if (!found) {
    throw new BridgeError(
      "bridge_missing",
      `EventKit bridge not found at '${candidates[0]}'. Run: npm run build:bridge`,
    );
  }
  return found;
}

/**
 * Long-lived child process speaking newline-delimited JSON.
 * Kept warm so EKEventStore does not pay startup cost on every call.
 */
export class EventKitBridge {
  private proc: ChildProcess | null = null;
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private stdoutBuffer = "";
  private lastStderr = "";
  private readonly binaryPath: string;

  constructor(binaryPath?: string) {
    this.binaryPath = binaryPath ?? locateBinary();
  }

  private start(): ChildProcess {
    const proc = spawn(this.binaryPath, ["--serve"], {
      stdio: ["pipe", "pipe", "pipe"],
    });

    proc.stdout!.setEncoding("utf8");
    proc.stdout!.on("data", (chunk: string) => this.onStdout(chunk));

    proc.stderr!.setEncoding("utf8");
    proc.stderr!.on("data", (chunk: string) => {
      this.lastStderr = (this.lastStderr + chunk).slice(-4000);
    });

    const die = (reason: string) => {
      if (this.proc === proc) this.proc = null;
      const detail = this.lastStderr.trim();
      this.failAll(
        new BridgeError(
          "bridge_crashed",
          `EventKit bridge ${reason}.${detail ? ` stderr: ${detail}` : ""}`,
        ),
      );
    };

    proc.on("exit", (code, signal) =>
      die(`exited (code=${code}, signal=${signal})`),
    );
    proc.on("error", (err) => die(`failed to launch: ${err.message}`));

    this.proc = proc;
    return proc;
  }

  private onStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    let newline: number;
    while ((newline = this.stdoutBuffer.indexOf("\n")) !== -1) {
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      this.dispatch(line);
    }
  }

  private dispatch(line: string): void {
    let payload: any;
    try {
      payload = JSON.parse(line);
    } catch {
      return; // ignore anything that is not a framed response
    }
    const entry = this.pending.get(payload?.id);
    if (!entry) return;
    this.pending.delete(payload.id);
    clearTimeout(entry.timer);
    if (payload.ok) {
      entry.resolve(payload.result);
    } else {
      const code = payload?.error?.code ?? "unknown";
      const message = payload?.error?.message ?? "Unknown EventKit error";
      entry.reject(new BridgeError(code, message));
    }
  }

  private failAll(error: Error): void {
    for (const [, entry] of this.pending) {
      clearTimeout(entry.timer);
      entry.reject(error);
    }
    this.pending.clear();
  }

  async call<T = any>(
    method: string,
    params: Record<string, unknown> = {},
    timeoutMs = DEFAULT_TIMEOUT_MS,
  ): Promise<T> {
    const proc = this.proc ?? this.start();
    const id = this.nextId++;

    // Drop undefined so the Swift side can tell "absent" from "explicit null".
    const cleaned: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(params)) {
      if (v !== undefined) cleaned[k] = v;
    }

    return new Promise<T>((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectPromise(
          new BridgeError(
            "timeout",
            `EventKit call '${method}' timed out after ${timeoutMs}ms`,
          ),
        );
      }, timeoutMs);

      this.pending.set(id, {
        resolve: resolvePromise as (v: unknown) => void,
        reject: rejectPromise,
        timer,
      });

      proc.stdin!.write(`${JSON.stringify({ id, method, params: cleaned })}\n`);
    });
  }

  stop(): void {
    this.failAll(new BridgeError("shutdown", "Bridge shutting down"));
    this.proc?.kill();
    this.proc = null;
  }
}
