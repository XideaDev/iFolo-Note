import { spawn, ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export interface ConnectionOptions {
  customAppPath?: string;
  onCrash?: (error: Error) => void;
  onOutputLine?: (line: string) => void;
}

export class IFoloConnection {
  private child: ChildProcess | null = null;
  private options: ConnectionOptions;
  private isTerminated = false;

  constructor(options: ConnectionOptions = {}) {
    this.options = options;
  }

  public resolveBinaryPath(): string | null {
    if (this.options.customAppPath && fs.existsSync(this.options.customAppPath)) {
      return this.options.customAppPath;
    }

    const candidatePaths = [
      "/Applications/iFolo.app/Contents/MacOS/iFolo",
      path.join(os.homedir(), "Applications/iFolo.app/Contents/MacOS/iFolo"),
      path.resolve(process.cwd(), "apps/macos/build/iFolo.app/Contents/MacOS/iFolo")
    ];

    for (const p of candidatePaths) {
      if (fs.existsSync(p)) {
        try {
          fs.accessSync(p, fs.constants.X_OK);
          return p;
        } catch {
          // not executable, continue
        }
      }
    }

    return null;
  }

  public isRunning(): boolean {
    return this.child !== null && !this.child.killed && this.child.exitCode === null;
  }

  public start(): boolean {
    if (this.isRunning()) {
      return true;
    }
    this.isTerminated = false;

    const binPath = this.resolveBinaryPath();
    if (!binPath) {
      console.warn("[iFoloTodo] iFolo binary not found in standard system locations.");
      return false;
    }

    try {
      this.child = spawn(binPath, ["--mcp"], {
        stdio: ["pipe", "pipe", "pipe"],
        env: {
          ...process.env,
          IFOLO_MCP_CLIENT: "pi-desktop-plugin-ifolo-todo"
        }
      });

      this.child.on("error", (err: Error) => {
        console.error("[iFoloTodo] Subprocess spawn error:", err);
        if (this.options.onCrash) {
          this.options.onCrash(err);
        }
      });

      this.child.on("exit", (code: number | null, signal: string | null) => {
        console.log(`[iFoloTodo] iFolo MCP subprocess exited with code ${code}, signal: ${signal}`);
        this.child = null;
        if (!this.isTerminated && this.options.onCrash) {
          this.options.onCrash(new Error(`Process exited unexpectedly with code ${code}`));
        }
      });

      this.child.stderr?.on("data", (data: Buffer) => {
        const text = data.toString().trim();
        if (text) {
          console.debug(`[iFoloTodo MCP stderr] ${text}`);
        }
      });

      // 注册宿主退出安全守护，防止孤儿进程
      process.once("exit", () => {
        this.stop();
      });

      return true;
    } catch (e) {
      console.error("[iFoloTodo] Failed to spawn iFolo MCP server:", e);
      return false;
    }
  }

  public getChild(): ChildProcess | null {
    return this.child;
  }

  public stop(): void {
    this.isTerminated = true;
    if (this.child) {
      try {
        this.child.stdin?.end();
        this.child.kill("SIGTERM");
      } catch {
        // ignore
      }
      this.child = null;
    }
  }
}
