// Minimal in-memory stand-in for require("premierepro"), enough to exercise
// Cue Bridge's apply/capture logic. Actions are closures run on commit.
"use strict";

class TickTime {
  constructor(seconds) { this.seconds = seconds; this.ticksNumber = Math.round(seconds * 254016000000); this.ticks = String(this.ticksNumber); }
  static createWithSeconds(s) { return new TickTime(s); }
  add(t) { return new TickTime(this.seconds + t.seconds); }
  subtract(t) { return new TickTime(this.seconds - t.seconds); }
  equals(t) { return Math.abs(t.seconds - this.seconds) < 1e-9; }
}
class PointF { constructor(x, y) { this.x = x; this.y = y; } }
class Color { constructor(r, g, b, a) { this.red = r; this.green = g; this.blue = b; this.alpha = a; } }

const act = (fn, desc) => ({ __run: fn, desc });

function plain(v) {
  if (v instanceof PointF) return [v.x, v.y];
  if (v instanceof Color) return v;
  return v;
}

class Keyframe {
  constructor(value, position) { this._v = plain(value); this.position = position || new TickTime(0); this._interp = 2; }
  get value() { return { value: this._v }; }
  set value(v) { this._v = plain(v); }
  async getTemporalInterpolationMode() { return this._interp; }
  async setTemporalInterpolationMode(m) { this._interp = m; return true; }
}

class ComponentParam {
  constructor(name, value, opts = {}) {
    this.displayName = name;
    this._value = value;
    this._tv = false;
    this._kfs = []; // {t:seconds, v, interp}
    this._settable = opts.settable !== false;
  }
  isTimeVarying() { return this._tv; }
  getKeyframeListAsTickTimes() { return this._kfs.map((k) => new TickTime(k.t)); }
  getKeyframePtr(t) {
    const k = this._kfs.find((x) => Math.abs(x.t - t.seconds) < 1e-9);
    if (!k) throw new Error("no keyframe");
    const kf = new Keyframe(k.v, new TickTime(k.t)); kf._interp = k.interp; return kf;
  }
  async getStartValue() { return this._value instanceof Color ? this._value : new Keyframe(this._value); }
  async getValueAtTime(t) { return { value: this._value }; }
  createKeyframe(v) { if (v === undefined) throw new Error("bad value"); return new Keyframe(v); }
  createSetTimeVaryingAction(on) { return act(() => { this._tv = on; if (!on) this._kfs = []; }, `tv ${this.displayName}=${on}`); }
  createSetValueAction(kf) {
    if (!this._settable) throw new Error(`${this.displayName} is read-only`);
    return act(() => { if (this._tv) throw new Error("param is time-varying"); this._value = kf._v; }, `set ${this.displayName}`);
  }
  createAddKeyframeAction(kf) {
    return act(() => {
      if (!this._tv) throw new Error("not time-varying");
      this._kfs = this._kfs.filter((k) => Math.abs(k.t - kf.position.seconds) > 1e-9);
      this._kfs.push({ t: kf.position.seconds, v: kf._v, interp: 2 });
      this._kfs.sort((a, b) => a.t - b.t);
    }, `kf ${this.displayName}`);
  }
  createSetInterpolationAtKeyframeAction(t, mode) {
    return act(() => { const k = this._kfs.find((x) => Math.abs(x.t - t.seconds) < 1e-9); if (!k) throw new Error("no kf"); k.interp = mode; }, "interp");
  }
}

class Component {
  constructor(matchName, displayName, params) { this.matchName = matchName; this.displayName = displayName; this.params = params; }
  async getMatchName() { return this.matchName; }
  async getDisplayName() { return this.displayName; }
  getParamCount() { return this.params.length; }
  getParam(i) { if (!this.params[i]) throw new Error("bad index"); return this.params[i]; }
}

const EFFECT_DEFS = {
  "AE.ADBE Gaussian Blur 2": ["Gaussian Blur", () => [new ComponentParam("Blurriness", 0), new ComponentParam("Blur Dimensions", 1), new ComponentParam("Repeat Edge Pixels", false)]],
  "PR.ADBE Tint": ["Tint", () => [new ComponentParam("Map Black To", new Color(0, 0, 0, 1)), new ComponentParam("Map White To", new Color(1, 1, 1, 1)), new ComponentParam("Amount to Tint", 100)]],
};
const AUDIO_DEFS = { "Parametric Equalizer": ["ADBE Parametric EQ", () => [new ComponentParam("Gain", 0)]] };

function motion() {
  return new Component("AE.ADBE Motion", "Motion", [
    new ComponentParam("Position", [0.5, 0.5]), new ComponentParam("Scale", 100), new ComponentParam("Scale Width", 100),
    new ComponentParam("Uniform Scale", true), new ComponentParam("Rotation", 0), new ComponentParam("Anchor Point", [0.5, 0.5]),
  ]);
}
function opacity() { return new Component("AE.ADBE Opacity", "Opacity", [new ComponentParam("Opacity", 100), new ComponentParam("Blend Mode", 0)]); }

