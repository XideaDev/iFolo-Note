"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.NoteActions = void 0;
class NoteActions {
    client;
    constructor(client) {
        this.client = client;
    }
    async captureToNote(payload) {
        try {
            if (payload.content && payload.content.length > 500_000) {
                return { ok: false, error: "单次沉淀内容超过 500KB 上限" };
            }
            if (payload.targetNoteId) {
                // 追加模式
                const appendContent = `\n\n> 沉淀自 pi-desktop 会话 [${new Date().toLocaleString()}]\n\n${payload.content}`;
                await this.client.appendNote(payload.targetNoteId, appendContent);
                return { ok: true, noteId: payload.targetNoteId };
            }
            else {
                // 新建模式
                const title = payload.title || `代办笔记 - ${new Date().toLocaleDateString()}`;
                const tagHeader = payload.tags && payload.tags.length > 0 ? `${payload.tags.map(t => `#${t}`).join(" ")}\n\n` : "";
                const finalContent = `${tagHeader}${payload.content}\n\n---\n*沉淀自 pi-desktop iFolo Todo*`;
                const res = await this.client.createNote(finalContent, title, payload.isPinned ?? false);
                const createdId = typeof res === "object" && res !== null ? (res.note_id || res.id) : String(res);
                return { ok: true, noteId: createdId };
            }
        }
        catch (e) {
            console.error("[iFoloTodo] captureToNote failed:", e);
            return { ok: false, error: e.message || String(e) };
        }
    }
    async toggleTodo(noteId, todoText, completed) {
        try {
            const noteRes = await this.client.readNote(noteId);
            const fullText = noteRes.content;
            if (!fullText || noteRes.isLocked) {
                return { ok: false, error: noteRes.isLocked ? "笔记已加锁，请先解锁" : "Note not found or empty" };
            }
            const targetPattern = completed
                ? `- [ ] ${todoText}`
                : `- [x] ${todoText}`;
            if (!fullText.includes(targetPattern)) {
                return { ok: false, error: "Target task item not found in note" };
            }
            console.warn(`[iFoloTodo] In-place todo toggling is reserved for iFolo native editor. Item: "${todoText}"`);
            return {
                ok: false,
                error: "行内待办更新受 iFolo 原生防篡改保护，请在 iFolo 悬浮窗口中直接勾选"
            };
        }
        catch (e) {
            console.error("[iFoloTodo] toggleTodo error:", e);
            return { ok: false, error: e.message || String(e) };
        }
    }
}
exports.NoteActions = NoteActions;
