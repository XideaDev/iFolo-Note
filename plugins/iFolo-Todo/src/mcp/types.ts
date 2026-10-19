export interface MCPRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface MCPResponse<T = unknown> {
  jsonrpc: "2.0";
  id: number | string | null;
  result?: T;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export interface NoteMetadata {
  id: string;
  title: string;
  snippet: string;
  updatedAt: string | number;
  isPinned?: boolean;
  folderId?: string;
  hasTodo?: boolean;
  tags?: string[];
}

export interface SearchResultItem {
  id: string;
  title: string;
  score: number;
  snippet: string;
  matchedText: string;
  updatedAt: string;
}

export interface MCPToolDefinition {
  name: string;
  description: string;
  inputSchema: {
    type: string;
    properties: Record<string, unknown>;
    required?: string[];
  };
}

export type PluginResponse<T = unknown> = 
  | { ok: true; data: T; error?: never }
  | { ok: false; error: string; code?: string; data?: null };
