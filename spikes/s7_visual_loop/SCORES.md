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
