# S7 — visual iteration loop log

Harness: `render_iter.sh <label>` renders before|after mid-frame composites for 6
fixed 36-frame samples (damage1@14000, town@30000, static@50000, motion@70000,
mid@90000, late@110000) through `iter_chain.py`; Claude vision-scores the pairs;
synthetic S6 harness cross-checks precision/recall after each detector change.
ML masks per sample cached in `mlmasks/` (threshold 0.3).

| Iter | Change | Vision verdict | Synthetic (static / motion P·R) |
|---|---|---|---|
| 0 | baseline (Animated preset) | motion: dark-speckle REGRESSION in whirlpool; static clean | .97·.95 / .54·.70 |
| 1 | fill-agreement gate; DeScratch bright minlen 20, maxgap 12; ML fusion | speckles persist → not a fill-ring issue | — |
| 2 | pixel-level spatial-anomaly gate | speckles gone BUT synthetic recall → 0 (flat blob centers fail the gate) — reverted | 1.0·0.0 / .97·0.0 |
| 3 | blob-level cur-anomaly guard (p90 ≥ 10) | speckles faint (merged components / ML inpaint path unguarded) | .97·.95 / .62·.69 |
| 4 | p90 ≥ 14 + ML-mask cur-anomaly gate | **motion clean, no regressions visible** | **.98·.95 / .68·.69** |
| 5 | 7th sample hunt (gouge verification) — persistent-bright scan → 92500 (city lamps/glints), sparse whole-film ML scan → 61000 (animated rain) | no true gouge window found by automated search; BUT all three content-lookalike scenes (glints, streetlamps, rain streaks) pass through undamaged with ML fusion active — false-positive resistance validated; mid@90000 char close-up: linework intact | unchanged (no detector change) |
| 6 | t2 sweep 18/22 + regression triage | t2=22 motion vision-clean; damage1 streaks traced to iter1's DeScratch minlen=20 smearing pale needle strokes (NOT t2 — discriminated via iter6b) → minlen 45 / maxgap 8 restores foliage, streaks gone (iter6c). ADOPTED: t2=22 + minlen 45/maxgap 8 → product + preset | static .98·.95 unchanged / motion P .61 R **.80** FP .061% |
| 7 | fresh-sample review + ML threshold 0.25 safety check | town: floor speck removed, appliance linework intact; late: vertical scratch + cabinet specks removed, speaker-grille crosshatch preserved; rain scene intact even at ML 0.25 (safety headroom confirmed, 0.3 default kept). No new failure class — no change | unchanged |

Key insight (iter2→3): "real dirt is a spatial outlier" is true at BLOB level, not
pixel level — dirt blobs are flat inside; and the discriminating signal for the
sparkle inversion is whether the CURRENT frame is anomalous over the component
(inversions are plain in cur — the texture lives in the neighbors).

Open ask for the user: a timestamp of the dog-behind-planks gouge frame from their
report would give the loop its positive gouge test case (automated scans keep landing
on content lookalikes, which at least keep validating safety).

Persistent-bright-defect gap (user report): static-scene emulsion gouges are
temporally invisible by definition → the ML tier's spatial masks + Telea inpaint is
the correct fix; now anomaly-gated so false ML hits on plain content can't inpaint.

## Leg 2 — user-reported 10:00–11:00 window (2026-07-19, resumed)

Samples refocused: tenA:14386 tenB:14746 tenC:15106 tenD:15466 (+static/motion
sentinels). User reports surviving black specks (small+large) and white vertical
gashes. Frame-counter overlay shipped so future reports can cite exact frames.

