// node test/run.js — loads the plugin scripts against the mock Premiere DOM.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const assert = require("assert");
const { makeEnv } = require("./mock-ppro");

function load(env) {
  env.project.getActiveSequence = async () => env.sequence;
  const ctx = {
    console, setTimeout, clearTimeout, setInterval, clearInterval, Date, Math, JSON, Promise,
    require: (m) => (m === "premierepro" ? env.ppro : m === "uxp" ? { host: { version: "26.0.0" } } : null),
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  for (const f of ["premiere.js", "presets.js", "bridge.js"]) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "js", f), "utf8"), ctx, { filename: f });
  }
  return ctx.Cue;
}

const tests = [];
const same = (a, b, m) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b), m);
const test = (name, fn) => tests.push({ name, fn });
const param = (comp, name) => comp.params.find((p) => p.displayName === name);
const find = (clip, match) => clip.chain.components.filter((c) => c.matchName === match);

test("catalog lists effects, audio effects and transitions with categories", async () => {
  const env = makeEnv(); const Cue = load(env);
  const cat = await Cue.premiere.getCatalog();
  assert.strictEqual(cat.video.length, 2);
  assert.strictEqual(cat.video[0].name, "Gaussian Blur");
  assert.strictEqual(cat.video[0].category, "Blur & Sharpen");
  assert.strictEqual(cat.audio[0].category, "Filter & EQ");
  assert.strictEqual(cat.transitions[0].name, "Cross Dissolve");
  assert.strictEqual(cat.transitions[0].category, "Dissolve");
});

test("video effect applies to every selected clip in one undo step", async () => {
  const env = makeEnv(); const Cue = load(env);
  env.state.selection = [env.v1, env.v2, env.a1];
  const r = await Cue.premiere.applyVideoEffect({ matchName: "AE.ADBE Gaussian Blur 2", name: "Gaussian Blur" }, {});
  assert.strictEqual(r.applied, 2);
  assert.strictEqual(find(env.v1, "AE.ADBE Gaussian Blur 2").length, 1);
  assert.strictEqual(find(env.v2, "AE.ADBE Gaussian Blur 2").length, 1);
  assert.strictEqual(env.log.filter((l) => l.startsWith("TX")).length, 1);
});

test("falls back to the clip under the playhead when nothing is selected", async () => {
  const env = makeEnv(); const Cue = load(env);
  env.state.playhead = 5;
  const r = await Cue.premiere.applyVideoEffect({ matchName: "PR.ADBE Tint", name: "Tint" }, {});
  assert.ok(r.fromPlayhead);
  assert.strictEqual(find(env.v2, "PR.ADBE Tint").length, 1);
  assert.strictEqual(find(env.v1, "PR.ADBE Tint").length, 0);
});

test("no fallback → helpful error", async () => {
  const env = makeEnv(); const Cue = load(env);
  await assert.rejects(Cue.premiere.applyVideoEffect({ matchName: "PR.ADBE Tint", name: "Tint" }, { fallbackToPlayhead: false }), /Select at least one video clip/);
});

test("transition at both ends with custom duration", async () => {
  const env = makeEnv(); const Cue = load(env);
  env.state.selection = [env.v1];
  await Cue.premiere.applyTransition({ matchName: "AE.ADBE Cross Dissolve New", name: "Cross Dissolve" }, { transitionPosition: "both", transitionDuration: 0.5 });
  same(env.v1.transitions.map((t) => [t.start, t.dur]), [[true, 0.5], [false, 0.5]]);
});

async function buildSourceClip(env, Cue) {
  // Source: blur 0→40 keyframed (bezier on 2nd), tint static, Scale changed, Position default.
  env.state.selection = [env.v1];
  await Cue.premiere.applyVideoEffect({ matchName: "AE.ADBE Gaussian Blur 2", name: "Gaussian Blur" }, {});
  await Cue.premiere.applyVideoEffect({ matchName: "PR.ADBE Tint", name: "Tint" }, {});
  const blur = find(env.v1, "AE.ADBE Gaussian Blur 2")[0];
  const b = param(blur, "Blurriness");
  b._tv = true; b._kfs = [{ t: 10.0, v: 0, interp: 2 }, { t: 11.0, v: 40, interp: 0 }]; // clip in-point = 10s
  param(find(env.v1, "PR.ADBE Tint")[0], "Amount to Tint").__set = 55;
  param(find(env.v1, "PR.ADBE Tint")[0], "Amount to Tint")._value = 55;
  param(find(env.v1, "AE.ADBE Motion")[0], "Scale")._value = 120;
}

