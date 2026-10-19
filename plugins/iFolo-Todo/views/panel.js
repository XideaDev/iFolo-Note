class TodoPanelController {
    // 顶层主选项卡
    tabSessionTodos;
    tabIfoloNotes;
    sessionTodoBadge;
    notesTodoBadge;
    viewSessionTodos;
    viewIfoloNotes;
    searchBoxWrap;
    searchInput;
    // 会话任务看板元素
    currentSessionTitle;
    sessionProgressText;
    sessionProgressFill;
    sessionTasksList;
    sessionEmptyHint;
    // 代办笔记库元素
    notesContainer;
    notesEmptyHint;
    // 快速沉淀卡片
    quickCreateCard;
    tabModeCreate;
    tabModeAppend;
    createFields;
    appendFields;
    appendTargetSelect;
    pinToggleWrap;
    // 详情弹窗
    detailModal;
    detailBackdrop;
    detailTitle;
    detailMeta;
    detailBody;
    btnCloseDetail;
    // 状态与数据
    currentTab = "session";
    currentMode = "create";
    allNotes = [];
    activeSession = null;
    lastRevision = 0;
    syncTimer = null;
    constructor() {
        this.tabSessionTodos = document.getElementById("tab-session-todos");
        this.tabIfoloNotes = document.getElementById("tab-ifolo-notes");
        this.sessionTodoBadge = document.getElementById("session-todo-badge");
        this.notesTodoBadge = document.getElementById("notes-todo-badge");
        this.viewSessionTodos = document.getElementById("view-session-todos");
        this.viewIfoloNotes = document.getElementById("view-ifolo-notes");
        this.searchBoxWrap = document.getElementById("search-box-wrap");
        this.searchInput = document.getElementById("search-input");
        this.currentSessionTitle = document.getElementById("current-session-title");
        this.sessionProgressText = document.getElementById("session-progress-text");
        this.sessionProgressFill = document.getElementById("session-progress-fill");
        this.sessionTasksList = document.getElementById("session-tasks-list");
        this.sessionEmptyHint = document.getElementById("session-empty-hint");
        this.notesContainer = document.getElementById("notes-container");
        this.notesEmptyHint = document.getElementById("notes-empty-hint");
        this.quickCreateCard = document.getElementById("quick-create-card");
        this.tabModeCreate = document.getElementById("tab-mode-create");
        this.tabModeAppend = document.getElementById("tab-mode-append");
        this.createFields = document.getElementById("create-mode-fields");
        this.appendFields = document.getElementById("append-mode-fields");
        this.appendTargetSelect = document.getElementById("append-target-select");
        this.pinToggleWrap = document.getElementById("pin-toggle-wrap");
        this.detailModal = document.getElementById("detail-modal");
        this.detailBackdrop = document.getElementById("detail-backdrop");
        this.detailTitle = document.getElementById("detail-title");
        this.detailMeta = document.getElementById("detail-meta");
        this.detailBody = document.getElementById("detail-body");
        this.btnCloseDetail = document.getElementById("btn-close-detail");
        this.bindEvents();
        this.init();
    }
    bindEvents() {
        // 顶部主选项卡切换
        this.tabSessionTodos.addEventListener("click", () => this.switchMainTab("session"));
        this.tabIfoloNotes.addEventListener("click", () => this.switchMainTab("notes"));
        // 立即刷新
        const btnRefresh = document.getElementById("btn-refresh");
        btnRefresh?.addEventListener("click", async () => {
            await this.invokeRpc("ifolo.syncSessionNow");
            await this.refreshAll();
        });
        btnRefresh?.addEventListener("dblclick", () => {
            window.location.reload();
        });
        // 展开/收起快速新建
        document.getElementById("btn-quick-new")?.addEventListener("click", () => {
            this.quickCreateCard.classList.toggle("hidden");
            if (!this.quickCreateCard.classList.contains("hidden")) {
                this.updateAppendSelectOptions();
                document.getElementById("new-note-content")?.focus();
            }
        });
        document.getElementById("btn-cancel-create")?.addEventListener("click", () => {
            this.quickCreateCard.classList.add("hidden");
        });
        // 新建 / 追加模式切换
        this.tabModeCreate.addEventListener("click", () => this.switchCaptureMode("create"));
        this.tabModeAppend.addEventListener("click", () => this.switchCaptureMode("append"));
        // 提交代办保存
        document.getElementById("btn-submit-create")?.addEventListener("click", () => {
            this.handleCreateSubmit();
        });
        // 搜索输入去抖 (仅代办笔记库)
        let searchTimer;
        this.searchInput.addEventListener("input", () => {
            clearTimeout(searchTimer);
            searchTimer = setTimeout(() => {
                this.handleSearch();
            }, 300);
        });
        // 详情模态浮层
        this.btnCloseDetail.addEventListener("click", () => this.closeDetailModal());
        this.detailBackdrop.addEventListener("click", () => this.closeDetailModal());
        // 焦点恢复探测
        window.addEventListener("focus", () => {
            this.refreshAll();
        });
    }
    async init() {
        this.applyThemeAdaptation();
        await this.refreshAll();
        this.startAutoSyncLoop();
    }
    applyThemeAdaptation() {
        const mql = window.matchMedia("(prefers-color-scheme: dark)");
        const updateTheme = () => {
            const isDark = mql.matches ||
                document.body.classList.contains("dark") ||
                document.documentElement.classList.contains("dark");
            if (isDark) {
                document.documentElement.setAttribute("data-theme", "dark");
            }
            else {
                document.documentElement.removeAttribute("data-theme");
            }
        };
        updateTheme();
        mql.addEventListener("change", updateTheme);
    }
    async waitForPiApi(timeoutMs = 1500) {
        const start = Date.now();
        while (Date.now() - start < timeoutMs) {
            if (typeof window.pi?.invoke === "function") {
                return window.pi;
            }
            await new Promise((r) => setTimeout(r, 40));
        }
        return window.pi || null;
    }
    async invokeRpc(channel, payload) {
        const api = await this.waitForPiApi();
        if (api && typeof api.invoke === "function") {
            return await api.invoke(channel, payload);
        }
        console.warn(`[TodoPanel] pi.invoke unavailable for ${channel}`);
        return { ok: false, error: "API_UNAVAILABLE" };
    }
    async refreshAll() {
        await Promise.all([
            this.loadSessionTodos(),
            this.loadIfoloNotes()
        ]);
    }
    startAutoSyncLoop() {
        if (this.syncTimer)
            clearInterval(this.syncTimer);
        this.syncTimer = setInterval(async () => {
            if (document.hidden)
                return;
            const pollRes = await this.invokeRpc("ifolo.pollChanges", { since: this.lastRevision });
            if (pollRes?.ok) {
                this.lastRevision = pollRes.revision;
                if (pollRes.hasChanges) {
                    await this.loadIfoloNotes();
                }
            }
            await this.loadSessionTodos();
        }, 1200);
    }
    async loadSessionTodos() {
        try {
            const res = await this.invokeRpc("ifolo.getSessionTodos");
            if (res?.ok && res.session) {
                this.activeSession = res.session;
                this.renderSessionTodos(res.session);
            }
            else {
                this.currentSessionTitle.innerText = "暂无活跃任务会话";
                this.sessionProgressText.innerText = "0/0";
                this.sessionProgressFill.style.width = "0%";
                this.sessionTodoBadge.innerText = "0";
                this.sessionTasksList.innerHTML = "";
                this.sessionEmptyHint.classList.remove("hidden");
            }
        }
        catch (e) {
            console.error("[TodoPanel] Failed to load session todos:", e);
        }
    }
    renderSessionTodos(session) {
        this.currentSessionTitle.innerText = session.sessionTitle || "当前会话";
        const todos = session.todos || [];
        const total = todos.length;
        const completed = todos.filter((t) => t.status === "completed").length;
        const percent = total > 0 ? Math.round((completed / total) * 100) : 0;
        this.sessionProgressText.innerText = `${completed}/${total} (${percent}%)`;
        this.sessionProgressFill.style.width = `${percent}%`;
        this.sessionTodoBadge.innerText = String(total);
        this.sessionTasksList.innerHTML = "";
        if (todos.length === 0) {
            this.sessionEmptyHint.classList.remove("hidden");
            return;
        }
        this.sessionEmptyHint.classList.add("hidden");
        for (const t of todos) {
            const card = document.createElement("div");
            const isDone = t.status === "completed";
            const isProgress = t.status === "in_progress";
            card.className = `session-task-card ${isDone ? "is-done" : ""} ${isProgress ? "is-progress" : ""}`;
            const check = document.createElement("div");
            check.className = "task-checkbox-indicator";
            check.innerText = isDone ? "✓" : (isProgress ? "●" : "");
            card.appendChild(check);
            const body = document.createElement("div");
            body.className = "task-content-box";
            const text = document.createElement("div");
            text.className = "task-text";
            text.innerText = t.content;
            body.appendChild(text);
            const footerTags = document.createElement("div");
            footerTags.className = "task-footer-tags";
            const statusBadge = document.createElement("span");
            if (isDone) {
                statusBadge.className = "task-badge task-badge--done";
                statusBadge.innerText = "已完成";
            }
            else if (isProgress) {
                statusBadge.className = "task-badge task-badge--progress";
                statusBadge.innerText = "正在进行...";
            }
            else if (t.status === "cancelled") {
                statusBadge.className = "task-badge task-badge--pending";
                statusBadge.innerText = "已取消";
            }
            else {
                statusBadge.className = "task-badge task-badge--pending";
                statusBadge.innerText = "排队等待";
            }
            footerTags.appendChild(statusBadge);
            if (t.priority === "high") {
                const priBadge = document.createElement("span");
                priBadge.className = "task-badge task-badge--high";
                priBadge.innerText = "🔥高优";
                footerTags.appendChild(priBadge);
            }
            body.appendChild(footerTags);
            card.appendChild(body);
            this.sessionTasksList.appendChild(card);
        }
    }
    async loadIfoloNotes() {
        try {
            const res = await this.invokeRpc("ifolo.listNotes", { limit: 60 });
            if (res?.ok && Array.isArray(res.notes)) {
                this.allNotes = res.notes;
                const todoNotes = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
                this.notesTodoBadge.innerText = String(todoNotes.length);
                if (this.currentTab === "notes") {
                    this.renderIfoloNotes(todoNotes);
                }
                this.updateAppendSelectOptions();
            }
        }
        catch (e) {
            console.error("[TodoPanel] Failed to load ifolo notes:", e);
        }
    }
    renderIfoloNotes(notes) {
        this.notesContainer.innerHTML = "";
        if (notes.length === 0) {
            this.notesEmptyHint.classList.remove("hidden");
            return;
        }
        this.notesEmptyHint.classList.add("hidden");
        for (const note of notes) {
            const card = document.createElement("div");
            card.className = "note-card";
            card.addEventListener("click", () => {
                this.openNoteDetail(note);
            });
            const header = document.createElement("div");
            header.className = "note-card__header";
            const title = document.createElement("div");
            title.className = "note-card__title";
            title.innerText = note.title || "未命名代办";
            header.appendChild(title);
            if (note.isPinned) {
                const badge = document.createElement("span");
                badge.className = "note-card__badge";
                badge.innerText = "置顶";
                header.appendChild(badge);
            }
            else {
                const todoBadge = document.createElement("span");
                todoBadge.className = "note-card__badge note-card__badge--todo";
                todoBadge.innerText = "代办";
                header.appendChild(todoBadge);
            }
            const snippet = document.createElement("div");
            snippet.className = "note-card__snippet";
            snippet.innerText = note.snippet || "暂无待办明细";
            card.appendChild(header);
            card.appendChild(snippet);
            this.notesContainer.appendChild(card);
        }
    }
    switchMainTab(tab) {
        this.currentTab = tab;
        if (tab === "session") {
            this.tabSessionTodos.classList.add("active");
            this.tabIfoloNotes.classList.remove("active");
            this.viewSessionTodos.classList.remove("hidden");
            this.viewIfoloNotes.classList.add("hidden");
            this.searchBoxWrap.classList.add("hidden");
            this.loadSessionTodos();
        }
        else {
            this.tabSessionTodos.classList.remove("active");
            this.tabIfoloNotes.classList.add("active");
            this.viewSessionTodos.classList.add("hidden");
            this.viewIfoloNotes.classList.remove("hidden");
            this.searchBoxWrap.classList.remove("hidden");
            const todoNotes = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
            this.renderIfoloNotes(todoNotes);
        }
    }
    switchCaptureMode(mode) {
        this.currentMode = mode;
        if (mode === "create") {
            this.tabModeCreate.classList.add("active");
            this.tabModeAppend.classList.remove("active");
            this.createFields.classList.remove("hidden");
            this.appendFields.classList.add("hidden");
            this.pinToggleWrap.classList.remove("hidden");
        }
        else {
            this.tabModeCreate.classList.remove("active");
            this.tabModeAppend.classList.add("active");
            this.createFields.classList.add("hidden");
            this.appendFields.classList.remove("hidden");
            this.pinToggleWrap.classList.add("hidden");
            this.updateAppendSelectOptions();
        }
    }
    updateAppendSelectOptions() {
        const currentVal = this.appendTargetSelect.value;
        this.appendTargetSelect.innerHTML = '<option value="">-- 请选择目标代办笔记 --</option>';
        const candidates = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
        for (const note of (candidates.length > 0 ? candidates : this.allNotes)) {
            const opt = document.createElement("option");
            opt.value = note.id;
            opt.innerText = `${note.isPinned ? "📌 " : ""}${note.title || "无标题笔记"}`;
            this.appendTargetSelect.appendChild(opt);
        }
        if (currentVal) {
            this.appendTargetSelect.value = currentVal;
        }
    }
    async handleSearch() {
        const query = this.searchInput.value.trim();
        if (!query) {
            const todoNotes = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
            return this.renderIfoloNotes(todoNotes);
        }
        try {
            const res = await this.invokeRpc("ifolo.searchNotes", { query, limit: 20 });
            if (res?.ok && Array.isArray(res.results)) {
                const mapped = res.results.map((r) => ({
                    id: r.id,
                    title: r.title,
                    snippet: r.snippet || r.matchedText,
                    updatedAt: r.updatedAt,
                    folderId: "todo"
                }));
                this.renderIfoloNotes(mapped);
            }
        }
        catch (e) {
            console.error("[TodoPanel] Search failed:", e);
        }
    }
    async handleCreateSubmit() {
        const titleInput = document.getElementById("new-note-title");
        const contentInput = document.getElementById("new-note-content");
        const pinInput = document.getElementById("new-note-pin");
        const content = contentInput.value.trim();
        if (!content)
            return;
        try {
            let payload = { content };
            if (this.currentMode === "create") {
                payload.title = titleInput.value.trim() || undefined;
                payload.isPinned = pinInput.checked;
                payload.folderId = "todo";
            }
            else {
                const targetId = this.appendTargetSelect.value;
                if (!targetId) {
                    alert("请先选择要追加的目标代办笔记");
                    return;
                }
                payload.targetNoteId = targetId;
            }
            const res = await this.invokeRpc("ifolo.capture", payload);
            if (res?.ok) {
                titleInput.value = "";
                contentInput.value = "";
                pinInput.checked = false;
                this.quickCreateCard.classList.add("hidden");
                await this.loadIfoloNotes();
            }
            else {
                alert(res?.error || "保存失败");
            }
        }
        catch (e) {
            console.error("[TodoPanel] Submit failed:", e);
            alert("提交失败: " + e.message);
        }
    }
    async openNoteDetail(note) {
        this.detailTitle.innerText = note.title || "代办正文";
        const dateStr = typeof note.updatedAt === "number"
            ? new Date(note.updatedAt * 1000).toLocaleString()
            : String(note.updatedAt || "");
        this.detailMeta.innerText = dateStr ? `更新于 ${dateStr}` : "";
        this.detailBody.innerHTML = '<div style="color: var(--text-muted); padding: 10px 0;">正在读取代办正文...</div>';
        this.detailModal.classList.remove("hidden");
        try {
            const res = await this.invokeRpc("ifolo.readNote", { noteId: note.id });
            if (res?.ok) {
                if (res.isLocked) {
                    this.detailBody.innerHTML = `
            <div class="lock-card">
              <div class="lock-card__icon">🔒</div>
              <div class="lock-card__title">受硬件级私密锁保护</div>
              <div class="lock-card__desc">此代办笔记已通过 AES-256 硬件密文锁定。请直接在 macOS 的 iFolo 悬浮窗口通过 Touch ID 解锁后查看。</div>
            </div>
          `;
                }
                else {
                    this.detailBody.innerText = res.content || "(正文内容为空)";
                }
            }
            else {
                this.detailBody.innerText = "读取失败: " + (res?.error || "未知异常");
            }
        }
        catch (e) {
            this.detailBody.innerText = "读取失败: " + e.message;
        }
    }
    closeDetailModal() {
        this.detailModal.classList.add("hidden");
    }
}
document.addEventListener("DOMContentLoaded", () => {
    new TodoPanelController();
});
