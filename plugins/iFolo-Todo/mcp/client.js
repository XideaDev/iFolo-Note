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
exports.MCPClient = void 0;
const readline = __importStar(require("node:readline"));
class MCPClient {
    connection;
    nextId = 1;
    pendingRequests = new Map();
    rl = null;
    initialized = false;
    constructor(connection) {
        this.connection = connection;
    }
    async init() {
        if (this.initialized)
            return true;
        const started = this.connection.start();
        if (!started)
            return false;
        const child = this.connection.getChild();
        if (!child || !child.stdout || !child.stdin)
            return false;
        this.rl = readline.createInterface({
            input: child.stdout,
            terminal: false
        });
        this.rl.on("line", (line) => {
            this.handleIncomingLine(line);
        });
        try {
            const initResp = await this.request("initialize", {
                protocolVersion: "2024-11-05",
                capabilities: {},
                clientInfo: { name: "pi-desktop-plugin-ifolo-todo", version: "1.0.0" }
            });
            console.log(`[iFoloTodo] Connected to ${initResp?.serverInfo?.name} v${initResp?.serverInfo?.version}`);
            this.initialized = true;
            return true;
        }
        catch (e) {
            console.error("[iFoloTodo] MCP initialize handshake failed:", e);
            return false;
        }
    }
    handleIncomingLine(line) {
        const trimmed = line.trim();
        if (!trimmed)
            return;
        try {
            const resp = JSON.parse(trimmed);
            if (resp.id !== null && resp.id !== undefined) {
                const pending = this.pendingRequests.get(resp.id);
                if (pending) {
                    clearTimeout(pending.timer);
                    this.pendingRequests.delete(resp.id);
                    if (resp.error) {
                        pending.reject(new Error(`[MCP ${resp.error.code}] ${resp.error.message}`));
                    }
                    else {
                        pending.resolve(resp.result);
                    }
                }
            }
        }
        catch {
            console.debug("[iFoloTodo] Ignored non-json stdout output:", trimmed);
        }
    }
    request(method, params, timeoutMs = 8000) {
        return new Promise((resolve, reject) => {
            const child = this.connection.getChild();
            if (!child || !child.stdin || !this.connection.isRunning()) {
                return reject(new Error("iFolo MCP subprocess is not running"));
            }
            const id = this.nextId++;
            const req = {
                jsonrpc: "2.0",
                id,
                method,
                params
            };
            const timer = setTimeout(() => {
                this.pendingRequests.delete(id);
                reject(new Error(`MCP request timeout (${method})`));
            }, timeoutMs);
            this.pendingRequests.set(id, {
                resolve: (val) => resolve(val),
                reject,
                timer
            });
            const payload = JSON.stringify(req) + "\n";
            child.stdin.write(payload, "utf-8");
        });
    }
    async callTool(name, args = {}) {
        const res = await this.request("tools/call", {
            name,
            arguments: args
        });
        if (res?.isError) {
            const msg = res.content?.[0]?.text || "Unknown tool call error";
            throw new Error(msg);
        }
        const rawText = res.content?.[0]?.text ?? "";
        try {
            return JSON.parse(rawText);
        }
        catch {
            return rawText;
        }
    }
    // --- 业务高层封装 ---
    async listNotes(limit = 60) {
        return this.callTool("ifolo_list_notes", { limit });
    }
    async readNote(noteId) {
        const raw = await this.callTool("ifolo_read_note", { note_id: noteId });
        const isLocked = typeof raw === "string" && raw.includes("<!-- IFOLO_LOCKED_NOTE -->");
        return { content: raw, isLocked };
    }
    async searchNotes(query, limit = 20) {
        return this.callTool("ifolo_search_notes", { query, limit });
    }
    async createNote(content, title, isPinned = false) {
        return this.callTool("ifolo_create_note", { content, title, is_pinned: isPinned });
    }
    async appendNote(noteId, contentToAppend) {
        return this.callTool("ifolo_append_note", {
            note_id: noteId,
            content_to_append: contentToAppend
        });
    }
    rejectAllPending(err) {
        for (const [id, req] of this.pendingRequests.entries()) {
            clearTimeout(req.timer);
            req.reject(err);
        }
        this.pendingRequests.clear();
    }
    destroy() {
        if (this.rl) {
            this.rl.close();
            this.rl = null;
        }
        this.rejectAllPending(new Error("Client destroyed"));
        this.connection.stop();
        this.initialized = false;
    }
}
exports.MCPClient = MCPClient;
