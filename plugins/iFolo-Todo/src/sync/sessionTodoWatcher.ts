import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execFile } from "node:child_process";
import { MCPClient } from "../mcp/client";

export interface SessionTodoItem {
  position: number;
  content: string;
  status: "pending" | "in_progress" | "completed" | "cancelled";
  priority: "high" | "medium" | "low";
  updatedAt: number;
}

export interface ActiveSessionData {
  sessionId: string;
  sessionTitle: string;
  todos: SessionTodoItem[];
  lastSyncedNoteId?: string;
  lastUpdatedAt: number;
}

/**
 * 监听 PI-Desktop 会话任务变动并自动汇总同步至 iFolo 主程序的代办笔记分类
 */
export class SessionTodoWatcher {
  private dbPath: string;
  private client: MCPClient;
  private watcher: fs.FSWatcher | null = null;
  private pollTimer: NodeJS.Timeout | null = null;
  private isProcessing = false;
  private lastSessionFingerprint = "";
  private currentActiveSession: ActiveSessionData | null = null;

  constructor(client: MCPClient) {
    this.client = client;
    this.dbPath = path.join(os.homedir(), ".pi-desktop", "pi.sqlite");
  }

  public start(): void {
    const dir = path.dirname(this.dbPath);
    if (!fs.existsSync(dir)) {
      console.warn("[SessionTodoWatcher] .pi-desktop directory not found yet:", dir);
      return;
    }

    try {
      this.watcher = fs.watch(dir, (eventType, filename) => {
        if (filename && (filename.includes("pi.sqlite") || filename.includes("session"))) {
          this.syncSessionTodos();
        }
      });
    } catch (e) {
      console.warn("[SessionTodoWatcher] File watcher unavailable, relying on polling:", e);
    }

    // 1000ms 定时探测活跃任务
    this.pollTimer = setInterval(() => {
      this.syncSessionTodos();
    }, 1000);

    // 初始立即执行一次
    this.syncSessionTodos();
  }

