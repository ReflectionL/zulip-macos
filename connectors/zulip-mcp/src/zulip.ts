import type { ZulipCredentials } from "./config.js";

export interface ZulipChannel {
  stream_id: number;
  name: string;
  description?: string;
  invite_only?: boolean;
}

export interface ZulipTopic {
  name: string;
  max_id: number;
}

export interface ZulipMessage {
  id: number;
  type: "stream" | "private";
  sender_full_name: string;
  sender_email: string;
  timestamp: number;
  subject: string;
  stream_id?: number;
  display_recipient: string | Array<{ email: string; full_name: string }>;
  content: string;
  reactions?: Array<{ emoji_name: string; user_id: number }>;
}

export interface NarrowTerm {
  operator: string;
  operand: string | number | string[];
  negated?: boolean;
}

export class ZulipApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string | undefined,
    message: string,
  ) {
    super(message);
  }
}

type Fetch = typeof fetch;

export class ZulipClient {
  constructor(
    private readonly creds: ZulipCredentials,
    private readonly fetchImpl: Fetch = fetch,
  ) {}

  private async request<T>(
    method: "GET" | "POST",
    path: string,
    params: Record<string, string> = {},
  ): Promise<T> {
    const url = new URL(`/api/v1${path}`, this.creds.site);
    const headers: Record<string, string> = {
      Authorization: `Basic ${Buffer.from(`${this.creds.email}:${this.creds.apiKey}`).toString("base64")}`,
    };
    let body: URLSearchParams | undefined;
    if (method === "GET") {
      for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    } else {
      body = new URLSearchParams(params);
      headers["Content-Type"] = "application/x-www-form-urlencoded";
    }
    const res = await this.fetchImpl(url, { method, headers, body, signal: AbortSignal.timeout(20_000) });
    const json = (await res.json().catch(() => ({}))) as { result?: string; msg?: string; code?: string };
    if (!res.ok || json.result === "error") {
      // Zulip error messages never echo credentials.
      throw new ZulipApiError(res.status, json.code, json.msg ?? `Zulip returned HTTP ${res.status}`);
    }
    return json as T;
  }

  async whoami(): Promise<{ user_id: number; full_name: string; email: string; is_bot: boolean }> {
    return this.request("GET", "/users/me");
  }

  async listChannels(): Promise<ZulipChannel[]> {
    const r = await this.request<{ streams: ZulipChannel[] }>("GET", "/streams");
    return r.streams;
  }

  async listTopics(channelId: number): Promise<ZulipTopic[]> {
    const r = await this.request<{ topics: ZulipTopic[] }>("GET", `/users/me/${channelId}/topics`);
    return r.topics;
  }

  /**
   * Fetches messages ending at `anchor` (default: newest). Content is returned
   * as the author's raw Markdown (`apply_markdown=false`). Reading through the
   * API does not mark messages as read.
   */
  async getMessages(opts: {
    narrow: NarrowTerm[];
    limit: number;
    anchor?: number | "newest";
  }): Promise<{ messages: ZulipMessage[]; found_oldest: boolean }> {
    return this.request("GET", "/messages", {
      anchor: String(opts.anchor ?? "newest"),
      num_before: String(opts.limit),
      num_after: "0",
      narrow: JSON.stringify(opts.narrow),
      apply_markdown: "false",
      client_gravatar: "false",
      include_anchor: "false",
    });
  }

  async sendChannelMessage(channel: string, topic: string, content: string): Promise<number> {
    const r = await this.request<{ id: number }>("POST", "/messages", {
      type: "stream",
      to: channel,
      topic,
      content,
    });
    return r.id;
  }

  async sendDirectMessage(recipients: string[], content: string): Promise<number> {
    const r = await this.request<{ id: number }>("POST", "/messages", {
      type: "private",
      to: JSON.stringify(recipients),
      content,
    });
    return r.id;
  }

  async addReaction(messageId: number, emojiName: string): Promise<void> {
    await this.request("POST", `/messages/${messageId}/reactions`, { emoji_name: emojiName });
  }
}