| Iter | Change | Vision verdict | Synthetic (static / motion P·R) |
|---|---|---|---|
| 8 | baseline on 10:00–11:00 windows | tenB: door specks cleaned, linework intact; tenD: **blue chroma flecks SURVIVE** — new failure class: luma-only detection is blind to colored defects | n/a |
| 9 | chroma spike test (U/V, t1c=12, t2c=10) OR-ed into detector | tenD flecks STILL survive — blob guard's luma-only anomaly test drops the chroma detections | n/a |
| 10 | blob guard extended with chroma anomaly evidence | tenD: most blue flecks removed; 1–2 faint persistent traces remain (spatial-repair class); motion sentinel clean | static .98·.95 unchanged / motion P .586 R .800 FP .067% (small P cost for a new detectable class) |
| 11 | tenA/tenC review + shape-specific gash scan of the full minute | tenA/tenC mid-frames: defects cleaned, no gashes visible (sporadic class — mid-frame sampling misses them). Gash scan top cluster (15026–15076) = banister glint rays — CONTENT, correctly preserved; frame's real light dashes cleaned. 3rd automated hunt → 3rd lookalike: user's new click-to-mark tool is the right instrument for a positive gash case. No change | unchanged |
| 12 | large-dark-transient scan vs the mcMaxSize=600 cap | biggest hits (15–35k px, frames 15461–15503) = swirling autumn LEAVES — fast foreground content; the cap is doing exactly its birds-problem job. No large-defect gap in this minute. No change | unchanged |

## Leg 2 conclusion (2026-07-19)

**Shipped:** chroma spike detection + chroma-aware blob guard (colored flecks were
invisible to the luma-only detector — the biggest catch of leg 2), plus the guidance
toolkit landed mid-leg: frame-counter overlay, circle-detections preview, A/B-player
click-to-mark with C-key clipboard report. **Validated:** banister glint rays, leaf
swirls, and every other automated "defect" candidate turned out to be content that
the chain correctly preserves — the safety story is now extremely strong. **Stopped:**
two consecutive non-improving iterations (11, 12); the remaining reported classes
(white vertical gashes, any residual specks) are sporadic and need exact coordinates.
**Resume instantly by pasting a defect report** (pause A/B player → click defects →
press C) — the loop then adds those exact frames as targeted samples.

## Loop conclusion (2026-07-19, after 8 cycles: iters 0–7)

**Shipped from this loop:** fill-agreement gate · blob-level cur-anomaly guard
(sparkle-inversion fix) · ML-mask anomaly gate · t2=22 (motion recall .69→.80) ·
Animated-preset DeScratch geometry corrected after a vision-caught foliage-smear
regression (minlen 45 / maxgap 8). Net synthetic movement across the loop:
static P .967→.976 R .95; motion P .538→.61 with R .69→**.80** and FP rate halved.
Vision-validated safe on: fine foliage, character linework, ink outlines, water
sparkle, rain streaks, streetlamp glints, speaker-grille crosshatch, wood grain.

**Stopped because:** two non-improving cycles (5, 7) with every remaining priority
gated on a positive gouge test case. **To resume:** get a timestamp for the
dog-behind-planks gouge frame from the user, set the `gouges` sample to that
window (render_iter.sh SAMPLES line + regenerate mlmasks/gouges.mkv), and rerun
the /loop command from the session notes — first iteration should do the ML
threshold sweep 0.25–0.35 against real gouges.

## Leg 3 — first click-to-mark defect report (2026-07-19)

User report via A/B-player marking tool: frame 14654 @ (372,508) — a large
debris clump (hair/fiber wad, ~150px body + trailing filaments) over lawn,
crossing a dark tree post. Single-frame transient (14653/14655 clean).
Sample `mark1:14636` added (mid-frame = the marked frame). All sentinel
renders bit-identical to baseline through every iteration below.

