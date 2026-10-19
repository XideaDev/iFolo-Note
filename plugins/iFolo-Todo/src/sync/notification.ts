import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export type DataChangeCallback = () => void;

export class IFoloDataWatcher {
  private watcher: fs.FSWatcher | null = null;
  private debounceTimer: NodeJS.Timeout | null = null;
  private callbacks: Set<DataChangeCallback> = new Set();
  private revision = 0;

  public start(): void {
    const dataDir = path.join(os.homedir(), "Library/Application Support/iFolo");
    if (!fs.existsSync(dataDir)) {
      console.warn("[iFoloWatcher] iFolo data directory does not exist yet:", dataDir);
      return;
    }

    try {
      this.watcher = fs.watch(dataDir, { recursive: true }, (eventType, filename) => {
        if (!filename) return;
        if (filename.includes(".tmp") || filename.includes("mcp-audit.log")) return;

        this.emitChange();
      });

      this.watcher.on("error", (err) => {
        console.warn("[iFoloWatcher] FSWatcher encountered error:", err);
        this.stop();
      });
      console.log("[iFoloWatcher] Started watching iFolo data directory for real-time sync.");
    } catch (e) {
      console.error("[iFoloWatcher] Failed to start data watcher:", e);
    }
  }

  public onChange(cb: DataChangeCallback): () => void {
    this.callbacks.add(cb);
    return () => this.callbacks.delete(cb);
  }

  private emitChange(): void {
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.revision += 1;
      for (const cb of this.callbacks) {
        try {
          cb();
        } catch (err) {
          console.error("[iFoloWatcher] Callback execution error:", err);
        }
      }
    }, 200);
  }

  public getRevision(): number {
    return this.revision;
  }

  public stop(): void {
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
    }
    if (this.debounceTimer) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = null;
    }
    this.callbacks.clear();
  }
}
