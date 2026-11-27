/*
 * Cue Bridge — Premiere operations.
 * Everything that touches the Premiere DOM lives here (and in presets.js),
 * so the rest of the plugin stays testable.
 */
(function (Cue) {
  "use strict";

  const ppro = require("premierepro");
  const C = ppro.Constants;

  // ---------------------------------------------------------------- errors

  class CueError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }

  function wrapError(e) {
    if (e instanceof CueError) return { code: e.code, message: e.message };
    return { code: "PREMIERE_ERROR", message: String((e && e.message) || e) };
  }

  // --------------------------------------------------------------- helpers

  const isVideoItem = (t) => !!ppro.VideoClipTrackItem && t instanceof ppro.VideoClipTrackItem;
  const isAudioItem = (t) => !!ppro.AudioClipTrackItem && t instanceof ppro.AudioClipTrackItem;

  async function getContext() {
    const project = await ppro.Project.getActiveProject();
    if (!project) throw new CueError("NO_PROJECT", "No project is open in Premiere.");
    const sequence = await project.getActiveSequence();
    if (!sequence) throw new CueError("NO_SEQUENCE", "Open a sequence in the timeline first.");
    return { project, sequence };
  }

  /**
   * Runs one undoable transaction. `build` is called synchronously while the
   * project is locked and must return an array of Actions.
   * Returns the number of actions committed (0 means nothing to do).
   */
  function transact(project, label, build) {
    let ok = false;
    let count = 0;
    let failure = null;
    project.lockedAccess(() => {
      try {
        const actions = (build() || []).filter(Boolean);
        count = actions.length;
        if (!count) { ok = true; return; }
        ok = project.executeTransaction((compound) => {
          for (const a of actions) compound.addAction(a);
        }, label);
      } catch (e) {
        failure = e;
      }
    });
    if (failure) throw failure;
    if (!ok) throw new CueError("TRANSACTION_FAILED", `Premiere rejected "${label}".`);
    return count;
  }

  async function getTrackItems(track) {
    // Typed as sync in some versions and async in others; await handles both.
    const items = await track.getTrackItems(C.TrackItemType.CLIP, false);
    return items || [];
  }

  async function clipsUnderPlayhead(sequence, media) {
    const pos = await sequence.getPlayerPosition();
    const at = pos.seconds;
    const hits = [];
    const covers = async (item) => {
      const s = (await item.getStartTime()).seconds;
      const e = (await item.getEndTime()).seconds;
      return at >= s - 1e-6 && at < e - 1e-6;
    };
    if (media === "video") {
      const n = await sequence.getVideoTrackCount();
      // Topmost track first: that's the clip you see in the Program monitor.
      for (let i = n - 1; i >= 0; i--) {
        const track = await sequence.getVideoTrack(i);
        for (const item of await getTrackItems(track)) {
          if (await covers(item)) { hits.push(item); break; }
        }
        if (hits.length) break;
      }
    } else {
      const n = typeof sequence.getAudioTrackCount === "function" ? await sequence.getAudioTrackCount() : 0;
      for (let i = 0; i < n; i++) {
        const track = await sequence.getAudioTrack(i);
        for (const item of await getTrackItems(track)) {
          if (await covers(item)) { hits.push(item); break; }
        }
        if (hits.length) break;
      }
    }
    return hits;
  }

  /**
   * Clips to act on. Uses the timeline selection; when nothing of the right
   * media type is selected and `fallbackToPlayhead` is on, uses the clip under
   * the playhead (topmost video track / lowest audio track).
   */
  async function resolveTargets(sequence, media, fallbackToPlayhead) {
    const selection = await sequence.getSelection();
    const items = (await selection.getTrackItems()) || [];
    const wanted = items.filter(media === "video" ? isVideoItem : isAudioItem);
    if (wanted.length || !fallbackToPlayhead) return { items: wanted, fromPlayhead: false };
    return { items: await clipsUnderPlayhead(sequence, media), fromPlayhead: true };
  }

  function requireTargets(targets, media) {
    if (!targets.items.length) {
      throw new CueError(
        "NO_TARGET",
        media === "video"
          ? "Select at least one video clip (or park the playhead over one)."
          : "Select at least one audio clip (or park the playhead over one)."
      );
    }
  }

  // ---------------------------------------------------------------- catalog

  function prettify(matchName) {
    return String(matchName)
      .replace(/^(AE|PR|ADBE)\./, "")
      .replace(/^ADBE\s+/, "")
      .replace(/\s+New$/, "")
      .replace(/([a-z])([A-Z])/g, "$1 $2")
      .replace(/_/g, " ")
      .trim();
  }

  // Premiere doesn't expose its Effects-panel bins to UXP, so we derive a
  // useful grouping from names. Anything unknown lands in the media default.
  const CATEGORY_RULES = [
    [/lumetri|color|colour|tint|curve|level|balance|hue|saturat|gamma|brightness|contrast|lut|channel mixer|equaliz|leave color|change to color|proc amp|three-way/i, "Color"],
    [/blur|sharpen|unsharp|defocus|bokeh/i, "Blur & Sharpen"],
    [/key|matte|chroma|luma|track matte|garbage|mask/i, "Keying"],
    [/distort|warp|twirl|wave|spherize|lens|magnify|mirror|bend|turbulent|ripple|corner pin|offset|stabiliz|rolling shutter|transform|crop|flip|edge feather/i, "Distort & Transform"],
    [/noise|grain|dust|scratch|median/i, "Noise & Grain"],
    [/glow|flare|lighting|light|emboss|mosaic|posterize|find edges|roughen|strobe|texture|solarize|replicate|brush|cartoon|stylize|invert/i, "Stylize"],
    [/time|echo|posterize time|frame/i, "Time"],
    [/generate|gradient|ramp|grid|circle|ellipse|4-color|cell|checker|lightning|fill|render|write-on/i, "Generate"],
    [/text|caption|title|timecode|clip name/i, "Text & Overlay"],
    [/immersive|vr /i, "Immersive"],
    [/audio|reverb|delay|eq|equali|compress|limit|gate|de-?ess|de-?noise|denoise|dereverb|hum|chorus|flanger|phaser|pitch|vocal|loudness|amplify|bass|treble|volume|pan|balance|fill left|fill right|swap|invert|notch|band|pass|filter|distortion|tube|guitar|mastering|dynamics|multiband/i, "Audio"],
  ];

  function categorize(name, matchName, fallback) {
    const hay = `${name} ${matchName}`;
    for (const [re, cat] of CATEGORY_RULES) {
      if (cat === "Audio") continue;
      if (re.test(hay)) return cat;
    }
    return fallback;
  }

  function categorizeAudio(name) {
    const n = name.toLowerCase();
    if (/reverb|delay|echo|chorus|flanger|phaser/.test(n)) return "Reverb & Delay";
    if (/eq|equali|pass|notch|band|filter|bass|treble/.test(n)) return "Filter & EQ";
    if (/compress|limit|gate|dynamics|loudness|amplify|hard limiter|multiband|tube/.test(n)) return "Amplitude & Dynamics";
    if (/noise|hum|de-?ess|dereverb|restor|click|declick/.test(n)) return "Noise Reduction";
    if (/pitch|vocal|voice/.test(n)) return "Voice & Pitch";
    if (/channel|pan|fill|swap|balance|binaural|panner/.test(n)) return "Channels";
    return "Audio Effects";
  }

  async function getCatalog() {
    const out = { video: [], audio: [], transitions: [] };
    const seen = new Set();
    const push = (list, item) => {
      if (seen.has(item.id)) return;
      seen.add(item.id);
      list.push(item);
    };

    const vMatch = (await ppro.VideoFilterFactory.getMatchNames()) || [];
    let vDisplay = [];
    try { vDisplay = (await ppro.VideoFilterFactory.getDisplayNames()) || []; } catch (_) { /* older builds */ }
    const aligned = vDisplay.length === vMatch.length;
    vMatch.forEach((m, i) => {
      const name = (aligned && vDisplay[i]) || prettify(m);
      push(out.video, { kind: "videoEffect", id: `v:${m}`, matchName: m, name, category: categorize(name, m, "Video Effects") });
    });

    let aDisplay = [];
    try { aDisplay = (await ppro.AudioFilterFactory.getDisplayNames()) || []; } catch (_) { /* ignore */ }
    aDisplay.forEach((n) => push(out.audio, { kind: "audioEffect", id: `a:${n}`, matchName: n, name: n, category: categorizeAudio(n) }));

    let tMatch = [];
    try { tMatch = (await ppro.TransitionFactory.getVideoTransitionMatchNames()) || []; } catch (_) { /* ignore */ }
    tMatch.forEach((m) => {
      const name = prettify(m);
      push(out.transitions, { kind: "transition", id: `t:${m}`, matchName: m, name, category: transitionCategory(name) });
    });

    let hostVersion = "";
    try { hostVersion = require("uxp").host.version; } catch (_) { /* ignore */ }
    return { ...out, premiereVersion: hostVersion, generatedAt: new Date().toISOString() };
  }

  function transitionCategory(name) {
    const n = name.toLowerCase();
    if (/dissolve|dip|fade|film/.test(n)) return "Dissolve";
    if (/wipe|band|barn|checker|clock|gradient|inset|paint|pinwheel|radial|random|spiral|venetian|wedge|zig/.test(n)) return "Wipe";
    if (/slide|push|split|center|band slide/.test(n)) return "Slide";
    if (/zoom|cross zoom/.test(n)) return "Zoom";
    if (/iris|cross|diamond|box|round/.test(n)) return "Iris";
    if (/page|peel/.test(n)) return "Page Peel";
    if (/morph/.test(n)) return "Morph";
    if (/immersive|vr/.test(n)) return "Immersive";
    if (/flip|cube|spin|swing|3d/.test(n)) return "3D Motion";
    return "Transitions";
  }

  // ------------------------------------------------------------- applying

  async function applyVideoEffect(item, options) {
    const { project, sequence } = await getContext();
    const targets = await resolveTargets(sequence, "video", options.fallbackToPlayhead !== false);
    requireTargets(targets, "video");
    const pairs = [];
    for (const clip of targets.items) {
      const chain = await clip.getComponentChain();
      let component;
      try {
        component = await ppro.VideoFilterFactory.createComponent(item.matchName);
      } catch (e) {
        throw new CueError("UNKNOWN_EFFECT", `Premiere couldn't create "${item.name}" (${item.matchName}).`);
      }
      pairs.push({ chain, component });
    }
    transact(project, `Cue: ${item.name}`, () => pairs.map((p) => p.chain.createAppendComponentAction(p.component)));
    return { applied: pairs.length, fromPlayhead: targets.fromPlayhead };
  }

  async function applyAudioEffect(item, options) {
    const { project, sequence } = await getContext();
    const targets = await resolveTargets(sequence, "audio", options.fallbackToPlayhead !== false);
    requireTargets(targets, "audio");
    const pairs = [];
    for (const clip of targets.items) {
      const chain = await clip.getComponentChain();
      let component;
      try {
        component = await ppro.AudioFilterFactory.createComponentByDisplayName(item.matchName || item.name, clip);
      } catch (e) {
        throw new CueError("UNKNOWN_EFFECT", `Premiere couldn't create audio effect "${item.name}".`);
      }
      pairs.push({ chain, component });
    }
    transact(project, `Cue: ${item.name}`, () => pairs.map((p) => p.chain.createAppendComponentAction(p.component)));
    return { applied: pairs.length, fromPlayhead: targets.fromPlayhead };
  }

  async function applyTransition(item, options) {
    const { project, sequence } = await getContext();
    const targets = await resolveTargets(sequence, "video", options.fallbackToPlayhead !== false);
    requireTargets(targets, "video");
    const where = options.transitionPosition || "end"; // "start" | "end" | "both"
    const ends = where === "both" ? [true, false] : [where === "start"];
    const duration = Number(options.transitionDuration) > 0 ? Number(options.transitionDuration) : 0;

    const plan = [];
    for (const clip of targets.items) {
      for (const toStart of ends) {
        let transition;
        try {
          transition = await ppro.TransitionFactory.createVideoTransition(item.matchName);
        } catch (e) {
          throw new CueError("UNKNOWN_TRANSITION", `Premiere couldn't create "${item.name}".`);
        }
        const opts = ppro.AddTransitionOptions();
        opts.setApplyToStart(toStart);
        if (duration) opts.setDuration(ppro.TickTime.createWithSeconds(duration));
        if (options.transitionSingleSided) opts.setForceSingleSided(true);
        plan.push({ clip, transition, opts });
      }
    }
    transact(project, `Cue: ${item.name}`, () => plan.map((p) => p.clip.createAddVideoTransitionAction(p.transition, p.opts)));
    return { applied: plan.length, fromPlayhead: targets.fromPlayhead };
  }

  async function getStatus() {
    try {
      const { sequence } = await getContext();
      const selection = await sequence.getSelection();
      const items = (await selection.getTrackItems()) || [];
      return {
        sequence: sequence.name || "",
        videoSelected: items.filter(isVideoItem).length,
        audioSelected: items.filter(isAudioItem).length,
      };
    } catch (e) {
      return { sequence: "", videoSelected: 0, audioSelected: 0, note: wrapError(e).message };
    }
  }

  Cue.premiere = {
    ppro,
    CueError,
    wrapError,
    getContext,
    transact,
    resolveTargets,
    requireTargets,
    isVideoItem,
    isAudioItem,
    getCatalog,
    applyVideoEffect,
    applyAudioEffect,
    applyTransition,
    getStatus,
    prettify,
  };
})(globalThis.Cue = globalThis.Cue || {});
