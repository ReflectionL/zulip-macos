import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { Config } from "./config.js";
import { registerTools } from "./tools.js";
import { ZulipClient } from "./zulip.js";

export function createServer(config: Config, zulip = new ZulipClient(config.credentials)): McpServer {
  const server = new McpServer({ name: "zulip", version: "0.1.0" });
  registerTools(server, config, zulip);
  return server;
}
