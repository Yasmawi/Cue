/*
 * Cue Bridge — capture & apply presets.
 *
 * UXP has no API for applying native .prfpset presets, so Cue captures a
 * clip's effect stack (effects, parameter values, keyframes, interpolation)
 * into its own JSON preset and replays it through the component-chain API.
 *
 * Keyframe safety rules when applying:
 *  1. Effects from the preset are always APPENDED as new instances. Existing
 *     effects on the target clip (and their keyframes) are never modified.
 *  2. Fixed effects (Motion, Opacity, Volume…) can't be appended, so the
 *     preset writes into the clip's own instance. Any parameter the editor
 *     has already keyframed on the target is left alone in "preserve" mode
 *     (the default). "replace" mode clears those keyframes first.
 *  3. Preset keyframes are placed relative to the target clip's own in-point
 *     (keyframe times are clip-media time, not sequence time), using the
 *     chosen timing: from clip start, stretched to clip length, or anchored
 *     to clip end.
 */
(function (Cue) {
  "use strict";

  const P = Cue.premiere;
  const { ppro, CueError } = P;
  const C = ppro.Constants;

  const FORMAT = 1;

  // ------------------------------------------------------------ intrinsics

  function isIntrinsic(media, matchName, displayName) {
    const m = String(matchName || "");
    const d = String(displayName || "");
    if (media === "video") {
      return /(^|[.\s])(Motion|Opacity|Time Remapping)$/i.test(m) || /^(Motion|Opacity|Time Remapping)$/i.test(d);
    }
    return /(^|[.\s])(Volume|Channel Volume|Panner)$/i.test(m) || /^(Volume|Channel Volume|Panner)$/i.test(d);
  }

  function isTimeRemap(matchName, displayName) {
    return /Time Remap/i.test(`${matchName} ${displayName}`);
  }

  // Values Premiere starts fixed effects with. A captured fixed-effect
  // parameter is only switched on when it's keyframed or differs from these,
  // so a "blur" preset doesn't silently reset Position/Scale on the target.
  // Unknown parameters start switched off (you can enable them in the app).
  const FIXED_DEFAULTS = {
    "Position": [0.5, 0.5],
    "Anchor Point": [0.5, 0.5],
    "Scale": 100,
    "Scale Height": 100,
    "Scale Width": 100,
    "Uniform Scale": true,
    "Rotation": 0,
    "Anti-flicker Filter": 0,
    "Crop Left": 0,
    "Crop Top": 0,
    "Crop Right": 0,
    "Crop Bottom": 0,
    "Opacity": 100,
    "Bypass": false,
    "Balance": 0,
    "Pan": 0,
  };

  function differsFromDefault(name, encoded) {
    if (!(name in FIXED_DEFAULTS) || !encoded) return null; // unknown
    const d = FIXED_DEFAULTS[name];
    const v = encoded.v;
    if (Array.isArray(d)) return !(Array.isArray(v) && Math.abs(v[0] - d[0]) < 1e-4 && Math.abs(v[1] - d[1]) < 1e-4);
    if (typeof d === "number") return !(typeof v === "number" && Math.abs(v - d) < 1e-4);
    return v !== d;
  }

  // -------------------------------------------------------- value encoding

  const isColorLike = (o) => !!o && typeof o === "object" && ["red", "green", "blue"].every((k) => typeof o[k] === "number");

  function encodeValue(raw) {
    if (raw == null) return null;
    if (ppro.MogrtText && raw instanceof ppro.MogrtText) return null;
    if (ppro.MogrtComment && raw instanceof ppro.MogrtComment) return null;
    let v = raw;
    for (let i = 0; i < 2; i++) {
      if (isColorLike(v)) break;
      if (v && typeof v === "object" && !Array.isArray(v) && "value" in v) v = v.value;
    }
    if (isColorLike(v)) return { t: "color", v: [v.red, v.green, v.blue, typeof v.alpha === "number" ? v.alpha : 1] };
    if (Array.isArray(v) && v.length >= 2 && v.every((n) => typeof n === "number")) return { t: "point", v: [v[0], v[1]] };
    if (v && typeof v === "object" && typeof v.x === "number" && typeof v.y === "number") return { t: "point", v: [v.x, v.y] };
    if (typeof v === "number" && Number.isFinite(v)) return { t: "num", v };
    if (typeof v === "boolean") return { t: "bool", v };
    if (typeof v === "string") return { t: "str", v };
    return null;
  }

  function decodeValue(e) {
    switch (e && e.t) {
      case "num":
      case "bool":
      case "str":
        return e.v;
      case "point":
        return new ppro.PointF(e.v[0], e.v[1]);
      case "color":
        return new ppro.Color(e.v[0], e.v[1], e.v[2], e.v[3]);
      default:
        throw new CueError("BAD_VALUE", "Preset contains a value Cue can't write.");
    }
  }

  // --------------------------------------------------------------- capture

  async function describeChain(chain) {
    const n = chain.getComponentCount();
    const out = [];
    for (let i = 0; i < n; i++) {
      const component = chain.getComponentAtIndex(i);
      let matchName = "";
      let displayName = "";
      try { matchName = await component.getMatchName(); } catch (_) { /* ignore */ }
      try { displayName = await component.getDisplayName(); } catch (_) { /* ignore */ }
      out.push({ component, matchName, displayName });
    }
    return out;
  }

  async function captureParams(component, inPoint, duration, fixed) {
    const params = [];
    const count = component.getParamCount();
    for (let p = 0; p < count; p++) {
      let param;
      try { param = component.getParam(p); } catch (_) { continue; }
      const name = param.displayName || "";
      try {
        let entry = null;
        if (param.isTimeVarying()) {
          const times = param.getKeyframeListAsTickTimes() || [];
          const keyframes = [];
          for (const t of times) {
            let value = null;
            let interp = null;
            try {
              const kf = param.getKeyframePtr(t);
              value = encodeValue(kf);
              try { interp = await kf.getTemporalInterpolationMode(); } catch (_) { /* ignore */ }
            } catch (_) { /* fall through */ }
            if (!value) {
              try { value = encodeValue(await param.getValueAtTime(t)); } catch (_) { /* ignore */ }
            }
            if (!value) continue;
            const offset = t.seconds - inPoint.seconds;
            keyframes.push({ offset, fraction: duration > 0 ? offset / duration : 0, value, interp });
          }
          if (keyframes.length) entry = { index: p, name, value: keyframes[0].value, keyframes };
        } else {
          const value = encodeValue(await param.getStartValue());
          if (value) entry = { index: p, name, value };
        }
        if (!entry) continue;
        if (fixed) {
          const diff = differsFromDefault(name, entry.value);
          entry.enabled = !!entry.keyframes || diff === true;
        } else {
          entry.enabled = true;
        }
        params.push(entry);
      } catch (_) {
        // Group headers and unsupported param types throw; they're not data.
      }
    }
    return params;
  }

  async function capturePreset(name) {
    const { sequence } = await P.getContext();
    const selection = await sequence.getSelection();
    const items = (await selection.getTrackItems()) || [];
    const video = items.find(P.isVideoItem);
    const audio = items.find(P.isAudioItem);
    if (!video && !audio) throw new CueError("NO_TARGET", "Select the clip whose effects you want to capture.");

    const preset = {
      format: FORMAT,
      id: `p_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
      name: String(name || "").trim() || "Untitled preset",
      createdAt: new Date().toISOString(),
      media: {},
      components: [],
    };

    for (const [media, clip] of [["video", video], ["audio", audio]]) {
      if (!clip) continue;
      const inPoint = await clip.getInPoint();
      const duration = (await clip.getDuration()).seconds;
      let clipName = "";
      try { clipName = await clip.getName(); } catch (_) { /* ignore */ }
      preset.media[media] = { duration, clipName };

      const chain = await clip.getComponentChain();
      for (const { component, matchName, displayName } of await describeChain(chain)) {
        const intrinsic = isIntrinsic(media, matchName, displayName);
        const params = await captureParams(component, inPoint, duration, intrinsic);
        if (intrinsic && !params.length) continue;
        const enabled = intrinsic ? !isTimeRemap(matchName, displayName) && params.some((p) => p.enabled) : true;
        preset.components.push({ media, matchName, displayName, intrinsic, enabled, params });
      }
    }

    if (!preset.components.some((c) => c.enabled)) {
      throw new CueError("NOTHING_TO_CAPTURE", "That clip has no added effects or changed Motion/Opacity/Volume settings.");
    }
    return preset;
  }

  // ----------------------------------------------------------------- apply

  function keyframeSeconds(kf, mode, targetDuration, sourceDuration) {
    const src = sourceDuration > 0 ? sourceDuration : targetDuration;
    let s;
    if (mode === "stretch") {
      const fraction = typeof kf.fraction === "number" ? kf.fraction : src > 0 ? kf.offset / src : 0;
      s = fraction * targetDuration;
    } else if (mode === "end") {
      s = targetDuration - (src - kf.offset);
    } else {
      s = kf.offset;
    }
    return Math.max(0, s);
  }

  function resolveParam(component, spec) {
    const count = component.getParamCount();
    if (spec.index < count) {
      const p = component.getParam(spec.index);
      if (!spec.name || !p.displayName || p.displayName === spec.name) return p;
    }
    for (let i = 0; i < count; i++) {
      const p = component.getParam(i);
      if (p.displayName === spec.name) return p;
    }
    return null;
  }

  /**
   * Commits groups of actions as one undo step. Each group's actions are built
   * lazily inside the project lock. If Premiere rejects the batch, retries one
   * group at a time so a single bad parameter can't sink the whole preset.
   */
  function commitGroups(project, label, groups, report) {
    const live = groups.filter((g) => !g.failed);
    if (!live.length) return;
    const build = (g) => {
      try {
        return g.make() || [];
      } catch (e) {
        g.failed = true;
        report.warnings.push(`Couldn't set "${g.name}": ${P.wrapError(e).message}`);
        return [];
      }
    };
    try {
      P.transact(project, label, () => live.flatMap(build));
      return;
    } catch (_) { /* fall back below */ }
    for (const g of live) {
      if (g.failed) continue;
      try {
        P.transact(project, label, () => build(g));
      } catch (e) {
        g.failed = true;
        report.warnings.push(`Couldn't set "${g.name}": ${P.wrapError(e).message}`);
      }
    }
  }

  async function applyToClip(project, preset, media, clip, options, report) {
    const applyFixed = options.applyFixedEffects !== false;
    const specs = (preset.components || []).filter(
      (c) => c.media === media && c.enabled !== false && (!c.intrinsic || applyFixed)
    );
    if (!specs.length) return;
    report.clips++;

    const inPoint = await clip.getInPoint();
    const targetDuration = (await clip.getDuration()).seconds;
    const sourceDuration = (preset.media && preset.media[media] && preset.media[media].duration) || targetDuration;
    const mode = options.keyframeMode === "replace" ? "replace" : "preserve";
    const timing = options.keyframeTiming || "start";

    // Phase 1 — append fresh effect instances.
    let chain = await clip.getComponentChain();
    const existing = await describeChain(chain);
    const additions = [];
    for (const spec of specs.filter((s) => !s.intrinsic)) {
      if (options.duplicateEffects === "skip" && existing.some((e) => e.matchName === spec.matchName)) {
        report.effectsSkipped++;
        continue;
      }
      try {
        const component = media === "video"
          ? await ppro.VideoFilterFactory.createComponent(spec.matchName)
          : await ppro.AudioFilterFactory.createComponentByDisplayName(spec.displayName, clip);
        additions.push({ spec, component });
      } catch (_) {
        report.warnings.push(`"${spec.displayName || spec.matchName}" isn't available in this Premiere install.`);
      }
    }
    if (additions.length) {
      P.transact(project, `Cue: ${preset.name}`, () => additions.map((a) => chain.createAppendComponentAction(a.component)));
      report.effectsAdded += additions.length;
    }

    // Phase 2 — bind preset entries to live components.
    chain = await clip.getComponentChain();
    const live = await describeChain(chain);
    const used = new Set();
    const bindings = [];
    additions.forEach((a, i) => {
      let idx = existing.length + i;
      if (!live[idx] || live[idx].matchName !== a.spec.matchName || used.has(idx)) {
        idx = -1;
        for (let j = live.length - 1; j >= 0; j--) {
          if (!used.has(j) && live[j].matchName === a.spec.matchName) { idx = j; break; }
        }
      }
      if (idx >= 0) { used.add(idx); bindings.push({ spec: a.spec, component: live[idx].component, fresh: true }); }
    });
    for (const spec of specs.filter((s) => s.intrinsic)) {
      let idx = live.findIndex((l, j) => !used.has(j) && l.matchName === spec.matchName);
      if (idx < 0) idx = live.findIndex((l, j) => !used.has(j) && l.displayName === spec.displayName);
      if (idx >= 0) { used.add(idx); bindings.push({ spec, component: live[idx].component, fresh: false }); }
    }

    // Phase 3 — plan parameter writes.
    const plan = [];
    for (const b of bindings) {
      for (const ps of b.spec.params || []) {
        if (ps.enabled === false) continue;
        let param;
        try { param = resolveParam(b.component, ps); } catch (_) { param = null; }
        if (!param) { report.paramsFailed++; continue; }
        let keyed = false;
        try { keyed = param.isTimeVarying(); } catch (_) { /* ignore */ }
        if (!b.fresh && keyed && mode === "preserve") { report.paramsPreserved++; continue; }
        plan.push({ param, spec: ps, keyed, label: `${b.spec.displayName} › ${ps.name}` });
      }
    }
    if (!plan.length) return;

    // 3a — clear keyframes being replaced (stopwatch off removes them).
    commitGroups(project, `Cue: ${preset.name}`, plan.filter((p) => p.keyed).map((p) => ({
      name: p.label, make: () => [p.param.createSetTimeVaryingAction(false)],
    })), report);

    // 3b — switch on keyframing where the preset animates.
    const animated = plan.filter((p) => p.spec.keyframes && p.spec.keyframes.length);
    commitGroups(project, `Cue: ${preset.name}`, animated.map((p) => ({
      name: p.label, make: () => [p.param.createSetTimeVaryingAction(true)],
    })), report);

    // 3c — write values and keyframes.
    const at = (kf) => inPoint.add(ppro.TickTime.createWithSeconds(keyframeSeconds(kf, timing, targetDuration, sourceDuration)));
    const valueGroups = plan.map((p) => ({
      name: p.label,
      ref: p,
      make: () => {
        if (p.spec.keyframes && p.spec.keyframes.length) {
          return p.spec.keyframes.map((kf) => {
            const k = p.param.createKeyframe(decodeValue(kf.value));
            k.position = at(kf);
            return p.param.createAddKeyframeAction(k);
          });
        }
        const k = p.param.createKeyframe(decodeValue(p.spec.value));
        return [p.param.createSetValueAction(k, true)];
      },
    }));
    commitGroups(project, `Cue: ${preset.name}`, valueGroups, report);
    for (const g of valueGroups) {
      if (g.failed) { report.paramsFailed++; continue; }
      report.paramsSet++;
      if (g.ref.spec.keyframes) report.keyframesAdded += g.ref.spec.keyframes.length;
    }

    // 3d — restore interpolation (hold / bezier / …). Ease handles aren't in the API yet.
    const interp = [];
    for (const g of valueGroups) {
      if (g.failed || !g.ref.spec.keyframes) continue;
      for (const kf of g.ref.spec.keyframes) {
        if (kf.interp != null && kf.interp !== C.InterpolationMode.LINEAR) interp.push({ p: g.ref, kf });
      }
    }
    commitGroups(project, `Cue: ${preset.name}`, interp.map((x) => ({
      name: x.p.label, make: () => [x.p.param.createSetInterpolationAtKeyframeAction(at(x.kf), x.kf.interp, true)],
    })), report);
  }

  async function applyPreset(preset, options) {
    options = options || {};
    if (!preset || !Array.isArray(preset.components)) throw new CueError("BAD_PRESET", "Preset data is missing or damaged.");
    const { project, sequence } = await P.getContext();
    const fallback = options.fallbackToPlayhead !== false;
    const wants = (m) => preset.components.some((c) => c.media === m && c.enabled !== false);
    const video = wants("video") ? await P.resolveTargets(sequence, "video", fallback) : { items: [] };
    const audio = wants("audio") ? await P.resolveTargets(sequence, "audio", fallback) : { items: [] };
    if (!video.items.length && !audio.items.length) {
      throw new CueError("NO_TARGET", "Select the clips to apply the preset to (or park the playhead over one).");
    }
    const report = {
      clips: 0, effectsAdded: 0, effectsSkipped: 0, paramsSet: 0, paramsPreserved: 0,
      paramsFailed: 0, keyframesAdded: 0, warnings: [],
    };
    for (const clip of video.items) await applyToClip(project, preset, "video", clip, options, report);
    for (const clip of audio.items) await applyToClip(project, preset, "audio", clip, options, report);
    report.applied = report.clips;
    return report;
  }

  Cue.presets = { capturePreset, applyPreset, encodeValue, decodeValue, keyframeSeconds, isIntrinsic, FORMAT };
})(globalThis.Cue = globalThis.Cue || {});
