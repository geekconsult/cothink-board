import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const temp = mkdtempSync(join(tmpdir(), "cothink-pi-bridge-"));
const fake = join(temp, "mcp.mjs");
writeFileSync(fake, `#!/usr/bin/env node
import { createInterface } from "node:readline";
const names = ["get_board", "get_board_context", "capture_board", "edit_board"];
createInterface({ input: process.stdin }).on("line", line => {
  const request = JSON.parse(line);
  const send = result => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\\n");
  if (request.method === "initialize") return send({});
  if (request.method === "tools/list") return send({ tools: names.map(name => ({ name, description: name, inputSchema: { type: "object", properties: { board_id: { type: "string" } }, required: ["board_id"] } })) });
  const args = request.params.arguments;
  if (args.crash) return process.exit(23);
  const result = { content: [{ type: "text", text: JSON.stringify(args) }] };
  if (args.delay) setTimeout(() => send(result), 600); else send(result);
});
`);
chmodSync(fake, 0o755);
process.env.COTHINK_MCP_PATH = fake;
process.env.COTHINK_PI_BOARD_ID = "board-one";
const { default: load } = await import(pathToFileURL(resolve("Assets/CoThinkPiExtension.ts")).href);
const originalWrite = process.stderr.write.bind(process.stderr);
let stderr = "";
process.stderr.write = function (chunk, ...args) { stderr += String(chunk); return originalWrite(chunk, ...args); };
async function open() {
  const tools = new Map();
  let shutdown;
  await load({ registerTool(tool) { tools.set(tool.name, tool); }, on(name, handler) { if (name === "session_shutdown") shutdown = handler; } });
  return { tools, shutdown };
}
try {
  const { tools, shutdown } = await open();
  const call = tools.get("cothink_get_board").execute;
  const controller = new AbortController();
  const start = Date.now();
  const cancelled = call("1", { delay: true }, controller.signal);
  setTimeout(() => controller.abort(), 30);
  await assert.rejects(cancelled, /dispatched board change may still complete/);
  assert(Date.now() - start < 400, "abort should not wait for the delayed MCP response");
  const result = await call("2", { board_id: "other" }, new AbortController().signal);
  assert.equal(JSON.parse(result.content[0].text).board_id, "board-one");
  await new Promise(resolve => setTimeout(resolve, 700));
  await call("3", {}, new AbortController().signal);
  const errorCount = stderr.split("COTHINK_MCP_ERROR:").length - 1;
  await shutdown();
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(stderr.split("COTHINK_MCP_ERROR:").length - 1, errorCount, "intentional shutdown must not report an error");

  const crashed = await open();
  await assert.rejects(crashed.tools.get("cothink_get_board").execute("4", { crash: true }, new AbortController().signal), /stopped|input failed/);
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal(stderr.split("COTHINK_MCP_ERROR:").length - 1, errorCount + 1, "unexpected exit should report exactly one error");
  await crashed.shutdown();
  console.log("PASS abort, late response, board binding, continued requests, shutdown and unexpected exit");
} finally {
  process.stderr.write = originalWrite;
}