class Chain {
  constructor(components) { this.components = components; }
  getComponentCount() { return this.components.length; }
  getComponentAtIndex(i) { return this.components[i]; }
  createAppendComponentAction(c) { return act(() => this.components.push(c.__real || c), "append"); }
  createInsertComponentAction(c, i) { return act(() => this.components.splice(i, 0, c), "insert"); }
}

class ClipBase {
  constructor(name, start, end, inPoint) {
    this.name = name; this.start = start; this.end = end; this.inPoint = inPoint;
    this.chain = new Chain([opacity(), motion()]);
    this.transitions = [];
  }
  async getName() { return this.name; }
  async getStartTime() { return new TickTime(this.start); }
  async getEndTime() { return new TickTime(this.end); }
  async getInPoint() { return new TickTime(this.inPoint); }
  async getDuration() { return new TickTime(this.end - this.start); }
  async getComponentChain() { return this.chain; }
  createAddVideoTransitionAction(tr, opts) { return act(() => this.transitions.push({ name: tr.matchName, start: opts._start, dur: opts._dur }), "transition"); }
}
class VideoClipTrackItem extends ClipBase {}
class AudioClipTrackItem extends ClipBase {
  constructor(...a) {
    super(...a);
    this.chain = new Chain([new Component("ADBE Audio Volume", "Volume", [new ComponentParam("Bypass", false), new ComponentParam("Level", 0)])]);
  }
}

class Track { constructor(items) { this.items = items; } async getTrackItems() { return this.items; } }

function makeEnv() {
  const log = [];
  const v1 = new VideoClipTrackItem("A.mp4", 0, 4, 10);
  const v2 = new VideoClipTrackItem("B.mp4", 4, 10, 2);
  const a1 = new AudioClipTrackItem("A.wav", 0, 4, 10);
  const state = { selection: [], playhead: 1 };
  const sequence = {
    name: "Sequence 01",
    async getSelection() { return { async getTrackItems() { return state.selection.slice(); } }; },
    async getPlayerPosition() { return new TickTime(state.playhead); },
    async getVideoTrackCount() { return 2; },
    async getVideoTrack(i) { return i === 0 ? new Track([v1, v2]) : new Track([]); },
    async getAudioTrackCount() { return 1; },
    async getAudioTrack() { return new Track([a1]); },
  };
  let locked = false;
  const project = {
    lockedAccess(cb) { locked = true; try { cb(); } finally { locked = false; } },
    executeTransaction(cb, label) {
      if (!locked) throw new Error("executeTransaction outside lockedAccess");
      const actions = [];
      cb({ addAction(a) { actions.push(a); return true; } });
      // Atomic: snapshot-free, but stop on first failure and report false like Premiere.
      try { actions.forEach((a) => a.__run()); } catch (e) { log.push(`FAIL ${label}: ${e.message}`); return false; }
      log.push(`TX ${label} (${actions.length})`);
      return true;
    },
  };
  const ppro = {
    TickTime, PointF, Color, Keyframe,
    VideoClipTrackItem, AudioClipTrackItem,
    MogrtText: class {}, MogrtComment: class {},
    Constants: { TrackItemType: { CLIP: 1 }, InterpolationMode: { BEZIER: 0, HOLD: 1, LINEAR: 2, TIME: 3 } },
    Project: { async getActiveProject() { return project; } },
    VideoFilterFactory: {
      async getMatchNames() { return Object.keys(EFFECT_DEFS); },
      async getDisplayNames() { return Object.values(EFFECT_DEFS).map((d) => d[0]); },
      async createComponent(m) { const d = EFFECT_DEFS[m]; if (!d) throw new Error("unknown"); return new Component(m, d[0], d[1]()); },
    },
    AudioFilterFactory: {
      async getDisplayNames() { return Object.keys(AUDIO_DEFS); },
      async createComponentByDisplayName(n) { const d = AUDIO_DEFS[n]; if (!d) throw new Error("unknown"); return new Component(d[0], n, d[1]()); },
    },
    TransitionFactory: {
      async getVideoTransitionMatchNames() { return ["AE.ADBE Cross Dissolve New", "AE.ADBE Dip To Black"]; },
      async createVideoTransition(m) { return { matchName: m }; },
    },
    AddTransitionOptions() {
      return { setApplyToStart(v) { this._start = v; return this; }, setDuration(t) { this._dur = t.seconds; return this; }, setForceSingleSided() { return this; } };
    },
  };
  return { ppro, project, sequence, state, v1, v2, a1, log, ComponentParam, Component };
}

module.exports = { makeEnv, TickTime, PointF, Color };
