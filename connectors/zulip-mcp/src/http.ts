import { createServer as createHttpServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

const MAX_BODY_BYTES = 1_000_000;

function tokenMatches(header: string | undefined, expected: string): boolean {
  const presented = /^Bearer (.+)$/i.exec(header ?? "")?.[1];
  if (!presented) return false;
  const a = Buffer.from(presented);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new Error("request body too large");
    chunks.push(chunk as Buffer);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function send(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}): void {
  res.writeHead(status, { "Content-Type": "application/json", ...headers });
  res.end(JSON.stringify(body));
}

/**
 * Stateless Streamable HTTP endpoint at /mcp protected by a static bearer token.
 * A fresh MCP server + transport is created per request, so there is no session
 * state to leak between callers.
 */
export function startHttpServer(opts: {
  makeServer: () => McpServer;
  bearerToken: string;
  host: string;
  port: number;
}): Promise<Server> {
  const httpServer = createHttpServer(async (req, res) => {
    try {
      const path = new URL(req.url ?? "/", "http://localhost").pathname;
      if (path === "/healthz") return send(res, 200, { ok: true });
      if (path !== "/mcp") return send(res, 404, { error: "not found" });
      if (!tokenMatches(req.headers.authorization, opts.bearerToken)) {
        return send(res, 401, { error: "unauthorized" }, { "WWW-Authenticate": "Bearer" });
      }
      if (req.method !== "POST") {
        return send(res, 405, { jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null }, { Allow: "POST" });
      }
      const body = await readJson(req);
      const server = opts.makeServer();
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      res.on("close", () => {
        void transport.close();
        void server.close();
      });
      await server.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (e) {
      if (!res.headersSent) send(res, 400, { error: e instanceof Error ? e.message : "bad request" });
    }
  });
  return new Promise((resolve, reject) => {
    httpServer.once("error", reject);
    httpServer.listen(opts.port, opts.host, () => resolve(httpServer));
  });
}
