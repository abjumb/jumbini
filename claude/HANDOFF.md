# Session handoff — 15 Aug 2026

State of the repo as of `7a9bb17` (= tag `v4.1`), written for whoever picks this up
next. Everything below was verified against the tree, not recalled; where a claim is
checkable there is a command to check it.

---

## Where things stand

**v4.1 is published, signed and notarized.** The Gatekeeper problem is solved — the
README's install section is now three steps with no right-click trick and no trip
through Privacy & Security. The release pipeline has run end to end from `main`.

**No open PRs.** Ten merged in one day (#5–#14) plus a few direct commits.

**CI exists now** and is the only compiler this repo has access to from a Linux
session. Two workflows:

| Workflow | Trigger | Runner | Does |
|---|---|---|---|
| `ci.yml` | push to main, every PR | `macos-latest` | `swift build`, `swift test` (327 tests), `./Scripts/bundle.sh` |
| `release.yml` | `v*` tags | `macos-15` (pinned) | tests, cert import, sign, notarize, staple, draft release |

---

## What shipped

- **#5** wardrobe overlay sprites removed (the art; `WardrobeArt` and its ink-bounds
  anchoring are still in `SpriteLoader.swift`)
- **#6** Bring Your Own Dog **Phase 0** — coats load from disk
- **#7** README points at `COATS.md`
- **#8** the macOS CI workflow
- **#9** README test count + Files table refreshed
- **#10** Developer ID signing + notarization
- **#11–#14** hardening the release path against real failures found by running it

### Phase 0, in one paragraph

`Coat` stopped being a two-case enum whose raw value doubled as a filename prefix. It
is now a struct carrying a **search root**: `root` (nil = the app bundle) plus `prefix`
(how coats sharing a folder stay apart). Bundled shaggy keeps `shaggy_` inside
`jumba/`; an installed coat gets its own directory under
`~/Library/Application Support/Jumbini/coats/<id>/` and needs no prefix. All dog art
already funnelled through one function (`SpriteLoader.texture(named:)`), which is why
the change stayed small. `coatSubstitutes` survived unrestructured, rekeyed by id.
Discovery and manifest parsing live in `CoatCatalog.swift` — Foundation only, no
AppKit — so they are testable without a Mac. Format is documented in `COATS.md`.

One non-obvious thing worth not re-deriving: **`textureCache` is keyed by coat id as
well as filename.** Two installed coats both hold an `idle_south`; a filename-only key
serves the first coat's art to the second.

---

## Verified findings that contradict the PRD

Both were checked against the tree. Re-check with the commands given.

### 1. It is 17 wired states and 136 sprites, not 21 and 168

`KIT_STATES` imports 21 states, but `SpriteLoader` only ever reads 17 of them.
`alert`, `growl`, `pin` and `whine` are imported and shipped — 32 sprites — and no
code references them. `rollover` and `shaketoy` are referenced but have no art
anywhere, so they fall back to other poses.

This is roughly a 19% cut to per-dog generation cost, which bears on the PRD's Q3
(pilot cap) and R6 (per-state QA).

```bash
python3 - <<'PY'
import re
kit=set(re.findall(r'^\s*"(\w+)":', open('Tools/import_jumba.py').read().split('KIT_STATES = {')[1].split('}')[0], re.M))
src=open('Sources/Jumbini/SpriteLoader.swift').read()
wired={m for m in re.findall(r'"([a-z0-9]+)_(?:\\\(d\)|south|\\\(\$0\.fileSuffix\)|\\\(\$0\))"', src)}
print(f"imported={len(kit)} wired={len(wired)} both={len(kit&wired)} sprites={len(kit&wired)*8}")
print("dead art:", " ".join(sorted(kit-wired)))
PY
```

### 2. An omitted state falls back to Jumba, not to another pose of your dog

`make()` already resolves coat → classic per animation, all-or-nothing. So a custom
coat missing `stalk` shows **Jumba** stalking, not its own sniff. This is the concrete
mechanism behind the PRD's Goal 2 ("no silent fallback to Jumba's art"), and the reason
all 17 states are worth drawing even though only `idle_south` is enforced. Documented
in `COATS.md`.

### 3. Q5 (does the format need a manifest?) — yes, and for an unstated reason

The art is not one canvas size. 41 of Jumba's states are 48×48; the three sitting poses
are **68×76** with less pixel density, which is why `SpriteLibrary` hardcodes a
`sitScale` (2.9) next to `baseScale` (2.4) — tuned to his specific export. A coat drawn
at another density had no way to say so. Hence `coat.json` with per-state `scales`.
`ASSETS.md` independently flags the same problem.

---

## Open work, ranked

### 1. R7 — the background-removal bug (recommended next)

