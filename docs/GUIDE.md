# Cue: full guide

Cue is a free macOS menu-bar app. Press a hotkey and a floating search bar opens over Premiere. Type a few letters to find a video effect, audio effect, transition, preset or macro, then press ↩ to apply it to the selected clips. A small UXP plugin called **Cue Bridge** runs inside Premiere. It connects to the app, keeps the effect list in sync, and does the actual applying.

```
Cue/
├── app/       Swift package for the macOS app (SwiftUI + AppKit, no dependencies)
└── plugin/    Cue Bridge UXP plugin for Premiere Pro 25.6 or later
```

---

## 1. Install

### The Mac app

Requirements: macOS 13 or later, plus Xcode or the free Command Line Tools (`xcode-select --install`).

```bash
cd app
./build.sh --install      # builds build/Cue.app, copies it to /Applications and launches it
```

Cue runs from the menu bar (the Cue mark: a C with a dot, filled in when Premiere is connected) and has no Dock icon. The first time it starts, it opens **Settings › Connection**, which shows your **pairing code**.

> The app has an ad-hoc signature. If macOS blocks it, right-click Cue.app › Open once. If a firewall prompt appears, you can safely allow it, because Cue only accepts connections from this Mac.

### The Premiere plugin

1. Make sure the free **Creative Cloud** desktop app is installed and signed in. It's needed once, to install the plugin.
2. Get `CueBridge.ccx` from the repository's **Releases** page, or build it yourself with `plugin/make-ccx.sh`.
3. Double-click `CueBridge.ccx`. When Creative Cloud warns that the plugin isn't from the Marketplace, click **Install**.
4. In Premiere: **Window › UXP Plugins › Cue Bridge**. Enter the pairing code and click **Connect**.
5. **Dock the panel in your workspace.** UXP panels only run while they are loaded, so a docked panel connects automatically every time Premiere starts.

You can quit Creative Cloud afterwards; the plugin stays installed. For plugin development, use UXP Developer Tool's **Load** with Developer Mode on instead.

---

## 2. Use it

Press **⌥Space** (you can change it) while Premiere is in front.

| Key | Action |
|---|---|
| type | fuzzy search. For example, `gb` finds Gaussian Blur and `xdis` finds Cross Dissolve |
| ↑ ↓ / ⌃P ⌃N | move through results |
| ⇞ ⇟ | jump a page |
| ⇥ / ⇧⇥ | next / previous category |
| ⌘1 … ⌘8 | All, Video, Audio, Transitions, Presets, Macros, Favorites, Recent |
| `v:` `a:` `t:` `p:` `m:` `f:` `r:` | type a prefix to jump to a category |
| ↩ | apply and close |
| ⌥↩ | apply and keep the bar open, to stack several effects |
| ⌘D | toggle favorite |
| ⎋ | clear the search, then reset the category, then close |
| ⌘, | Settings |

You can rebind every panel key in **Settings › Keys**.

- **Targets.** Effects go to every selected clip of the matching type. If nothing is selected, Cue uses the clip under the playhead (topmost video track or lowest audio track). You can turn this off.
- **Recents and favorites** float to the top when the search is empty, and they also rank higher in search results.
- **Item shortcuts** (Settings › Keys): give any effect, preset or macro its own global shortcut. By default these shortcuts only work while Premiere is the frontmost app, so they don't take over keys in other apps.
- The footer shows the connection state and what's selected, for example `Sequence 01 · 2 video`.

---

## 3. Presets that keep your keyframes intact

UXP has **no API for applying native `.prfpset` presets**. Cue therefore uses its own presets, captured from a real clip:

1. Style a clip in Premiere: effects, values, keyframes, Motion and Opacity changes.
2. Select it and click **Capture** in the Cue Bridge panel (or use Settings › Presets › Capture Selected Clip).
3. The preset appears in search like any other item.

Tip: to bring over one of your existing `.prfpset` presets, drag it onto a clip once in Premiere and capture that clip.

**How applying works:**

