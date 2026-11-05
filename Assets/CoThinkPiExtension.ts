import { spawn } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, appendFileSync } from "node:fs";

type PendingEntry = { resolve: (value: any) => void; reject: (error: Error) => void; cleanup: () => void };

/** One JSON-RPC-over-stdio MCP child process with a pending-request table. */
class MCPChild {
  readonly child: any;
  private nextID = 1;
  private pending = new Map<number, PendingEntry>();
  private closed = false;
  private fatalFired = false;
  private errorText = "";

  private readonly onFatal: (error: Error) => void;

  constructor(command: string, args: string[], label: string, onFatal: (error: Error) => void) {
    this.onFatal = onFatal;
    this.child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"], env: process.env });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (text: string) => { this.errorText = (this.errorText + text).slice(-2048); });
    this.child.on("error", (error: Error) => this.fireFatal(new Error(`${label}: ${error.message}`)));
    this.child.on("close", (code: any, signal: any) => {
      if (this.closed) return;
      this.fireFatal(new Error(`${label} stopped (${code ?? signal ?? "unknown"}). ${this.errorText}`.trim()));
    });
    this.child.stdin.on("error", (error: Error) => this.fireFatal(new Error(`${label} input failed: ${error.message}`)));
    this.child.stdout.setEncoding("utf8");
    let output = "";
    this.child.stdout.on("data", (chunk: string) => {
      output += chunk;
      let end: number;
      while ((end = output.indexOf("\n")) >= 0) {
        const line = output.slice(0, end); output = output.slice(end + 1);
        let response: any;
        try { response = JSON.parse(line); } catch { this.fireFatal(new Error(`Invalid response from ${label}`)); this.child.kill(); return; }
        const item = this.pending.get(response.id);
        if (!item) continue;
        this.pending.delete(response.id); item.cleanup();
        if (response.error) item.reject(new Error(response.error.message || `${label} request failed`));
        else item.resolve(response.result);
      }
      if (output.length > 96_000_000) { this.fireFatal(new Error(`${label} response exceeded 96 MB`)); this.child.kill(); }
    });
  }

  get isClosed() { return this.closed; }

  private fireFatal(error: Error) {
    if (this.fatalFired) return;
    this.fatalFired = true;
    this.onFatal(error);
  }

  markClosed() { this.closed = true; }

  request(method: string, params: object, timeout = 120_000, signal?: AbortSignal): Promise<any> {
    if (this.closed) return Promise.reject(new Error(`${method} failed: child not running`));
    if (signal?.aborted) return Promise.reject(new Error("Cancelled"));
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const finishError = (error: Error) => {
        const item = this.pending.get(id);
        if (!item) return;
        this.pending.delete(id); item.cleanup(); reject(error);
      };
      const timer = setTimeout(() => finishError(new Error(`${method} timed out`)), timeout);
      const onAbort = () => finishError(new Error("Cancelled. A dispatched change may still complete; reread before retrying."));
      const cleanup = () => { clearTimeout(timer); signal?.removeEventListener("abort", onAbort); };
      this.pending.set(id, { resolve, reject, cleanup });
      signal?.addEventListener("abort", onAbort, { once: true });
      if (signal?.aborted) { onAbort(); return; }
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n", (error: Error | null) => {
        if (error) finishError(error);
      });
    });
  }

  shutdown() {
    this.closed = true;
    try { this.child.stdin.end(); } catch { }
    this.child.kill();
  }
}

function sanitizeToolPart(name: string): string {
  const cleaned = name.toLowerCase().replace(/[^a-z0-9_-]/g, "_").replace(/^_+|_+$/g, "");
  return cleaned || "tool";
}