**This is a live silent-corruption bug on `main`, not a hypothetical.** It is also the
only P0 in the Bring Your Own Dog PRD that needs no Mac, no Apple account and no
generation pipeline — pure stdlib Python, fully testable from a Linux session.

The PRD says light coats break `import_jumba.py`'s flood fill. **They don't.** A pure
white dog with an intact 1px dark outline survives a white backdrop with zero loss.
What breaks it is an **outline breach** — a generator artifact, not a colour property.
A 3px gap erases 100% of the sprite, and it does so even on a *transparent* background
where nothing should be stripped at all. The existing `BACKDROP_MIN_FRACTION` (0.10)
floor cannot catch this, because eating the whole dog is comfortably more than 10%.

Reproducer (still fails on `7a9bb17`):

```bash
python3 - <<'PY'
import sys; sys.path.insert(0,'Tools')
from import_jumba import strip_background_if_backdrop
W=H=48
def canvas(): return [bytearray(b"\x00\x00\x00\x00"*W) for _ in range(H)]
def px(r,x,y,c): r[y][x*4:x*4+4]=bytes(c)
def dog(rows,fur,gap=False):
    for y in range(12,37):
        for x in range(12,37):
            edge = y in (12,36) or x in (12,36)
            px(rows,x,y,(tuple(fur) if (edge and gap and y==12 and 20<=x<=22) else ((20,20,20) if edge else tuple(fur)))+(255,))
    return rows
def body(r): return sum(1 for y in range(13,36) for x in range(13,36) if r[y][x*4+3]>0)
r=dog(canvas(),(252,252,252),gap=True); b=body(r); strip_background_if_backdrop(W,H,r)
print(f"erased {b-body(r)}/{b} interior pixels")   # currently 529/529
PY
```

What the fix needs:

- An **upper bound** to sit alongside the existing lower one: a fill consuming most of
  the interior should fail loudly rather than write a hole. This is the only guard that
  catches the catastrophic case.
- Regression fixtures varying **outline integrity and anti-aliasing**, not just coat
  colour — that is where the real failure lives.
- `Tools/*.py` currently has **zero test coverage** and is not touched by `ci.yml`.
  Wiring it in is part of this.

Worth knowing: the flood fill is currently **dead code on the kit path**. `Idle` is the
only kit state with a baked backdrop and it is deliberately not imported (`KIT_STATES`
maps idle → `Idle_2`). So if the generator is specified to emit transparent PNGs with
hard outlines, R7 shrinks to "add the guard and the fixtures."

### 2. SHA-pin `softprops/action-gh-release`

Still `@v2` (tag-pinned) at `.github/workflows/release.yml:213`, in a workflow that has
the Developer ID private key in its environment. A retagged or compromised third-party
action is a real supply-chain path. Small fix, and the downside is key material rather
than a bug.

### 3. Runner divergence

`release.yml` pins `macos-15`; `ci.yml` tracks `macos-latest`. Defensible — a release
wants a stable runner — but the two paths can drift in toolchain, and the pin needs
revisiting when GitHub retires the image. A comment in `release.yml` already notes this.

### 4. Bring Your Own Dog, Phase 1 — the spike (blocked here)

The PRD's Q1 is still the top risk and needs a generation pipeline this container does
not have. One finding that should shape it: `jumbini-kit/dog-states/metadata.json` has
**44 states, 44 distinct character ids, and exactly 1 prompt string**. Identity was held
by re-issuing the same 433-character prose brief 44 times independently — there was no
canonical-frame reference anchoring anywhere in how Jumba was made. So R5's proposed
approach is *new*, not a formalization of practice. The known drift rate under
prompt-only anchoring is at least 1-in-44 severe enough to reject (`Idle` came back with
tan eye glints and was replaced by `Idle_2`), caught only because a human looked. That
is the baseline the spike has to beat, and it belongs in its success criteria.

---

## Environment notes for the next session

**This container is Linux.** No `swift`, no `codesign`, no `xcrun`. The package is
macOS-only (AppKit/SpriteKit), so **CI is the only compiler available** — push a branch
and read the check run. Do not claim Swift changes are verified until CI says so.

**Pushing works.** A previous session reported a 403 and told the user to apply a patch
by hand on their Mac; that was wrong for this environment. Pushes to `abjumb/jumbini`
succeeded ~10 times in one session.

**Check for drift before trusting a patch or a plan.** A signing patch authored earlier
in the day carried a README rewrite that had already landed separately, and its copy
predated two later README commits — replaying it would have silently reverted both.
`git apply --check` caught it. Same discipline applies to the PRD, which is accurate on
mechanics but wrong on the two counts above.

**Branch naming is a mess and it does not matter.** Most of today's work went through
`claude/remove-wardrobe-sprites-mzfsut` regardless of topic, because that was the
session's designated branch; `signing-and-readme` ended up signing-only. Merged PRs are
the real record.
