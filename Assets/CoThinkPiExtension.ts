import { spawn } from "node:child_process";

export default async function (pi: any) {
  const boardID = process.env.COTHINK_PI_BOARD_ID;
  const command = process.env.COTHINK_MCP_PATH;
  if (!boardID || !command) { process.stderr.write("COTHINK_MCP_ERROR: board ID or MCP executable is missing\n"); throw new Error("CoThink board ID or MCP executable is missing"); }

  const child = spawn(command, [], { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, COTHINK_MCP_ACTOR: process.env.COTHINK_MCP_ACTOR || "pi" } });
  let nextID = 1;
  let closed = false;
  let ready = false;
  let shuttingDown = false;
  let errorText = "";
  const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void; cleanup: () => void }>();
  const fail = (error: Error) => {
    if (closed) return;
    closed = true;
    if (ready && !shuttingDown) process.stderr.write(`COTHINK_MCP_ERROR: ${error.message}\n`);
    for (const item of pending.values()) { item.cleanup(); item.reject(error); }
    pending.clear();
  };
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (text: string) => { errorText = (errorText + text).slice(-2048); });
  child.on("error", (error) => fail(new Error(`Unable to start CoThink MCP: ${error.message}`)));
  child.on("close", (code, signal) => fail(new Error(`CoThink MCP stopped (${code ?? signal ?? "unknown"}). ${errorText}`)));
  child.stdin.on("error", (error) => fail(new Error(`CoThink MCP input failed: ${error.message}`)));
  child.stdout.setEncoding("utf8");
  let output = "";
  child.stdout.on("data", (chunk: string) => {
    output += chunk;
    let end: number;
    while ((end = output.indexOf("\n")) >= 0) {
      const line = output.slice(0, end); output = output.slice(end + 1);
      let response: any;
      try { response = JSON.parse(line); } catch { fail(new Error("Invalid response from CoThink MCP")); child.kill(); return; }
      const item = pending.get(response.id);
      if (!item) continue;
      pending.delete(response.id); item.cleanup();
      if (response.error) item.reject(new Error(response.error.message || "CoThink MCP request failed"));
      else item.resolve(response.result);
    }
    if (output.length > 96_000_000) { fail(new Error("CoThink MCP response exceeded 96 MB")); child.kill(); }
  });
  function request(method: string, params: object, timeout = 120_000, signal?: AbortSignal): Promise<any> {
    if (closed) return Promise.reject(new Error("CoThink MCP is not running"));
    if (signal?.aborted) return Promise.reject(new Error("Cancelled"));
    const id = nextID++;
    return new Promise((resolve, reject) => {
      const finishError = (error: Error) => {
        const item = pending.get(id);
        if (!item) return;
        pending.delete(id); item.cleanup(); reject(error);
      };
      const timer = setTimeout(() => finishError(new Error(`CoThink MCP ${method} timed out`)), timeout);
      const onAbort = () => finishError(new Error("Cancelled. A dispatched board change may still complete; reread the board before retrying."));
      const cleanup = () => { clearTimeout(timer); signal?.removeEventListener("abort", onAbort); };
      pending.set(id, { resolve, reject, cleanup });
      signal?.addEventListener("abort", onAbort, { once: true });
      if (signal?.aborted) { onAbort(); return; }
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n", (error) => {
        if (error) finishError(error);
      });
    });
  }
  try {
    await request("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "CoThink Pi chat", version: "1.0" } }, 10_000);
    const listing = await request("tools/list", {}, 10_000);
    if (!Array.isArray(listing?.tools)) throw new Error("CoThink MCP did not provide its tools");
    const registered = new Set<string>();
    for (const tool of listing.tools) {
      const properties = { ...(tool.inputSchema?.properties || {}) };
      const isBoardScoped = Object.hasOwn(properties, "board_id");
      if (isBoardScoped) delete properties.board_id;
      const required = (tool.inputSchema?.required || []).filter((name: string) => !isBoardScoped || name !== "board_id");
      registered.add(tool.name);
      pi.registerTool({
        name: `cothink_${tool.name}`,
        label: `CoThink ${tool.name}`,
        description: isBoardScoped ? `${tool.description} This tool operates on the board currently open in CoThink.` : tool.description,
        parameters: { ...tool.inputSchema, properties, required },
        async execute(_id: string, args: Record<string, unknown>, signal: AbortSignal) {
          if (signal.aborted) throw new Error("Cancelled");
          const arguments_ = isBoardScoped ? { ...args, board_id: boardID } : args;
          const result = await request("tools/call", { name: tool.name, arguments: arguments_ }, 120_000, signal);
          if (signal.aborted) throw new Error("Cancelled");
          const content = (result?.content || []).map((part: any) => {
            if (part.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string") return { type: "image", data: part.data, mimeType: part.mimeType };
            if (part.type === "text") return { type: "text", text: part.text };
            return { type: "text", text: JSON.stringify(part) };
          });
          if (result?.isError) throw new Error(content.filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n") || "CoThink MCP tool failed");
          return { content: content.length ? content : [{ type: "text", text: "Done." }], details: {} };
        },
      });
    }
    if (!["get_board", "get_board_context", "capture_board", "edit_board"].every((name) => registered.has(name))) throw new Error("CoThink MCP is missing required board tools");
    ready = true;
    process.stderr.write("COTHINK_MCP_READY\n");
  } catch (error) {
    process.stderr.write(`COTHINK_MCP_ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
    child.kill();
    throw error;
  }
  pi.on("session_shutdown", async () => { shuttingDown = true; child.stdin.end(); child.kill(); fail(new Error("CoThink session closed")); });
}
