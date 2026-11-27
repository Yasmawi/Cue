// node test/e2e.js — boots the real panel scripts (with a tiny DOM stub and the
// mock Premiere DOM) against a WebSocket server that speaks the same protocol
// as the Cue Mac app's BridgeServer.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");
const { WebSocketServer } = require("ws");
const { makeEnv } = require("./mock-ppro");

const PORT = 47999;
const CODE = "K7Q2ZP";

function el(id) {
  const kids = [];
  return {
    id, value: "", textContent: "", disabled: false, className: "",
    childNodes: kids, firstChild: null, lastChild: null,
    classList: { _s: new Set(id === "settings" ? ["hidden"] : []), contains(c) { return this._s.has(c); }, toggle(c, on) { on ? this._s.add(c) : this._s.delete(c); }, remove(c) { this._s.delete(c); } },
    listeners: {},
    addEventListener(t, fn) { this.listeners[t] = fn; },
    insertBefore(n) { kids.unshift(n); this.firstChild = kids[0]; this.lastChild = kids[kids.length - 1]; },
    removeChild() { kids.pop(); this.lastChild = kids[kids.length - 1]; },
  };
}

function boot(env, settings) {
  env.project.getActiveSequence = async () => env.sequence;
  const els = {};
  const store = { "cue.bridge.settings": JSON.stringify(settings) };
  const ctx = {
    console, setTimeout, clearTimeout, setInterval, clearInterval, Date, Math, JSON, Promise,
    WebSocket: globalThis.WebSocket || require("ws").WebSocket,
    localStorage: { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; } },
    document: {
      readyState: "complete",
      getElementById: (id) => (els[id] = els[id] || el(id)),
      createElement: () => ({ className: "", textContent: "" }),
      addEventListener() {},
    },
    require: (m) => {
      if (m === "premierepro") return env.ppro;
      if (m === "uxp") return { host: { version: "26.0.0" }, entrypoints: { setup() {} } };
      return null;
    },
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  for (const f of ["premiere.js", "presets.js", "bridge.js", "main.js"]) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "js", f), "utf8"), ctx, { filename: f });
  }
  return { ctx, els };
}

// Minimal re-implementation of the Swift BridgeServer protocol.
function startServer() {
  const wss = new WebSocketServer({ port: PORT });
  const state = { events: [], peer: null, rejected: 0 };
  let n = 0;
  const pending = new Map();
  wss.on("connection", (ws, req) => {
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw);
      if (msg.type === "hello") {
        if (msg.token !== CODE) { state.rejected++; ws.send(JSON.stringify({ type: "rejected", message: "Wrong pairing code." })); return ws.close(); }
        state.peer = ws;
        state.hello = msg;
        ws.send(JSON.stringify({ type: "welcome", app: "Cue", version: "1.0.0", protocol: 1 }));
      } else if (msg.type === "event") {
        state.events.push(msg);
      } else if (msg.type === "response") {
        const p = pending.get(msg.id); pending.delete(msg.id); p && p(msg);
      } else if (msg.type === "ping") {
        ws.send(JSON.stringify({ type: "pong", t: msg.t }));
      }
    });
  });
  state.request = (method, params) => new Promise((resolve) => {
    const id = `r${++n}`;
    pending.set(id, resolve);
    state.peer.send(JSON.stringify({ type: "request", id, method, params }));
  });
  state.close = () => new Promise((r) => { wss.clients.forEach((c) => c.terminate()); wss.close(r); });
  return state;
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 3000) {
  const t0 = Date.now();
  while (!fn()) { if (Date.now() - t0 > ms) throw new Error("timed out"); await wait(20); }
}

(async () => {
  const server = startServer();

  // 1) wrong pairing code is refused and the plugin stops retrying
  {
    const env = makeEnv();
    const { ctx, els } = boot(env, { host: "localhost", port: PORT, token: "WRONG1", autoConnect: true });
    await until(() => server.rejected === 1);
    await wait(300);
    assert.strictEqual(els.status.textContent, "Pairing code rejected");
    assert.strictEqual(server.rejected, 1, "no retry loop after rejection");
    console.log("✓ wrong pairing code is rejected without a retry loop");
  }

  // 2) correct code → welcome → catalog event
  const env = makeEnv();
  const { ctx: panel, els } = boot(env, { host: "localhost", port: PORT, token: CODE.toLowerCase(), autoConnect: true });
  await until(() => server.events.some((e) => e.name === "catalog"));
  assert.strictEqual(server.hello.premiereVersion, "26.0.0");
  assert.strictEqual(server.hello.token, CODE, "token is upper-cased like the app expects");
  const cat = server.events.find((e) => e.name === "catalog").data;
  assert.strictEqual(cat.video.length, 2);
  assert.strictEqual(els.status.textContent, "Connected");
  console.log("✓ pairs, says hello, pushes the catalog on connect");

  // 3) status + apply round trips
  env.state.selection = [env.v1, env.a1];
  let r = await server.request("status.get", {});
  assert.deepStrictEqual([r.ok, r.result.videoSelected, r.result.audioSelected], [true, 1, 1]);
  r = await server.request("apply", { item: { kind: "videoEffect", id: "v:AE.ADBE Gaussian Blur 2", name: "Gaussian Blur", matchName: "AE.ADBE Gaussian Blur 2" }, options: {} });
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.result.applied, 1);
  console.log("✓ status.get and apply(videoEffect) round-trip");

  // 4) capture over the bridge, then apply the preset (as the app would send it back)
  env.v1.chain.components[2].params[0]._value = 25; // Blurriness on the blur we just added
  r = await server.request("preset.capture", { name: "Soft" });
  assert.strictEqual(r.ok, true);
  const preset = r.result;
  env.state.selection = [env.v2];
  r = await server.request("apply", { item: { kind: "preset", id: `p:${preset.id}`, name: "Soft", matchName: preset.id }, options: { keyframeMode: "preserve" }, preset });
  assert.strictEqual(r.ok, true, JSON.stringify(r.error));
  assert.strictEqual(env.v2.chain.components[2].params[0]._value, 25);
  console.log("✓ preset.capture → apply(preset) round-trip");

  // 5) errors come back as {ok:false,error:{code,message}}
  env.state.selection = [];
  env.state.playhead = 99;
  r = await server.request("apply", { item: { kind: "transition", id: "t:x", name: "Cross Dissolve", matchName: "AE.ADBE Cross Dissolve New" }, options: {} });
  assert.deepStrictEqual([r.ok, r.error.code], [false, "NO_TARGET"]);
  r = await server.request("nope", {});
  assert.strictEqual(r.error.code, "UNKNOWN_METHOD");
  console.log("✓ errors are reported with codes");

  // 6) panel "Capture" button sends a preset.captured event
  env.state.selection = [env.v1];
  panel.document.getElementById("presetName").value = "From panel";
  await els.capture.listeners.click();
  await until(() => server.events.some((e) => e.name === "preset.captured"));
  assert.strictEqual(server.events.find((e) => e.name === "preset.captured").data.name, "From panel");
  console.log("✓ panel capture button emits preset.captured");

  // 7) reconnects after the app restarts
  server.peer.terminate();
  await until(() => els.status.textContent.startsWith("Cue app not found") || els.status.textContent === "Connected", 4000);
  await until(() => els.status.textContent === "Connected", 6000);
  console.log("✓ reconnects automatically");

  await server.close();
  console.log("\nall e2e checks passed");
  process.exit(0);
})().catch((e) => { console.error("✗", e); process.exit(1); });