test("capture records effects, keyframes relative to in-point, and only changed fixed params", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = await Cue.presets.capturePreset("Punch blur");
  const blur = preset.components.find((c) => c.matchName === "AE.ADBE Gaussian Blur 2");
  const kfs = blur.params.find((p) => p.name === "Blurriness").keyframes;
  same(kfs.map((k) => [k.offset, k.value.v, k.interp]), [[0, 0, 2], [1, 40, 0]]);
  const motion = preset.components.find((c) => c.matchName === "AE.ADBE Motion");
  assert.ok(motion.enabled);
  assert.strictEqual(motion.params.find((p) => p.name === "Scale").enabled, true);
  assert.strictEqual(motion.params.find((p) => p.name === "Position").enabled, false);
  const opacity = preset.components.find((c) => c.matchName === "AE.ADBE Opacity");
  assert.strictEqual(opacity.enabled, false, "untouched Opacity stays off");
  const tint = preset.components.find((c) => c.matchName === "PR.ADBE Tint");
  same(tint.params[0].value, { t: "color", v: [0, 0, 0, 1] });
  // JSON round trip (the app stores it)
  JSON.parse(JSON.stringify(preset));
});

test("apply preset: appends effects, keyframes land at target in-point, interpolation restored", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = JSON.parse(JSON.stringify(await Cue.presets.capturePreset("Punch blur")));
  env.state.selection = [env.v2]; // in-point 2s, duration 6s
  const r = await Cue.presets.applyPreset(preset, {});
  assert.strictEqual(r.effectsAdded, 2);
  const blur = find(env.v2, "AE.ADBE Gaussian Blur 2")[0];
  const b = param(blur, "Blurriness");
  same(b._kfs.map((k) => [k.t, k.v, k.interp]), [[2, 0, 2], [3, 40, 0]]);
  assert.strictEqual(param(find(env.v2, "PR.ADBE Tint")[0], "Amount to Tint")._value, 55);
  assert.strictEqual(param(find(env.v2, "AE.ADBE Motion")[0], "Scale")._value, 120);
  same(param(find(env.v2, "AE.ADBE Motion")[0], "Position")._value, [0.5, 0.5]);
  assert.strictEqual(r.warnings.length, 0, r.warnings.join("; "));
});

test("apply preset never touches the target's own keyframes (preserve mode)", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = await Cue.presets.capturePreset("Punch blur");
  // Target already has keyframed Scale and its own blur with keyframes.
  env.state.selection = [env.v2];
  await Cue.premiere.applyVideoEffect({ matchName: "AE.ADBE Gaussian Blur 2", name: "Gaussian Blur" }, {});
  const own = find(env.v2, "AE.ADBE Gaussian Blur 2")[0];
  param(own, "Blurriness")._tv = true; param(own, "Blurriness")._kfs = [{ t: 2.5, v: 7, interp: 2 }];
  const scale = param(find(env.v2, "AE.ADBE Motion")[0], "Scale");
  scale._tv = true; scale._kfs = [{ t: 2, v: 80, interp: 2 }, { t: 4, v: 150, interp: 2 }];
  const before = JSON.stringify([scale._kfs, param(own, "Blurriness")._kfs]);

  const r = await Cue.presets.applyPreset(preset, {});
  assert.strictEqual(JSON.stringify([scale._kfs, param(own, "Blurriness")._kfs]), before);
  assert.strictEqual(r.paramsPreserved, 1);
  assert.strictEqual(find(env.v2, "AE.ADBE Gaussian Blur 2").length, 2, "preset blur is a new instance");
});

test("replace mode swaps keyframed fixed params for preset values", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = await Cue.presets.capturePreset("Punch blur");
  env.state.selection = [env.v2];
  const scale = param(find(env.v2, "AE.ADBE Motion")[0], "Scale");
  scale._tv = true; scale._kfs = [{ t: 2, v: 80, interp: 2 }];
  await Cue.presets.applyPreset(preset, { keyframeMode: "replace" });
  assert.strictEqual(scale._tv, false);
  assert.strictEqual(scale._value, 120);
});