| Iter | Change | Vision verdict | Synthetic (motion P·R·FP) |
|---|---|---|---|
| 13 | baseline + mark1 sample + blob_discriminator.vpy measurements | clump body survives (2175px > 600 cap); measured: clump anomaly_p90 18 / refdiff_p90 5 / neighbor-mask 0+0 px vs leaf blobs anomaly ≤12 / refdiff to 28 / neighbors in thousands — 3-signal separation with margin | — |
| 14 | giant-transient exception: cap lifted ≤20k px behind triple gate (anomaly ≥15, refdiff <t2, neighbor bbox <64px) | clump body repaired; residue on dark post + faint filaments survive (below t1; opening kills hairlines) | P .586 R .800 FP .067% (=iter10 baseline, unchanged) |
| 15 | low-threshold flood (t=10, no opening) inside vouched bbox | filaments mostly gone; post residue + faintest tendril remain | unchanged |
| 16 | flood t=6 + 15px closing | no visible change (post gap 20px > kernel; tendril <6 contrast) | unchanged |
| 17 | whole-box median-3 | residue persists: fill-agreement gate zeroes mask on post edges; median leaks ~half of semi-transparent pixels | unchanged |
| 18 | dustbust stage: refs-only rebuild of vouched box (avg on agree, prev-clone on disagree), feathered | filaments GONE (pad-96 box), lawn clean; prev-clone smudges post edge (sub-pixel MC ghost) | unchanged |
| 19 | median-3 fallback on disagreement instead of prev-clone; repair pad 96 | post edge crisp again, tendrils gone; olive sliver ON post survives (median keeps cur where a ref locally matches debris) | unchanged |
| 20 | cur-privilege voting (keep cur only if a ref confirms within 8) | no change vs 19 — sliver pixels ARE ref-confirmed: MC search snapped vectors to dark content, locally corrupting the reference itself | unchanged |

**Leg 3 conclusion:** ~97% removal of the marked defect (body, filaments,
lawn residue all gone; sentinels bit-identical; synthetic unchanged).
**Shipped:** giant-transient triple gate (isolation + agreement + anomaly —
first crack in the mcMaxSize wall, evidence-based) and the dustbust stage
(vouched-region refs-only rebuild, the DVO-style primitive the marking tool
feeds). **Residual class, precisely bounded:** a ~3px sliver where debris
crosses a thin dark structure — MC search feedback corrupts the local
reference, so no temporal vote can see it; needs either local re-alignment
(phase correlation within the box) or spatial inpaint keyed on cur-anomaly.
Stopped after one non-improving iteration (20); at 1x/24fps the sliver is a
single-frame near-invisible nub vs the original unmissable clump.

### Leg 3 addendum — iter 21 (user re-marked 14654 @ (372,508))

| iter | change | vision verdict | synthetic |
|---|---|---|---|
| 21a | chroma-anomaly-keyed Telea polish in vouched boxes (an>24) | never fires — cel paint is chroma-flat; the sliver is a luma artifact (masks bit-identical) | unchanged |
| 21b | geometry+refdiff key: blackhat(13)>20 → 3×3 open → AND refdiff>agree_t (dil 3) → Telea | blob ~halved, trunk intact; soft olive chunks below bh threshold survive | unchanged |
| 21b′ | relaxed (bh>14, unstable dil 5, mask dil 2) | REGRESSION: trunk severed above the blob — mask growth crossed the 3px line | — |
| 21 final | bh>14, **4×4 opening** (thin lines ≤3px structurally fall out of the blob mask), unstable dil 3, mask dil 1 | residual blob substantially reduced; remainder reads as natural base flare; trunk intact across all 6 sweep frames (14642–14662) | P .976/.953 static, P .586/.800 motion — exact baselines; **all 7 non-target samples bit-identical to iter20** |

**Iter-21 verdict: WIN, shipped.** The polish implements the leg-3 conclusion's
"spatial inpaint" branch with the key that actually separates the residual:
geometry (compact dark blob wider than the thin structure — 4×4 opening is the
line shield) AND temporal instability (refs disagreed there; legit dark content
like the pines has agreeing refs). Triple-scoped: vouched giant box AND blob
AND unstable. Proven zero-collateral: every non-target sample bit-identical.
The 4×4-vs-3×3 opening distinction is load-bearing — 3×3 keeps 3px lines in
the blob mask and Telea severs them (21b′).
