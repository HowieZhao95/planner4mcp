#!/usr/bin/env node
// Minimal MCP client: initialize -> tools/list -> tools/call, over stdio.
// Usage: node scripts/smoke.mjs [toolName] ['{"json":"args"}']

import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const proc = spawn("node", [resolve(root, "dist", "index.js")], {
  stdio: ["pipe", "pipe", "inherit"],
});

let buffer = "";
const pending = new Map();
let nextId = 1;

proc.stdout.setEncoding("utf8");
proc.stdout.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    const entry = pending.get(msg.id);
    if (entry) {
      pending.delete(msg.id);
      entry(msg);
    }
  }
});

function rpc(method, params) {
  const id = nextId++;
  return new Promise((res) => {
    pending.set(id, res);
    proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
  });
}

function notify(method, params) {
  proc.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
}

const init = await rpc("initialize", {
  protocolVersion: "2024-11-05",
  capabilities: {},
  clientInfo: { name: "smoke", version: "0" },
});
console.log("initialize:", JSON.stringify(init.result?.serverInfo));
notify("notifications/initialized", {});

const list = await rpc("tools/list", {});
const tools = list.result?.tools ?? [];
console.log(`tools/list: ${tools.length} tools`);
console.log(tools.map((t) => `  - ${t.name}`).join("\n"));

const toolName = process.argv[2];
if (toolName) {
  const args = process.argv[3] ? JSON.parse(process.argv[3]) : {};
  const out = await rpc("tools/call", { name: toolName, arguments: args });
  console.log(`\ntools/call ${toolName}:`);
  console.log(out.result?.content?.[0]?.text ?? JSON.stringify(out, null, 2));
  if (out.result?.isError) console.log("(isError = true)");
}

proc.kill();
process.exit(0);
