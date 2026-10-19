"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.onLoad = onLoad;
exports.onUnload = onUnload;
exports.onPanelInvoke = onPanelInvoke;
exports.onCommand = onCommand;
const connection_1 = require("./mcp/connection");
const client_1 = require("./mcp/client");
const capture_1 = require("./actions/capture");
const notification_1 = require("./sync/notification");
const sessionTodoWatcher_1 = require("./sync/sessionTodoWatcher");
function getHostApi() {
    return globalThis.pi || null;
}
class IFoloTodoPlugin {
    connection;
    client;
    actions;
    watcher;
    sessionTodoWatcher;
    constructor() {
        this.connection = new connection_1.IFoloConnection({
            onCrash: (err) => {
                console.warn("[iFoloTodo] iFolo bridge crashed or exited:", err.message);
            }
        });
        this.client = new client_1.MCPClient(this.connection);
        this.actions = new capture_1.NoteActions(this.client);
        this.watcher = new notification_1.IFoloDataWatcher();
        this.sessionTodoWatcher = new sessionTodoWatcher_1.SessionTodoWatcher(this.client);
    }
    async onLoad() {
        console.log("[iFoloTodo] Loading iFolo Todo Plugin...");
        // 1. 初始化 MCP Client 与子进程连接
        const connected = await this.client.init();
        if (connected) {
            console.log("[iFoloTodo] Successfully connected to local iFolo MCP service.");
        }
        else {
            console.warn("[iFoloTodo] Could not connect to iFolo MCP immediately. Will attempt on demand.");
        }
        // 2. 启动数据目录与会话任务自动同步
        this.watcher.start();
        this.sessionTodoWatcher.start();
    }
    async onUnload() {
        console.log("[iFoloTodo] Unloading iFolo Todo Plugin...");
        this.sessionTodoWatcher.stop();
        this.watcher.stop();
        this.client.destroy();
    }
    getSessionTodoWatcher() {
        return this.sessionTodoWatcher;
    }
    getClient() {
        return this.client;
    }
    getActions() {
        return this.actions;
    }
    getWatcher() {
        return this.watcher;
    }
}
const pluginInstance = new IFoloTodoPlugin();
async function onLoad() {
    await pluginInstance.onLoad();
}
async function onUnload() {
    await pluginInstance.onUnload();
}
/**
 * 响应 pi-desktop Webview 侧栏与弹窗面板的 RPC 交互
 */
async function onPanelInvoke(channel, payload) {
    const client = pluginInstance.getClient();
    const actions = pluginInstance.getActions();
    // 保证连接可用
    await client.init().catch(() => { });
    switch (channel) {
        case "ifolo.getStatus": {
            const isRunning = pluginInstance.getClient()["connection"].isRunning();
            return { ok: true, connected: isRunning };
        }
        case "ifolo.listNotes": {
            try {
                const limit = typeof payload?.limit === "number" ? payload.limit : 60;
                const notes = await client.listNotes(limit);
                return { ok: true, notes };
            }
            catch (err) {
                return { ok: false, error: err.message, notes: [] };
            }
        }
        case "ifolo.readNote": {
            try {
                const noteId = payload?.noteId;
                if (!noteId)
                    throw new Error("Missing noteId");
                const res = await client.readNote(noteId);
                return { ok: true, content: res.content, isLocked: res.isLocked };
            }
            catch (err) {
                return { ok: false, error: err.message };
            }
        }
        case "ifolo.searchNotes": {
            try {
                const query = payload?.query || "";
                const limit = payload?.limit || 20;
                const results = await client.searchNotes(query, limit);
                return { ok: true, results };
            }
            catch (err) {
                return { ok: false, error: err.message, results: [] };
            }
        }
        case "ifolo.capture": {
            const capturePayload = payload;
            const res = await actions.captureToNote(capturePayload);
            return res;
        }
        case "ifolo.toggleTodo": {
            const { noteId, todoText, completed } = payload || {};
            const ok = await actions.toggleTodo(noteId, todoText, completed);
            return { ok };
        }
        case "ifolo.openPanel": {
            const hostApi = getHostApi();
            if (typeof hostApi?.ui?.openPanel === "function") {
                await hostApi.ui.openPanel();
                return { ok: true };
            }
            return { ok: false, error: "pi.ui.openPanel unavailable" };
        }
        case "ifolo.pollChanges": {
            const currentRev = pluginInstance.getWatcher().getRevision();
            const since = typeof payload?.since === "number" ? payload.since : 0;
            return {
                ok: true,
                revision: currentRev,
                hasChanges: currentRev > since
            };
        }
        case "ifolo.getSessionTodos": {
            const sessionData = pluginInstance.getSessionTodoWatcher().getCurrentSessionData();
            return {
                ok: true,
                session: sessionData
            };
        }
        case "ifolo.syncSessionNow": {
            pluginInstance.getSessionTodoWatcher().syncSessionTodos();
            return { ok: true };
        }
        default:
            throw new Error(`[iFoloTodo] Unknown RPC invoke channel: ${channel}`);
    }
}
/**
 * 响应 PI-Desktop 快捷命令面板与快捷键触发
 */
async function onCommand(commandId, ...args) {
    const hostApi = getHostApi();
    switch (commandId) {
        case "ifolo-todo.openSidebar": {
            if (typeof hostApi?.ui?.openView === "function") {
                return await hostApi.ui.openView("ifolo-todo-sidebar");
            }
            return { ok: false, error: "pi.ui.openView unavailable" };
        }
        case "ifolo-todo.quickCapture": {
            if (typeof hostApi?.ui?.openPanel === "function") {
                return await hostApi.ui.openPanel();
            }
            return { ok: false, error: "pi.ui.openPanel unavailable" };
        }
        default:
            console.warn(`[iFoloTodo] Unhandled onCommand: ${commandId}`);
            return { ok: false, error: `Unhandled command ${commandId}` };
    }
}
module.exports = {
    onLoad,
    onUnload,
    onPanelInvoke,
    onCommand
};
