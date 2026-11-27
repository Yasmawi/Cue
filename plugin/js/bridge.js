/*
 * Cue Bridge — WebSocket link to the Cue macOS app.
 * The app is the server (UXP can only open client sockets); this side
 * connects, authenticates with the pairing code, then answers requests.
 */
(function (Cue) {
  "use strict";

  const PROTOCOL_VERSION = 1;
  const PLUGIN_VERSION = "1.0.0";

  class Bridge {
    constructor({ getSettings, onState, log }) {
      this.getSettings = getSettings;
      this.onState = onState || (() => {});
      this.log = log || (() => {});
      this.socket = null;
      this.state = "idle"; // idle | connecting | open | authed | error
      this.wanted = false;
      this.retry = 0;
      this.retryTimer = null;
      this.heartbeat = null;
      this.lastHeard = 0;
      this.queue = Promise.resolve();
      this.handlers = {};
    }

    on(method, fn) { this.handlers[method] = fn; }

    setState(state, detail) {
      this.state = state;
      this.onState(state, detail);
    }

    start() {
      this.wanted = true;
      this.retry = 0;
      this.open();
    }

    stop() {
      this.wanted = false;
      clearTimeout(this.retryTimer);
      clearInterval(this.heartbeat);
      if (this.socket) { try { this.socket.close(); } catch (_) { /* ignore */ } }
      this.socket = null;
      this.setState("idle");
    }

    restart() { this.stop(); this.start(); }

    open() {
      clearTimeout(this.retryTimer);
      const { host, port } = this.getSettings();
      const url = `ws://${host || "localhost"}:${port || 47821}/cue`;
      this.setState("connecting", url);
      let socket;
      try {
        socket = new WebSocket(url);
      } catch (e) {
        this.log(`Couldn't open ${url}: ${e.message || e}`, "error");
        return this.scheduleRetry();
      }
      this.socket = socket;

      socket.onopen = async () => {
        this.lastHeard = Date.now();
        this.setState("open");
        let premiereVersion = "";
        try { premiereVersion = require("uxp").host.version; } catch (_) { /* ignore */ }
        this.send({
          type: "hello",
          protocol: PROTOCOL_VERSION,
          plugin: "cue-bridge",
          version: PLUGIN_VERSION,
          premiereVersion,
          token: String(this.getSettings().token || "").trim().toUpperCase(),
        });
      };

      socket.onmessage = (ev) => {
        this.lastHeard = Date.now();
        let msg;
        try { msg = JSON.parse(ev.data); } catch (_) { return; }
        this.handle(msg);
      };

      socket.onerror = () => { /* onclose follows */ };

      socket.onclose = () => {
        clearInterval(this.heartbeat);
        if (this.socket === socket) this.socket = null;
        if (this.state === "authed") this.log("Disconnected from Cue.", "warn");
        if (this.wanted && this.state !== "rejected") this.scheduleRetry();
        else if (this.state !== "rejected") this.setState("idle");
      };
    }

    scheduleRetry() {
      if (!this.wanted) return;
      const delay = Math.min(10000, 750 * Math.pow(1.6, this.retry++));
      this.setState("waiting", Math.round(delay / 100) / 10);
      this.retryTimer = setTimeout(() => this.open(), delay);
    }

    send(obj) {
      if (!this.socket || this.socket.readyState !== 1) return false;
      this.socket.send(JSON.stringify(obj));
      return true;
    }

    emit(name, data) { return this.send({ type: "event", name, data }); }

    async handle(msg) {
      switch (msg.type) {
        case "welcome":
          this.retry = 0;
          this.setState("authed", msg.app || "Cue");
          this.log(`Connected to ${msg.app || "Cue"} ${msg.version || ""}`.trim(), "ok");
          clearInterval(this.heartbeat);
          this.heartbeat = setInterval(() => {
            if (Date.now() - this.lastHeard > 45000) {
              this.log("Cue stopped responding — reconnecting.", "warn");
              try { this.socket && this.socket.close(); } catch (_) { /* ignore */ }
              return;
            }
            this.send({ type: "ping", t: Date.now() });
          }, 15000);
          if (this.handlers.__connected) this.handlers.__connected();
          return;
        case "rejected":
          this.log(msg.message || "Cue rejected the pairing code.", "error");
          this.setState("rejected", msg.message);
          this.wanted = false;
          return;
        case "pong":
          return;
        case "request":
          // Run Premiere work strictly one request at a time so macros and
          // rapid key presses never interleave transactions.
          this.queue = this.queue.then(() => this.answer(msg));
          return;
        default:
          return;
      }
    }

    async answer(msg) {
      const fn = this.handlers[msg.method];
      if (!fn) {
        this.send({ type: "response", id: msg.id, ok: false, error: { code: "UNKNOWN_METHOD", message: `Unknown method ${msg.method}` } });
        return;
      }
      try {
        const result = await fn(msg.params || {});
        this.send({ type: "response", id: msg.id, ok: true, result: result === undefined ? null : result });
      } catch (e) {
        const error = Cue.premiere ? Cue.premiere.wrapError(e) : { code: "ERROR", message: String(e) };
        this.send({ type: "response", id: msg.id, ok: false, error });
      }
    }
  }

  Cue.Bridge = Bridge;
  Cue.PLUGIN_VERSION = PLUGIN_VERSION;
})(globalThis.Cue = globalThis.Cue || {});
