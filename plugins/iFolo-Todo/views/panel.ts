// 声明 pi-desktop 宿主全局注入的 API
declare const pi: {
  invoke: (channel: string, payload?: any) => Promise<any>;
};

interface SessionTodoItem {
  position: number;
  content: string;
  status: "pending" | "in_progress" | "completed" | "cancelled";
  priority: "high" | "medium" | "low";
  updatedAt: number;
}

interface ActiveSessionData {
  sessionId: string;
  sessionTitle: string;
  todos: SessionTodoItem[];
  lastSyncedNoteId?: string;
  lastUpdatedAt: number;
}

interface NoteItem {
  id: string;
  title: string;
  snippet: string;
  updatedAt: string | number;
  isPinned?: boolean;
  hasTodo?: boolean;
  folderId?: string;
  tags?: string[];
}

type MainViewTab = "session" | "notes";
type CaptureMode = "create" | "append";

class TodoPanelController {
  // 顶层主选项卡
  private tabSessionTodos: HTMLElement;
  private tabIfoloNotes: HTMLElement;
  private sessionTodoBadge: HTMLElement;
  private notesTodoBadge: HTMLElement;

  private viewSessionTodos: HTMLElement;
  private viewIfoloNotes: HTMLElement;
  private searchBoxWrap: HTMLElement;
  private searchInput: HTMLInputElement;

  // 会话任务看板元素
  private currentSessionTitle: HTMLElement;
  private sessionProgressText: HTMLElement;
  private sessionProgressFill: HTMLElement;
  private sessionTasksList: HTMLElement;
  private sessionEmptyHint: HTMLElement;

  // 代办笔记库元素
  private notesContainer: HTMLElement;
  private notesEmptyHint: HTMLElement;

  // 快速沉淀卡片
  private quickCreateCard: HTMLElement;
  private tabModeCreate: HTMLElement;
  private tabModeAppend: HTMLElement;
  private createFields: HTMLElement;
  private appendFields: HTMLElement;
  private appendTargetSelect: HTMLSelectElement;
  private pinToggleWrap: HTMLElement;

  // 详情弹窗
  private detailModal: HTMLElement;
  private detailBackdrop: HTMLElement;
  private detailTitle: HTMLElement;
  private detailMeta: HTMLElement;
  private detailBody: HTMLElement;
  private btnCloseDetail: HTMLElement;

  // 状态与数据
  private currentTab: MainViewTab = "session";
  private currentMode: CaptureMode = "create";
  private allNotes: NoteItem[] = [];
  private activeSession: ActiveSessionData | null = null;
  private lastRevision = 0;
  private syncTimer: any = null;

  constructor() {
    this.tabSessionTodos = document.getElementById("tab-session-todos")!;
    this.tabIfoloNotes = document.getElementById("tab-ifolo-notes")!;
    this.sessionTodoBadge = document.getElementById("session-todo-badge")!;
    this.notesTodoBadge = document.getElementById("notes-todo-badge")!;

    this.viewSessionTodos = document.getElementById("view-session-todos")!;
    this.viewIfoloNotes = document.getElementById("view-ifolo-notes")!;
    this.searchBoxWrap = document.getElementById("search-box-wrap")!;
    this.searchInput = document.getElementById("search-input") as HTMLInputElement;

    this.currentSessionTitle = document.getElementById("current-session-title")!;
    this.sessionProgressText = document.getElementById("session-progress-text")!;
    this.sessionProgressFill = document.getElementById("session-progress-fill")!;
    this.sessionTasksList = document.getElementById("session-tasks-list")!;
    this.sessionEmptyHint = document.getElementById("session-empty-hint")!;

    this.notesContainer = document.getElementById("notes-container")!;
    this.notesEmptyHint = document.getElementById("notes-empty-hint")!;

    this.quickCreateCard = document.getElementById("quick-create-card")!;
    this.tabModeCreate = document.getElementById("tab-mode-create")!;
    this.tabModeAppend = document.getElementById("tab-mode-append")!;
    this.createFields = document.getElementById("create-mode-fields")!;
    this.appendFields = document.getElementById("append-mode-fields")!;
    this.appendTargetSelect = document.getElementById("append-target-select") as HTMLSelectElement;
    this.pinToggleWrap = document.getElementById("pin-toggle-wrap")!;

    this.detailModal = document.getElementById("detail-modal")!;
    this.detailBackdrop = document.getElementById("detail-backdrop")!;
    this.detailTitle = document.getElementById("detail-title")!;
    this.detailMeta = document.getElementById("detail-meta")!;
    this.detailBody = document.getElementById("detail-body")!;
    this.btnCloseDetail = document.getElementById("btn-close-detail")!;

    this.bindEvents();
    this.init();
  }