- Effects from the preset are always **added as new instances**. Cue never modifies effects that are already on the clip, or their keyframes.
- **Fixed effects** (Motion, Opacity, Volume) can't be added a second time, so the preset writes into the clip's own instance. In **Preserve** mode (the default), any fixed-effect property you have already keyframed on the target is left exactly as it is. In **Replace** mode, those keyframes are swapped for the preset's.
- When capturing, a fixed-effect property is only switched on if it's keyframed or differs from Premiere's default. A "blur" preset therefore won't reset Position or Scale on your clip. You can switch any property on or off in Settings › Presets.
- Preset keyframes are placed relative to **each target clip's own start**, which correctly accounts for trimmed in-points. Timing options: from clip start, stretched to clip length, or anchored to clip end. You can set the timing per preset.
- Interpolation modes (linear, hold, bezier) are restored. Custom bezier ease handles aren't exposed to plugins yet.
- If Premiere refuses one property, the rest of the preset still applies, and the toast tells you what was skipped.

A preset uses a few undo steps: one adds the effects, the others set keyframing and values.

---

## 4. Macros

In **Settings › Macros** you can chain items in order, for example Warp Stabilizer → a look preset → Cross Dissolve at both ends. You can add pauses, override transition position and duration per step, choose whether to stop on errors, test-run a macro, and give it a shortcut. Macros show up in search under **Macros**.

---

## 5. Settings overview

- **General:** open hotkey, launch at login, close after applying, toast, playhead fallback, number of rows, number of recents.
- **Appearance:** 5 themes (Midnight, Graphite, Ember, Aurora, Daylight), custom accent color, translucency, width, text size, compact rows, category bar, key hints, live preview.
- **Keys:** panel key bindings and item shortcuts.
- **Applying:** default transition position, duration and single-sided option. Preset keyframe mode, timing, duplicate handling, and whether to apply fixed effects.
- **Presets / Macros:** edit, rename, toggle effects and properties, import and export (JSON).
- **Connection:** server on/off, pairing code (copy or regenerate), port, browser blocking, sync now, activity log.

All data lives in `~/Library/Application Support/Cue/` as plain JSON.

---

## 6. How the two parts talk

- Cue runs a WebSocket server on **localhost:47821**. It accepts connections only from this Mac. UXP plugins can't listen for connections, so the plugin connects to the app as a client.
- The plugin sends `hello` with the pairing code. After 10 wrong codes in a minute, Cue refuses everyone for a minute. Connections from web pages are refused by default.
- Messages are JSON: `request` / `response` (methods: `catalog.get`, `status.get`, `apply`, `preset.capture`, `ping`) and `event` (`catalog`, `preset.captured`).
- The plugin runs requests one at a time, so macros and fast key presses never overlap. It reconnects automatically with backoff.

**Changing the port:** set it in Settings › Connection, add `ws://localhost:<port>` to `requiredPermissions.network.domains` in `plugin/manifest.json`, reload the plugin, and enter the same port in the panel.

---

## 7. Known limits (from Premiere's plugin API, as of Premiere 26)

- Native `.prfpset` presets can't be applied by plugins. Use Capture instead (see §3).
- Audio transitions can't be listed or applied by UXP, so only video transitions appear.
- Premiere doesn't expose its Effects-panel folders, so Cue groups effects into categories based on their names.
- Bezier ease handles aren't readable or writable. Interpolation modes are.

## 8. Troubleshooting

- **Panel says "Cue app not found":** make sure Cue is running and the port matches. The menu-bar icon fills in when Premiere is connected.
- **"Pairing code rejected":** copy the code from the Cue menu and click Connect again.
- **Hotkey does nothing:** another app may own that combo. Settings › General shows a warning if it's taken.
- **Effects are missing after a Premiere update:** click Sync in the panel or in the Cue menu.

## 9. Development

```bash
cd plugin
npm install           # only needed for the e2e test (ws)
node test/run.js      # apply / capture / keyframe-safety tests against a mock Premiere DOM
node test/e2e.js      # real panel scripts ↔ WebSocket server speaking Cue's protocol
```

Plugin source: `js/premiere.js` (targets, catalog, effects and transitions), `js/presets.js` (capture and keyframe-safe apply), `js/bridge.js` (socket), `js/main.js` (panel UI).
App source: `Core/` (models, search, preferences), `Bridge/BridgeServer.swift`, `System/HotKeyCenter.swift`, `UI/` (panel, results, HUD, settings).