  public stop(): void {
    if (this.watcher) {
      this.watcher.close();
      this.watcher = null;
    }
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  public getCurrentSessionData(): ActiveSessionData | null {
    return this.currentActiveSession;
  }

  /**
   * 读取当前活跃会话与任务并执行汇总同步
   */
  public syncSessionTodos(): void {
    if (this.isProcessing || !fs.existsSync(this.dbPath)) return;
    this.isProcessing = true;

    // 优先获取最近更新且包含任务清单的活跃会话
    const sessionQuery = "SELECT s.id, s.title, s.updated_at FROM sessions s INNER JOIN session_todo t ON s.id = t.session_id GROUP BY s.id ORDER BY s.updated_at DESC LIMIT 1;";
    execFile("sqlite3", [this.dbPath, sessionQuery], { timeout: 2000 }, (err, stdout) => {
      if (err || !stdout || !stdout.trim()) {
        this.isProcessing = false;
        return;
      }

      const [sessionId, rawTitle, updatedAtStr] = stdout.trim().split("|");
      if (!sessionId) {
        this.isProcessing = false;
        return;
      }

      const sessionTitle = (rawTitle && rawTitle.trim()) ? rawTitle.trim() : "无标题任务会话";

      // 获取该会话下的所有 Todo 任务项
      const todoQuery = `SELECT position, content, status, priority, updated_at FROM session_todo WHERE session_id = '${sessionId}' ORDER BY position ASC;`;
      execFile("sqlite3", [this.dbPath, todoQuery], { timeout: 2000 }, async (todoErr, todoOut) => {
        try {
          if (todoErr || !todoOut || !todoOut.trim()) {
            this.isProcessing = false;
            return;
          }

          const lines = todoOut.trim().split("\n");
          const todos: SessionTodoItem[] = [];

          for (const line of lines) {
            const parts = line.split("|");
            if (parts.length >= 5) {
              todos.push({
                position: parseInt(parts[0], 10),
                content: parts[1],
                status: parts[2] as any,
                priority: parts[3] as any,
                updatedAt: parseInt(parts[4], 10)
              });
            }
          }

          if (todos.length === 0) {
            this.isProcessing = false;
            return;
          }

          // 构建变动指纹，避免重复写盘
          const fingerprint = `${sessionId}:${todos.map(t => `${t.position}-${t.status}-${t.content}`).join(";")}`;
          if (fingerprint === this.lastSessionFingerprint) {
            this.isProcessing = false;
            return;
          }

          this.lastSessionFingerprint = fingerprint;
          this.currentActiveSession = {
            sessionId,
            sessionTitle,
            todos,
            lastUpdatedAt: Date.now()
          };

          // 组织标准 Markdown 并同步至 iFolo 代办分类
          await this.syncToIFoloTodoFolder(sessionId, sessionTitle, todos);
        } catch (syncError) {
          console.error("[SessionTodoWatcher] Sync failed:", syncError);
        } finally {
          this.isProcessing = false;
        }
      });
    });
  }

  private async syncToIFoloTodoFolder(sessionId: string, sessionTitle: string, todos: SessionTodoItem[]): Promise<void> {
    const completedCount = todos.filter(t => t.status === "completed").length;
    const totalCount = todos.length;
    const progressPercent = Math.round((completedCount / totalCount) * 100);

    const noteTitle = `[会话任务] ${sessionTitle}`;
    let md = `# ${noteTitle}\n\n`;
    md += `> 📌 **会话待办汇总** · 进度：**${completedCount}/${totalCount} (${progressPercent}%)** · 更新：${new Date().toLocaleString()}\n`;
    md += `> 会话标识：\`${sessionId}\`\n\n`;
    md += `### 待办任务清单\n\n`;

    for (const t of todos) {
      const isDone = t.status === "completed";
      const priorityLabel = t.priority === "high" ? "🔥高优" : (t.priority === "low" ? "🌱低优" : "");
      const statusLabel = t.status === "in_progress" ? " (进行中...)" : (t.status === "cancelled" ? " (已取消)" : "");
      const checkMark = isDone ? "[x]" : "[ ]";
      md += `- ${checkMark} ${t.content}${statusLabel} ${priorityLabel}\n`;
    }

    md += `\n---\n*由 PI-Desktop iFolo Todo 插件自动同步至「代办笔记」分类*`;

    try {
      const existingNotes = await this.client.listNotes(100);
      const matched = existingNotes.find(n => n.title.includes(sessionId) || n.title.includes(noteTitle));

      if (matched) {
        const notesDir = path.join(os.homedir(), "Library/Application Support/iFolo/notes");
        const notePath = path.join(notesDir, `${matched.id}.md`);
        if (fs.existsSync(notePath)) {
          fs.writeFileSync(notePath, md, "utf-8");
          console.log(`[SessionTodoWatcher] Updated active session todo note: ${matched.id}`);
        }
      } else {
        const res: any = await this.client.createNote(md, noteTitle, true);
        const createdId = typeof res === "object" && res !== null ? (res.note_id || res.id) : String(res);
        if (createdId) {
          this.assignNoteToTodoFolder(createdId);
          console.log(`[SessionTodoWatcher] Created and assigned session todo to 'todo' folder: ${createdId}`);
        }
      }
    } catch (err) {
      console.error("[SessionTodoWatcher] Failed to write iFolo todo note:", err);
    }
  }

  private assignNoteToTodoFolder(noteId: string): void {
    const foldersPath = path.join(os.homedir(), "Library/Application Support/iFolo/folders.json");
    if (!fs.existsSync(foldersPath)) return;

    try {
      const content = fs.readFileSync(foldersPath, "utf-8");
      const folderData = JSON.parse(content);
      if (!folderData.noteFolders) {
        folderData.noteFolders = {};
      }
      folderData.noteFolders[noteId] = "todo";
      fs.writeFileSync(foldersPath, JSON.stringify(folderData, null, 2), "utf-8");
    } catch (e) {
      console.error("[SessionTodoWatcher] assignNoteToTodoFolder failed:", e);
    }
  }
}