  private bindEvents(): void {
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
        (document.getElementById("new-note-content") as HTMLTextAreaElement)?.focus();
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
    let searchTimer: any;
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

  private async init(): Promise<void> {
    this.applyThemeAdaptation();
    await this.refreshAll();
    this.startAutoSyncLoop();
  }

  private applyThemeAdaptation(): void {
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const updateTheme = () => {
      const isDark = mql.matches || 
        document.body.classList.contains("dark") || 
        document.documentElement.classList.contains("dark");
      if (isDark) {
        document.documentElement.setAttribute("data-theme", "dark");
      } else {
        document.documentElement.removeAttribute("data-theme");
      }
    };
    updateTheme();
    mql.addEventListener("change", updateTheme);
  }

  private async waitForPiApi(timeoutMs = 1500): Promise<any> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (typeof (window as any).pi?.invoke === "function") {
        return (window as any).pi;
      }
      await new Promise((r) => setTimeout(r, 40));
    }
    return (window as any).pi || null;
  }

  private async invokeRpc(channel: string, payload?: any): Promise<any> {
    const api = await this.waitForPiApi();
    if (api && typeof api.invoke === "function") {
      return await api.invoke(channel, payload);
    }
    console.warn(`[TodoPanel] pi.invoke unavailable for ${channel}`);
    return { ok: false, error: "API_UNAVAILABLE" };
  }

  private async refreshAll(): Promise<void> {
    await Promise.all([
      this.loadSessionTodos(),
      this.loadIfoloNotes()
    ]);
  }

  private startAutoSyncLoop(): void {
    if (this.syncTimer) clearInterval(this.syncTimer);
    this.syncTimer = setInterval(async () => {
      if (document.hidden) return;

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

  private async loadSessionTodos(): Promise<void> {
    try {
      const res = await this.invokeRpc("ifolo.getSessionTodos");
      if (res?.ok && res.session) {
        this.activeSession = res.session;
        this.renderSessionTodos(res.session);
      } else {
        this.currentSessionTitle.innerText = "暂无活跃任务会话";
        this.sessionProgressText.innerText = "0/0";
        this.sessionProgressFill.style.width = "0%";
        this.sessionTodoBadge.innerText = "0";
        this.sessionTasksList.innerHTML = "";
        this.sessionEmptyHint.classList.remove("hidden");
      }
    } catch (e) {
      console.error("[TodoPanel] Failed to load session todos:", e);
    }
  }

  private renderSessionTodos(session: ActiveSessionData): void {
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
      } else if (isProgress) {
        statusBadge.className = "task-badge task-badge--progress";
        statusBadge.innerText = "正在进行...";
      } else if (t.status === "cancelled") {
        statusBadge.className = "task-badge task-badge--pending";
        statusBadge.innerText = "已取消";
      } else {
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

  private async loadIfoloNotes(): Promise<void> {
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
    } catch (e) {
      console.error("[TodoPanel] Failed to load ifolo notes:", e);
    }
  }

  private renderIfoloNotes(notes: NoteItem[]): void {
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
      } else {
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

  private switchMainTab(tab: MainViewTab): void {
    this.currentTab = tab;
    if (tab === "session") {
      this.tabSessionTodos.classList.add("active");
      this.tabIfoloNotes.classList.remove("active");
      this.viewSessionTodos.classList.remove("hidden");
      this.viewIfoloNotes.classList.add("hidden");
      this.searchBoxWrap.classList.add("hidden");
      this.loadSessionTodos();
    } else {
      this.tabSessionTodos.classList.remove("active");
      this.tabIfoloNotes.classList.add("active");
      this.viewSessionTodos.classList.add("hidden");
      this.viewIfoloNotes.classList.remove("hidden");
      this.searchBoxWrap.classList.remove("hidden");
      const todoNotes = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
      this.renderIfoloNotes(todoNotes);
    }
  }

  private switchCaptureMode(mode: CaptureMode): void {
    this.currentMode = mode;
    if (mode === "create") {
      this.tabModeCreate.classList.add("active");
      this.tabModeAppend.classList.remove("active");
      this.createFields.classList.remove("hidden");
      this.appendFields.classList.add("hidden");
      this.pinToggleWrap.classList.remove("hidden");
    } else {
      this.tabModeCreate.classList.remove("active");
      this.tabModeAppend.classList.add("active");
      this.createFields.classList.add("hidden");
      this.appendFields.classList.remove("hidden");
      this.pinToggleWrap.classList.add("hidden");
      this.updateAppendSelectOptions();
    }
  }

  private updateAppendSelectOptions(): void {
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

  private async handleSearch(): Promise<void> {
    const query = this.searchInput.value.trim();
    if (!query) {
      const todoNotes = this.allNotes.filter(n => n.folderId === "todo" || !!n.hasTodo);
      return this.renderIfoloNotes(todoNotes);
    }

    try {
      const res = await this.invokeRpc("ifolo.searchNotes", { query, limit: 20 });
      if (res?.ok && Array.isArray(res.results)) {
        const mapped: NoteItem[] = res.results.map((r: any) => ({
          id: r.id,
          title: r.title,
          snippet: r.snippet || r.matchedText,
          updatedAt: r.updatedAt,
          folderId: "todo"
        }));
        this.renderIfoloNotes(mapped);
      }
    } catch (e) {
      console.error("[TodoPanel] Search failed:", e);
    }
  }

  private async handleCreateSubmit(): Promise<void> {
    const titleInput = document.getElementById("new-note-title") as HTMLInputElement;
    const contentInput = document.getElementById("new-note-content") as HTMLTextAreaElement;
    const pinInput = document.getElementById("new-note-pin") as HTMLInputElement;

    const content = contentInput.value.trim();
    if (!content) return;

    try {
      let payload: any = { content };

      if (this.currentMode === "create") {
        payload.title = titleInput.value.trim() || undefined;
        payload.isPinned = pinInput.checked;
        payload.folderId = "todo";
      } else {
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
      } else {
        alert(res?.error || "保存失败");
      }
    } catch (e: any) {
      console.error("[TodoPanel] Submit failed:", e);
      alert("提交失败: " + e.message);
    }
  }

  private async openNoteDetail(note: NoteItem): Promise<void> {
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
        } else {
          this.detailBody.innerText = res.content || "(正文内容为空)";
        }
      } else {
        this.detailBody.innerText = "读取失败: " + (res?.error || "未知异常");
      }
    } catch (e: any) {
      this.detailBody.innerText = "读取失败: " + e.message;
    }
  }

  private closeDetailModal(): void {
    this.detailModal.classList.add("hidden");
  }
}

document.addEventListener("DOMContentLoaded", () => {
  new TodoPanelController();
});
