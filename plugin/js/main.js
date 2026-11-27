/* Cue Bridge — panel UI and request handlers. */
(function (Cue) {
  "use strict";

  const STORE_KEY = "cue.bridge.settings";
  const DEFAULTS = { host: "localhost", port: 47821, token: "", autoConnect: true };

  function loadSettings() {
    try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(STORE_KEY) || "{}") }; } catch (_) { return { ...DEFAULTS }; }
  }
  function saveSettings(s) {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(s)); } catch (_) { /* ignore */ }
  }

  let settings = loadSettings();
  const $ = (id) => document.getElementById(id);

  // ---------------------------------------------------------------- logging

  function log(text, kind) {
    const list = $("log");
    if (!list) return;
    const row = document.createElement("div");
    row.className = `log-row ${kind || ""}`;
    const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    row.textContent = `${time}  ${text}`;
    list.insertBefore(row, list.firstChild);
    while (list.childNodes.length > 60) list.removeChild(list.lastChild);
  }

  // ------------------------------------------------------------------ state

  const STATE_TEXT = {
    idle: "Not connected",
    connecting: "Connecting…",
    open: "Pairing…",
    authed: "Connected",
    waiting: "Cue app not found — retrying",
    rejected: "Pairing code rejected",
  };

  function renderState(state, detail) {
    const dot = $("dot");
    dot.className = `dot ${state}`;
    let text = STATE_TEXT[state] || state;
    if (state === "waiting" && detail) text += ` in ${detail}s`;
    $("status").textContent = text;
    $("connect").textContent = state === "idle" || state === "rejected" ? "Connect" : "Disconnect";
    $("sync").disabled = state !== "authed";
    $("capture").disabled = state !== "authed";
  }

  const bridge = new Cue.Bridge({ getSettings: () => settings, onState: renderState, log });

  // --------------------------------------------------------------- handlers

  async function syncCatalog(reason) {
    const catalog = await Cue.premiere.getCatalog();
    bridge.emit("catalog", catalog);
    log(`Synced ${catalog.video.length} video effects, ${catalog.audio.length} audio effects, ${catalog.transitions.length} transitions${reason ? ` (${reason})` : ""}.`, "ok");
    return catalog;
  }

  bridge.on("__connected", () => { syncCatalog("on connect").catch((e) => log(`Sync failed: ${Cue.premiere.wrapError(e).message}`, "error")); });
  bridge.on("ping", async () => ({ pong: Date.now() }));
  bridge.on("catalog.get", async () => syncCatalog("requested by Cue"));
  bridge.on("status.get", async () => Cue.premiere.getStatus());
  bridge.on("preset.capture", async ({ name }) => {
    const preset = await Cue.presets.capturePreset(name);
    log(`Captured preset “${preset.name}” (${preset.components.filter((c) => c.enabled).length} effects).`, "ok");
    return preset;
  });
  bridge.on("apply", async ({ item, options, preset }) => {
    if (!item) throw new Cue.premiere.CueError("BAD_REQUEST", "Nothing to apply.");
    const opts = options || {};
    let result;
    switch (item.kind) {
      case "videoEffect": result = await Cue.premiere.applyVideoEffect(item, opts); break;
      case "audioEffect": result = await Cue.premiere.applyAudioEffect(item, opts); break;
      case "transition": result = await Cue.premiere.applyTransition(item, opts); break;
      case "preset": result = await Cue.presets.applyPreset(preset || item.preset, opts); break;
      default: throw new Cue.premiere.CueError("BAD_REQUEST", `Cue Bridge can't apply items of kind “${item.kind}”.`);
    }
    const n = result.applied != null ? result.applied : result.clips;
    log(`Applied ${item.name} → ${n} clip${n === 1 ? "" : "s"}${result.fromPlayhead ? " (under playhead)" : ""}.`, "ok");
    if (result.paramsPreserved) log(`Kept ${result.paramsPreserved} keyframed parameter${result.paramsPreserved === 1 ? "" : "s"} untouched.`);
    (result.warnings || []).slice(0, 5).forEach((w) => log(w, "warn"));
    return result;
  });

  // --------------------------------------------------------------------- UI

  function readForm() {
    settings = {
      ...settings,
      host: $("host").value.trim() || "localhost",
      port: parseInt($("port").value, 10) || DEFAULTS.port,
      token: $("token").value.trim().toUpperCase(),
    };
    saveSettings(settings);
  }

  function init() {
    $("host").value = settings.host;
    $("port").value = String(settings.port);
    $("token").value = settings.token;

    $("connect").addEventListener("click", () => {
      readForm();
      if (bridge.state === "idle" || bridge.state === "rejected") {
        settings.autoConnect = true;
        saveSettings(settings);
        bridge.start();
      } else {
        settings.autoConnect = false;
        saveSettings(settings);
        bridge.stop();
      }
    });

    ["host", "port", "token"].forEach((id) =>
      $(id).addEventListener("change", () => {
        readForm();
        if (bridge.state !== "idle") bridge.restart();
      })
    );

    $("sync").addEventListener("click", () => syncCatalog("manual").catch((e) => log(Cue.premiere.wrapError(e).message, "error")));

    $("capture").addEventListener("click", async () => {
      const name = $("presetName").value.trim();
      try {
        const preset = await Cue.presets.capturePreset(name);
        bridge.emit("preset.captured", preset);
        log(`Sent preset “${preset.name}” to Cue.`, "ok");
        $("presetName").value = "";
      } catch (e) {
        log(Cue.premiere.wrapError(e).message, "error");
      }
    });

    $("toggleSettings").addEventListener("click", () => {
      const box = $("settings");
      const show = box.classList.contains("hidden");
      box.classList.toggle("hidden", !show);
      $("toggleSettings").textContent = show ? "Hide connection" : "Connection…";
    });
    if (!settings.token) $("settings").classList.remove("hidden");

    renderState("idle");
    log(`Cue Bridge ${Cue.PLUGIN_VERSION} ready.`);
    if (settings.autoConnect) bridge.start();
  }

  const { entrypoints } = require("uxp");
  entrypoints.setup({
    panels: {
      cueBridgePanel: {
        show() { /* panel is static HTML; init runs once on load */ },
      },
    },
  });

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})(globalThis.Cue = globalThis.Cue || {});