export default async function (pi: any) {
  const memoryPath = process.env.COTHINK_MEMORY_PATH;
  const serversConfigPath = process.env.COTHINK_MCP_SERVERS_CONFIG;

  const shutdownChildren: MCPChild[] = [];
  let shuttingDown = false;

  // ---- Board memory tool: Pi can persist durable facts across chat sessions. ----
  if (memoryPath) {
    pi.registerTool({
      name: "cothink_memory",
      label: "CoThink memory",
      description: "Read or update this board's persistent agent memory. Memory content is loaded into the system prompt of every future chat session, so store durable facts, user preferences, and decisions here rather than repeating them.",
      parameters: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["read", "remember", "forget"], description: "read = show memory; remember = add a fact; forget = remove a matching line, or clear all memory when content is empty." },
          content: { type: "string", description: "For remember: the fact to store. For forget: text to match and remove; empty clears everything." },
        },
        required: ["action"],
      },
      async execute(_id: string, args: Record<string, unknown>) {
        const action = String(args.action || "read");
        const content = typeof args.content === "string" ? args.content.trim() : "";
        if (action === "read") {
          const text = existsSync(memoryPath) ? readFileSync(memoryPath, "utf8") : "";
          return { content: [{ type: "text", text: text.trim() || "(memory is empty)" }], details: {} };
        }
        if (action === "remember") {
          if (!content) throw new Error("Provide the fact to remember in content.");
          const date = new Date().toISOString().slice(0, 10);
          appendFileSync(memoryPath, `- ${date} ${content}\n`);
          return { content: [{ type: "text", text: `Remembered: ${content}` }], details: {} };
        }
        if (action === "forget") {
          if (!content) {
            writeFileSync(memoryPath, "");
            return { content: [{ type: "text", text: "Memory cleared." }], details: {} };
          }
          if (!existsSync(memoryPath)) return { content: [{ type: "text", text: "Memory is already empty." }], details: {} };
          const before = readFileSync(memoryPath, "utf8");
          const kept = before.split("\n").filter((line) => !line.includes(content));
          writeFileSync(memoryPath, kept.join("\n"));
          return { content: [{ type: "text", text: kept.length === before.split("\n").length ? `No memory line matched "${content}".` : `Removed lines matching "${content}".` }], details: {} };
        }
        throw new Error(`Unknown memory action: ${action}`);
      },
    });
  }

  // ---- External MCP servers from CoThink's MCP config file. ----
  let serverSpecs: any[] = [];
  if (serversConfigPath && existsSync(serversConfigPath)) {
    try {
      const parsed = JSON.parse(readFileSync(serversConfigPath, "utf8"));
      const section = parsed?.mcpServers || parsed?.mcp_servers || parsed?.servers || parsed;
      if (section && typeof section === "object") {
        for (const [name, spec] of Object.entries(section)) {
          if (spec && typeof spec === "object" && typeof (spec as any).command === "string" && (spec as any).command && (spec as any).enabled !== false) {
            serverSpecs.push({ name, spec });
          }
        }
      }
    } catch (error) {
      process.stderr.write(`COTHINK_MCP_SERVER_ERROR: config ${serversConfigPath}: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }

  // ---- Required CoThink board MCP bridge. ----
  const boardID = process.env.COTHINK_PI_BOARD_ID;
  const command = process.env.COTHINK_MCP_PATH;
  if (!boardID || !command) { process.stderr.write("COTHINK_MCP_ERROR: board ID or MCP executable is missing\n"); throw new Error("CoThink board ID or MCP executable is missing"); }

  let ready = false;
  const boardChild = new MCPChild(command, [], "CoThink MCP", (error: Error) => {
    if (ready && !shuttingDown) process.stderr.write(`COTHINK_MCP_ERROR: ${error.message}\n`);
  });

  // ---- Shared tool registration from one MCP child. ----
  async function bridgeChildTools(child: MCPChild, toolNamePrefix: string, toolLabelPrefix: string, boardScoped: boolean): Promise<string[]> {
    const listing = await child.request("tools/list", {}, 10_000);
    if (!Array.isArray(listing?.tools)) throw new Error("did not provide its tools");
    const registered: string[] = [];
    for (const tool of listing.tools) {
      let parameters = tool.inputSchema || { type: "object", properties: {} };
      let boardScopedTool = false;
      if (boardScoped && parameters?.properties?.board_id) {
        const properties = { ...parameters.properties };
        delete properties.board_id;
        parameters = { ...parameters, properties, required: (parameters.required || []).filter((name: string) => name !== "board_id") };
        boardScopedTool = true;
      }
      registered.push(tool.name);
      pi.registerTool({
        name: `${toolNamePrefix}${sanitizeToolPart(tool.name)}`,
        label: `${toolLabelPrefix} ${tool.name}`,
        description: boardScopedTool ? `${tool.description} This tool operates on the board currently open in CoThink.` : tool.description,
        parameters,
        async execute(_id: string, args: Record<string, unknown>, signal: AbortSignal) {
          if (signal.aborted) throw new Error("Cancelled");
          const arguments_ = boardScopedTool ? { ...args, board_id: boardID } : args;
          const result = await child.request("tools/call", { name: tool.name, arguments: arguments_ }, 120_000, signal);
          if (signal.aborted) throw new Error("Cancelled");
          const content = (result?.content || []).map((part: any) => {
            if (part.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string") return { type: "image", data: part.data, mimeType: part.mimeType };
            if (part.type === "text") return { type: "text", text: part.text };
            return { type: "text", text: JSON.stringify(part) };
          });
          if (result?.isError) throw new Error(content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n") || "MCP tool failed");
          return { content: content.length ? content : [{ type: "text", text: "Done." }], details: {} };
        },
      });
    }
    return registered;
  }

  // ---- Board MCP: required tools, readiness signal, per-call board ID injection. ----
  try {
    await boardChild.request("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "CoThink Pi chat", version: "2.0" } }, 10_000);
    const registered = await bridgeChildTools(boardChild, "cothink_", "CoThink", true);
    if (!["get_board", "get_board_context", "capture_board", "edit_board"].every((name) => registered.includes(name))) throw new Error("CoThink MCP is missing required board tools");
    ready = true;
    process.stderr.write("COTHINK_MCP_READY\n");
  } catch (error) {
    process.stderr.write(`COTHINK_MCP_ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
    boardChild.shutdown();
    throw error;
  }

  // ---- External MCP servers: bridge each one's tools with a per-server prefix. ----
  for (const { name, spec } of serverSpecs) {
    const child = new MCPChild(spec.command, spec.args || [], `MCP ${name}`, (error: Error) => {
      if (!shuttingDown) process.stderr.write(`COTHINK_MCP_SERVER_ERROR: ${name}: ${error.message}\n`);
    });
    shutdownChildren.push(child);
    try {
      await child.request("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "CoThink Pi chat", version: "2.0" } }, 10_000);
      const registered = await bridgeChildTools(child, `mcp_${sanitizeToolPart(name)}_`, name, false);
      process.stderr.write(`COTHINK_MCP_SERVER_READY: ${name}: ${registered.length} tools\n`);
    } catch (error) {
      child.shutdown();
      process.stderr.write(`COTHINK_MCP_SERVER_ERROR: ${name}: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }

  pi.on("session_shutdown", async () => {
    shuttingDown = true;
    boardChild.shutdown();
    for (const child of shutdownChildren) child.shutdown();
  });
}