test("duplicate=skip leaves existing effects alone", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = await Cue.presets.capturePreset("Punch blur");
  env.state.selection = [env.v1];
  const r = await Cue.presets.applyPreset(preset, { duplicateEffects: "skip" });
  assert.strictEqual(r.effectsSkipped, 2);
  assert.strictEqual(find(env.v1, "AE.ADBE Gaussian Blur 2").length, 1);
});

test("keyframe timing modes", async () => {
  const env = makeEnv(); const Cue = load(env);
  const k = { offset: 1, fraction: 0.25 };
  assert.strictEqual(Cue.presets.keyframeSeconds(k, "start", 8, 4), 1);
  assert.strictEqual(Cue.presets.keyframeSeconds(k, "stretch", 8, 4), 2);
  assert.strictEqual(Cue.presets.keyframeSeconds(k, "end", 8, 4), 5);
  assert.strictEqual(Cue.presets.keyframeSeconds({ offset: 0 }, "end", 2, 4), 0, "clamped");
});

test("one unwritable param doesn't sink the rest of the preset", async () => {
  const env = makeEnv(); const Cue = load(env);
  await buildSourceClip(env, Cue);
  const preset = await Cue.presets.capturePreset("Punch blur");
  env.state.selection = [env.v2];
  // Make Tint's Amount read-only on targets created from now on.
  const orig = env.ppro.VideoFilterFactory.createComponent;
  env.ppro.VideoFilterFactory.createComponent = async (m) => {
    const c = await orig(m);
    if (m === "PR.ADBE Tint") c.params[2]._settable = false;
    return c;
  };
  const r = await Cue.presets.applyPreset(preset, {});
  assert.strictEqual(r.paramsFailed, 1);
  assert.ok(r.warnings.some((w) => /Amount to Tint/.test(w)));
  assert.strictEqual(param(find(env.v2, "AE.ADBE Gaussian Blur 2")[0], "Blurriness")._kfs.length, 2);
});

test("audio preset applies to audio clips by display name", async () => {
  const env = makeEnv(); const Cue = load(env);
  env.state.selection = [env.a1];
  await Cue.premiere.applyAudioEffect({ matchName: "Parametric Equalizer", name: "Parametric Equalizer" }, {});
  const eq = env.a1.chain.components[1];
  eq.params[0]._value = -6;
  const preset = await Cue.presets.capturePreset("Phone EQ");
  const target = new env.ppro.AudioClipTrackItem("B.wav", 4, 8, 0);
  env.state.selection = [target];
  const r = await Cue.presets.applyPreset(preset, {});
  assert.strictEqual(r.effectsAdded, 1);
  assert.strictEqual(target.chain.components[1].params[0]._value, -6);
});

test("bridge answers requests in order and reports errors", async () => {
  const env = makeEnv(); const Cue = load(env);
  const sent = [];
  const b = new Cue.Bridge({ getSettings: () => ({}), onState() {}, log() {} });
  b.send = (m) => { sent.push(m); return true; };
  const order = [];
  b.on("slow", async () => { await new Promise((r) => setTimeout(r, 30)); order.push("slow"); return 1; });
  b.on("fast", async () => { order.push("fast"); return 2; });
  b.on("boom", async () => { throw new Cue.premiere.CueError("NO_TARGET", "nope"); });
  b.handle({ type: "request", id: "1", method: "slow" });
  b.handle({ type: "request", id: "2", method: "fast" });
  b.handle({ type: "request", id: "3", method: "boom" });
  b.handle({ type: "request", id: "4", method: "missing" });
  await b.queue;
  same(order, ["slow", "fast"]);
  same(sent.map((m) => [m.id, m.ok]), [["1", true], ["2", true], ["3", false], ["4", false]]);
  assert.strictEqual(sent[2].error.code, "NO_TARGET");
});

(async () => {
  let failed = 0;
  for (const t of tests) {
    try { await t.fn(); console.log(`✓ ${t.name}`); } catch (e) { failed++; console.log(`✗ ${t.name}\n   ${e.stack.split("\n").slice(0, 3).join("\n   ")}`); }
  }
  console.log(`\n${tests.length - failed}/${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
