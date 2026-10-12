#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { startHttpServer } from "./http.js";
import { createServer } from "./server.js";

// stdout carries the MCP protocol in stdio mode, so all logging goes to stderr.
const log = (msg: string): void => void process.stderr.write(`zulip-mcp: ${msg}\n`);

async function main(): Promise<void> {
  const config = loadConfig();
  const args = process.argv.slice(2);

  if (!args.includes("--http")) {
    await createServer(config).connect(new StdioServerTransport());
    log(`stdio ready (${config.write.enabled ? "writes ENABLED" : "read-only"})`);
    return;
  }

  const token = process.env["ZULIP_MCP_TOKEN"];
  if (!token || token.length < 32) {
    throw new Error("HTTP mode requires ZULIP_MCP_TOKEN (at least 32 characters), e.g. `openssl rand -hex 32`.");
  }
  const host = process.env["ZULIP_MCP_HOST"] ?? "127.0.0.1";
  const port = Number(process.env["ZULIP_MCP_PORT"] ?? 8787);
  await startHttpServer({ makeServer: () => createServer(config), bearerToken: token, host, port });
  log(`listening on http://${host}:${port}/mcp (${config.write.enabled ? "writes ENABLED" : "read-only"})`);
}

main().catch((e: unknown) => {
  log(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
