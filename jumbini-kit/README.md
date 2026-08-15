# Jumbini / Treat-Box asset kit

Everything generated in the Claude session, in one place.

## Already in this zip
- `audio/` — 10 synthesized 8-bit WAV clips (22050 Hz, 8-bit mono): bark x3, growl,
  yip, whine, squeak, grunt, chime, shutter. Plus `synth.py` to regenerate/tweak.
- `sheets/` — the 5 interactive HTML review sheets (open in a browser; every sprite
  is previewable and downloadable from there too).
- `manifest.json` — 161 entries mapping every generated asset to its download URL.
- `fetch_assets.py` — downloads all of them.

## Getting the images
The sprites live on PixelLab's CDN (the sandbox that built this kit can't reach it,
your machine can). Run:

    python3 fetch_assets.py

This creates `assets/` with:
- `treat-box/` — chosen base icon, 9-frame wobble, 16 candidates each for
  top-down / opened / crushed, plus the original candidate grid
- `jumbini/sprites/` — 43 props & FX frames (strips as name_0..N)
- `jumbini/ui/` — emote bubble, 8 icons, badge, caption plate, watermark, mute
- `jumbini/wardrobe/` — 7 items x 4 front directions on 48x48 overlay canvases
- `jumba-character/jumba_all_states.zip` — ALL 44 dog states in importer layout
  (`<state>/rotations/<direction>.png` + metadata.json each): corrected-eye
  originals, the 12 manifest poses, and the 20 shaggy-coat variants

The script is re-runnable; it skips files it already has and retries failures.

## Notes
- Known suspect sprites (flagged in the Jumbini sheet): rope_taut_left/mid,
  confetti_2, dust_0, toy_squash_1, bandana_e.
- URLs are unauthenticated; the job UUID is the access key. They're PixelLab-hosted,
  so fetch soon rather than years from now.
