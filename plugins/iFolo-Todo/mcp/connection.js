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
exports.IFoloConnection = void 0;
const node_child_process_1 = require("node:child_process");
const fs = __importStar(require("node:fs"));
const path = __importStar(require("node:path"));
const os = __importStar(require("node:os"));
class IFoloConnection {
    child = null;
    options;
    isTerminated = false;
    constructor(options = {}) {
        this.options = options;
    }
    resolveBinaryPath() {
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
                }
                catch {
                    // not executable, continue
                }
            }
        }
        return null;
    }
    isRunning() {
        return this.child !== null && !this.child.killed && this.child.exitCode === null;
    }
    start() {
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
            this.child = (0, node_child_process_1.spawn)(binPath, ["--mcp"], {
                stdio: ["pipe", "pipe", "pipe"],
                env: {
                    ...process.env,
                    IFOLO_MCP_CLIENT: "pi-desktop-plugin-ifolo-todo"
                }
            });
            this.child.on("error", (err) => {
                console.error("[iFoloTodo] Subprocess spawn error:", err);
                if (this.options.onCrash) {
                    this.options.onCrash(err);
                }
            });
            this.child.on("exit", (code, signal) => {
                console.log(`[iFoloTodo] iFolo MCP subprocess exited with code ${code}, signal: ${signal}`);
                this.child = null;
                if (!this.isTerminated && this.options.onCrash) {
                    this.options.onCrash(new Error(`Process exited unexpectedly with code ${code}`));
                }
            });
            this.child.stderr?.on("data", (data) => {
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
        }
        catch (e) {
            console.error("[iFoloTodo] Failed to spawn iFolo MCP server:", e);
            return false;
        }
    }
    getChild() {
        return this.child;
    }
    stop() {
        this.isTerminated = true;
        if (this.child) {
            try {
                this.child.stdin?.end();
                this.child.kill("SIGTERM");
            }
            catch {
                // ignore
            }
            this.child = null;
        }
    }
}
exports.IFoloConnection = IFoloConnection;
