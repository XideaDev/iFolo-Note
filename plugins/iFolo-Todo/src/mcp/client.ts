import { IFoloConnection } from "./connection";
import { MCPRequest, MCPResponse, NoteMetadata, SearchResultItem } from "./types";
import * as readline from "node:readline";

export class MCPClient {
  private connection: IFoloConnection;
  private nextId = 1;
  private pendingRequests = new Map<number | string, {
    resolve: (val: unknown) => void;
    reject: (err: Error) => void;
    timer: NodeJS.Timeout;
  }>();
  private rl: readline.Interface | null = null;
  private initialized = false;

  constructor(connection: IFoloConnection) {
    this.connection = connection;
  }

  public async init(): Promise<boolean> {
    if (this.initialized) return true;

    const started = this.connection.start();
    if (!started) return false;

    const child = this.connection.getChild();
    if (!child || !child.stdout || !child.stdin) return false;

    this.rl = readline.createInterface({
      input: child.stdout,
      terminal: false
    });

    this.rl.on("line", (line) => {
      this.handleIncomingLine(line);
    });

    try {
      const initResp = await this.request<{
        protocolVersion: string;
        serverInfo: { name: string; version: string };
      }>("initialize", {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "pi-desktop-plugin-ifolo-todo", version: "1.0.0" }
      });

      console.log(`[iFoloTodo] Connected to ${initResp?.serverInfo?.name} v${initResp?.serverInfo?.version}`);
      this.initialized = true;
      return true;
    } catch (e) {
      console.error("[iFoloTodo] MCP initialize handshake failed:", e);
      return false;
    }
  }

  private handleIncomingLine(line: string): void {
    const trimmed = line.trim();
    if (!trimmed) return;

    try {
      const resp = JSON.parse(trimmed) as MCPResponse;
      if (resp.id !== null && resp.id !== undefined) {
        const pending = this.pendingRequests.get(resp.id);
        if (pending) {
          clearTimeout(pending.timer);
          this.pendingRequests.delete(resp.id);
          if (resp.error) {
            pending.reject(new Error(`[MCP ${resp.error.code}] ${resp.error.message}`));
          } else {
            pending.resolve(resp.result);
          }
        }
      }
    } catch {
      console.debug("[iFoloTodo] Ignored non-json stdout output:", trimmed);
    }
  }

  public request<T = unknown>(method: string, params?: Record<string, unknown>, timeoutMs = 8000): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const child = this.connection.getChild();
      if (!child || !child.stdin || !this.connection.isRunning()) {
        return reject(new Error("iFolo MCP subprocess is not running"));
      }

      const id = this.nextId++;
      const req: MCPRequest = {
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
        resolve: (val) => resolve(val as T),
        reject,
        timer
      });

      const payload = JSON.stringify(req) + "\n";
      child.stdin.write(payload, "utf-8");
    });
  }

  public async callTool<T = unknown>(name: string, args: Record<string, unknown> = {}): Promise<T> {
    const res = await this.request<{ content: Array<{ type: string; text: string }>; isError?: boolean }>(
      "tools/call",
      {
        name,
        arguments: args
      }
    );

    if (res?.isError) {
      const msg = res.content?.[0]?.text || "Unknown tool call error";
      throw new Error(msg);
    }

    const rawText = res.content?.[0]?.text ?? "";
    try {
      return JSON.parse(rawText) as T;
    } catch {
      return rawText as unknown as T;
    }
  }

  // --- 业务高层封装 ---

  public async listNotes(limit = 60): Promise<NoteMetadata[]> {
    return this.callTool<NoteMetadata[]>("ifolo_list_notes", { limit });
  }

  public async readNote(noteId: string): Promise<{ content: string; isLocked: boolean }> {
    const raw = await this.callTool<string>("ifolo_read_note", { note_id: noteId });
    const isLocked = typeof raw === "string" && raw.includes("<!-- IFOLO_LOCKED_NOTE -->");
    return { content: raw, isLocked };
  }

  public async searchNotes(query: string, limit = 20): Promise<SearchResultItem[]> {
    return this.callTool<SearchResultItem[]>("ifolo_search_notes", { query, limit });
  }

  public async createNote(content: string, title?: string, isPinned = false): Promise<any> {
    return this.callTool<any>("ifolo_create_note", { content, title, is_pinned: isPinned });
  }

  public async appendNote(noteId: string, contentToAppend: string): Promise<any> {
    return this.callTool<any>("ifolo_append_note", {
      note_id: noteId,
      content_to_append: contentToAppend
    });
  }

  public rejectAllPending(err: Error): void {
    for (const [id, req] of this.pendingRequests.entries()) {
      clearTimeout(req.timer);
      req.reject(err);
    }
    this.pendingRequests.clear();
  }

  public destroy(): void {
    if (this.rl) {
      this.rl.close();
      this.rl = null;
    }
    this.rejectAllPending(new Error("Client destroyed"));
    this.connection.stop();
    this.initialized = false;
  }
}
