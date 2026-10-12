import { readFileSync } from "node:fs";

export interface ZulipCredentials {
  site: string;
  email: string;
  apiKey: string;
}

export interface WritePolicy {
  /** When false the write tools are not even registered. */
  enabled: boolean;
  /** If non-empty, channel posts are limited to these channels and DMs are refused. */
  channelAllowlist: string[];
}

export interface Config {
  credentials: ZulipCredentials;
  write: WritePolicy;
}

/** Parses the `[api]` section of a standard zuliprc file. */
export function parseZuliprc(text: string): Partial<ZulipCredentials> {
  const out: Record<string, string> = {};
  let inApi = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const section = /^\[(.+)\]$/.exec(line);
    if (section) {
      inApi = section[1] === "api";
      continue;
    }
    if (!inApi) continue;
    const eq = line.indexOf("=");
    if (eq > 0) out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return { site: out["site"], email: out["email"], apiKey: out["key"] };
}

export function normalizeSite(site: string): string {
  const url = new URL(site);
  if (url.protocol !== "https:" && !isLoopback(url.hostname)) {
    throw new Error("ZULIP_SITE must use https:// (http is only allowed for localhost)");
  }
  return url.origin;
}

function isLoopback(host: string): boolean {
  return host === "localhost" || host === "127.0.0.1" || host === "[::1]";
}

/**
 * Credentials come from the environment or a zuliprc file. They are never
 * logged and never part of any tool output.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const fromFile = env["ZULIP_RC"] ? parseZuliprc(readFileSync(env["ZULIP_RC"], "utf8")) : {};
  const site = env["ZULIP_SITE"] ?? fromFile.site;
  const email = env["ZULIP_EMAIL"] ?? fromFile.email;
  const apiKey = env["ZULIP_API_KEY"] ?? fromFile.apiKey;
  if (!site || !email || !apiKey) {
    throw new Error(
      "Missing Zulip credentials: set ZULIP_SITE, ZULIP_EMAIL and ZULIP_API_KEY, or point ZULIP_RC at a zuliprc file.",
    );
  }
  const allowlist = (env["ZULIP_MCP_WRITE_CHANNELS"] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    credentials: { site: normalizeSite(site), email, apiKey },
    write: { enabled: env["ZULIP_MCP_WRITE"] === "1", channelAllowlist: allowlist },
  };
}
