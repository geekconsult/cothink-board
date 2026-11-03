import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const temp = mkdtempSync(join(tmpdir(), "cothink-pi-bridge-"));
const fake = join(temp, "mcp.mjs");
writeFileSync(fake, `#!/usr/bin/env node
let buffer = "";
const tools = [
  { name: "get_board", description: "Read board", inputSchema: { type: "object", properties: { board_id: { type: "string" } }, required: ["board_id"] } },
  { name: "get_board_context", description: "Read board context", inputSchema: { type: "object", properties: { board_id: { type: "string" } }, required: ["board_id"] } },
  { name: "capture_board", description: "Capture board", inputSchema: { type: "object", properties: { board_id: { type: "string" } }, required: ["board_id"] } },
  { name: "edit_board", description: "Edit board", inputSchema: { type: "object", properties: { board_id: { type: "string" }, expected_revision: { type: "integer" }, operations: { type: "array" } }, required: ["board_id", "expected_revision", "operations"] } },
  { name: "create_board", description: "Create board", inputSchema: { type: "object", properties: { title: { type: "string" } }, required: ["title"] } },
  { name: "list_board_lists", description: "List lists", inputSchema: { type: "object", properties: {} } },
];
process.stdin.setEncoding("utf8").on("data", chunk => {
  buffer += chunk;
  while (buffer.includes("\\n")) {
    const end = buffer.indexOf("\\n");
    const request = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    const send = result => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\\n");
    if (request.method === "initialize") { send({}); continue; }
    if (request.method === "tools/list") { send({ tools }); continue; }
    const args = request.params.arguments || {};
    if (args.crash) { process.exit(23); continue; }
    const result = { content: [{ type: "text", text: JSON.stringify(args) }] };
    if (args.delay) setTimeout(() => send(result), 600); else send(result);
  }
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
  assert.deepEqual([...tools.keys()].sort(), ["cothink_capture_board", "cothink_create_board", "cothink_edit_board", "cothink_get_board", "cothink_get_board_context", "cothink_list_board_lists"]);
  const getBoard = tools.get("cothink_get_board");
  assert.deepEqual(getBoard.parameters.required, []);
  assert.deepEqual(Object.keys(getBoard.parameters.properties), []);
  const editBoard = tools.get("cothink_edit_board");
  assert.deepEqual(editBoard.parameters.required, ["expected_revision", "operations"]);
  assert.deepEqual(Object.keys(editBoard.parameters.properties).sort(), ["expected_revision", "operations"]);
  const createBoard = tools.get("cothink_create_board");
  assert.deepEqual(createBoard.parameters.required, ["title"]);
  assert.deepEqual(Object.keys(createBoard.parameters.properties), ["title"]);
  const call = getBoard.execute;
  const controller = new AbortController();
  const start = Date.now();
  const cancelled = call("1", { delay: true }, controller.signal);
  setTimeout(() => controller.abort(), 30);
  await assert.rejects(cancelled, /dispatched board change may still complete/);
  assert(Date.now() - start < 400, "abort should not wait for the delayed MCP response");
  const result = await call("2", { board_id: "other" }, new AbortController().signal);
  assert.equal(JSON.parse(result.content[0].text).board_id, "board-one");
  assert.deepEqual(JSON.parse((await createBoard.execute("2b", { title: "My board" }, new AbortController().signal)).content[0].text), { title: "My board" });
  assert.deepEqual(JSON.parse((await tools.get("cothink_list_board_lists").execute("2c", {}, new AbortController().signal)).content[0].text), {});
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
