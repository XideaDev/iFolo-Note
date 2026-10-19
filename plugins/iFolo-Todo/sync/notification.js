"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.IFoloDataWatcher = void 0;
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const os = __importStar(require("node:os"));
class IFoloDataWatcher {
    watcher = null;
    debounceTimer = null;
    callbacks = new Set();
    revision = 0;
    start() {
        const dataDir = path.join(os.homedir(), "Library/Application Support/iFolo");
        if (!fs.existsSync(dataDir)) {
            console.warn("[iFoloWatcher] iFolo data directory does not exist yet:", dataDir);
            return;
        }
        try {
            this.watcher = fs.watch(dataDir, { recursive: true }, (eventType, filename) => {
                if (!filename)
                    return;
                if (filename.includes(".tmp") || filename.includes("mcp-audit.log"))
                    return;
                this.emitChange();
            });
            this.watcher.on("error", (err) => {
                console.warn("[iFoloWatcher] FSWatcher encountered error:", err);
                this.stop();
            });
            console.log("[iFoloWatcher] Started watching iFolo data directory for real-time sync.");
        }
        catch (e) {
            console.error("[iFoloWatcher] Failed to start data watcher:", e);
        }
    }
    onChange(cb) {
        this.callbacks.add(cb);
        return () => this.callbacks.delete(cb);
    }
    emitChange() {
        if (this.debounceTimer) {
            clearTimeout(this.debounceTimer);
        }
        this.debounceTimer = setTimeout(() => {
            this.revision += 1;
            for (const cb of this.callbacks) {
                try {
                    cb();
                }
                catch (err) {
                    console.error("[iFoloWatcher] Callback execution error:", err);
                }
            }
        }, 200);
    }
    getRevision() {
        return this.revision;
    }
    stop() {
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
exports.IFoloDataWatcher = IFoloDataWatcher;
