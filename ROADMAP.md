# Roadmap

## Ideas
- [ ] Notarized, signed release builds
- [ ] Search inside preset contents (find presets by the effects they use)
- [ ] Apply an effect to a whole track or every clip in the sequence
- [ ] Optional per-item options popover (⇧↩) for transitions and presets
- [ ] Import native `.prfpset` files directly, if Adobe adds an API for it
- [ ] Audio transitions, once UXP supports them
- [ ] Localized UI

## Known issues
- A preset takes a few undo steps instead of one (effects, keyframing, values).
- Effect categories are guessed from names, because Premiere doesn't expose its Effects-panel folders.
- Changing the bridge port also needs an edit to `plugin/manifest.json`.
