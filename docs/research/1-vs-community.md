Research complete. Findings below.

# ANGLE 1 — VS/AVS community state of the art for film dust & scratch cleanup

## (a) RemoveDirtMC — the motion-compensated composition

**Algorithm (why plain RemoveDirt misses):** `RestoreMotionBlocks` never looks at frame n itself for detection — it divides the frame into 8x8 blocks and compares each block's luma in `neighbour(n-1)` vs `neighbour(n+1)` using one of three methods: plain SAD (>= `mthreshold` → motion block), noise-adjusted SAD (`noise>0`: `SUM(||y-x|-noise|)`), or NPC "noisy pixel counting" (`noise>=0 and noisy>=0`: count pixels differing >= noise; block is motion if count >= noisy — the author calls NPC "clearly the best method", he ran most tests with `noise=8..10, noisy=12`). Phase 2 grows/prunes motion blocks via `dist`/`tolerance`/`dmode` neighborhood voting; phase 3 copies motion blocks from `restore` into `filtered` and iteratively un-cleans blocks whose 8-px border-line SAD mismatch exceeds `pthreshold`/`cthreshold`; if phase-3 motion blocks exceed `gmthreshold` % the whole frame is taken from `alternative`. Source: [avisynth.nl/index.php/RemoveDirt](http://avisynth.nl/index.php/RemoveDirt) (note: HTTPS cert is broken on this host; fetch over plain HTTP). Consequence: **any global/camera motion floods phase 1 with motion blocks and cleaning shuts off** — that is exactly the "hit and miss" failure mode on real handheld 35mm. MC alignment of n-1/n+1 before detection is the canonical fix; the `neighbour2` parameter exists specifically "for using RemoveDirt in combination with motion compensation filters like MVTools (see RemoveDirtMC)".

**Canonical RemoveDirt script (verbatim, avisynth.nl):**
```avisynth
function RemoveDirt(clip input, bool "_grey", int "repmode")
{
    _grey=default(_grey, false)
    repmode=default(repmode, 16)
    clmode=17
    clensed=Clense(input, grey=_grey, cache=4)
    sbegin = ForwardClense(input, grey=_grey, cache=-1)
    send = BackwardClense(input, grey=_grey, cache=-1)
    alt=Repair(SCSelect(input, sbegin, send, clensed, debug=true), input, mode=repmode, modeU = _grey ? -1 : repmode)
    restore=Repair(clensed, input, mode=repmode, modeU = _grey ? -1 : repmode)
    corrected=RestoreMotionBlocks(clensed, restore, neighbour=input, alternative=alt, gmthreshold=70, dist=1, dmode=2, debug=false, noise=10, noisy=12, grey=_grey)
    return RemoveGrain(corrected, mode=clmode, modeU = _grey ? -1 : clmode)
}
```

**johnmeyer's improved RemoveDirtMC (verbatim; the de-facto community standard, posted in [videohelp 378183 posts #5-6](https://forum.videohelp.com/threads/378183-8mm-restoration-script-question)) — two-step motion search on a prefiltered super clip, `MFlow` (per-pixel flow, not block compensate):**
```avisynth
function RemoveDirt(clip input, int "limit", bool "_grey")
{
  clensed=input.Clense(grey=_grey, cache=4)
  alt=input.RemoveGrain(2)
  return RestoreMotionBlocks(clensed,input,alternative=alt,pthreshold=6,cthreshold=8, gmthreshold=40,dist=3,dmode=2,debug=false,noise=limit,noisy=4, grey=_grey)
}
function RemoveDirtMC(clip,int "limit", bool "_grey")
{
  _grey=default(_grey, false)
  limit = default(limit,6)
  prefiltered = RemoveGrain(clip,2)
  superfilt = MSuper(prefiltered, hpad=32, vpad=32,pel=2)
  super=MSuper(clip, hpad=32, vpad=32,pel=2)
  bvec = MAnalyse(superfilt,isb=true,  blksize=16, overlap=2,delta=1, truemotion=true)
  fvec = MAnalyse(superfilt,isb=false, blksize=16, overlap=2,delta=1, truemotion=true)
  bvec_re = Mrecalculate(super,bvec,blksize=8, overlap=0,thSAD=100)
  fvec_re = Mrecalculate(super,fvec,blksize=8, overlap=0,thSAD=100)
  backw = MFlow(clip,super,bvec_re)
  forw  = MFlow(clip,super,fvec_re)
  clp=interleave(forw,clip,backw)
  clp=clp.RemoveDirt(limit,_grey)
  clp=clp.SelectEvery(3,1)
  return clp
}
```
Key deltas vs the canonical composition (and vs FilmRestore's current chain): **no SCSelect** (alt = spatial `RemoveGrain(2)`), `gmthreshold=40` (not 70), `dist=3`, `noisy=4`, per-pixel `MFlow` warping instead of raw neighbors, and MAnalyse→MRecalculate two-step (he reported same quality as blksize=4 at ~no perf cost). "RemoveDirtMC(25), where 25 is the strength" is his typical 8mm strength; the older single-step variant (`RemoveDirtMC_old`, blksize=16, no recalc) is the one documented on the wiki.

**Working VapourSynth port of the whole thing (verbatim, [Selur/VapoursynthScriptsInHybrid/removeDirt.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/removeDirt.py)):**
```python
def RemoveDirt(input, repmode=16, remgrainmode=17, limit=10):
  cleansed = core.zsmooth.Clense(input)          # or rgvs
  sbegin = core.zsmooth.ForwardClense(input)
  send  = core.zsmooth.BackwardClense(input)
  scenechange = core.removedirt.SCSelect(input, sbegin, send, cleansed)   # or rdvs.SCSelect
  alt     = core.zsmooth.Repair(scenechange, input, mode=[repmode,repmode,1])
  restore = core.zsmooth.Repair(cleansed, input, mode=[repmode,repmode,1])
  corrected = core.removedirt.RestoreMotionBlocks(cleansed, restore, neighbour=input, alternative=alt,
                gmthreshold=70, dist=1, dmode=2, noise=limit, noisy=12)
  return core.zsmooth.RemoveGrain(corrected, mode=[remgrainmode,remgrainmode,1])

def RemoveDirtMC(input, limit=6, repmode=16, remgrainmode=17, block_size=8, block_over=4, gpu=False):
  quad = core.zsmooth.RemoveGrain(input, mode=[12,0,1])   # blur luma for vector search
  i    = MV.Super(quad, pel=2, blksize=block_size, overlap=block_over)
  bvec = MV.Analyse(super=i, isb=True,  blksize=block_size, overlap=block_over, delta=1, truemotion=True, chroma=True)
  fvec = MV.Analyse(super=i, isb=False, blksize=block_size, overlap=block_over, delta=1, truemotion=True, chroma=True)
  backw = MV.Flow(clip=quad, super=i, vectors=[bvec])
  forw  = MV.Flow(clip=quad, super=i, vectors=[fvec])
  clp = core.std.Interleave([backw,quad,forw])
  clp = RemoveDirt(clp, repmode=2, remgrainmode=17, limit=limit)
  return core.std.SelectEvery(clp,3,1)
```
Note its inline comments from the original author: "blksize 8 is much better for 720x576 noisy source than blksize=16" and "block overlapping 0! 2 or 4 is not good for my noisy b&w 8mm source". Caveat: this port runs RemoveDirt on the *blurred* `quad` clip — johnmeyer's AVS original interleaves the unblurred `clip`; for 1440x1080 follow johnmeyer (flow-warp the real frames, search vectors on prefiltered).

**arm64 feasibility:** `RestoreMotionBlocks`/`SCSelect` ship in [pinterf/RemoveDirt](https://github.com/pinterf/RemoveDirt) v1.1 (2025-01-08, dual AviSynth+VapourSynth API4, GPL-2.0, CMake) — [Stefan-Olt/vs-plugin-build](https://github.com/Stefan-Olt/vs-plugin-build) carries `plugins/removedirt.json` building `libremovedirt.dylib` for `darwin-*` (plain cmake+make, no deps). v1.1 changelog: "Fix SCSelect (VapourSynth)" — use v1.1, not v1.0. Older `rdvs` namespace port: [Rational-Encoding-Thaumaturgy/vapoursynth-removedirt](https://github.com/Rational-Encoding-Thaumaturgy/vapoursynth-removedirt) (GPL-2.0, CMake, last push 2021, also has `DupBlocks`). MVTools: [dubhater/vapoursynth-mvtools](https://github.com/dubhater/vapoursynth-mvtools) GPL-2.0, meson, actively pushed through 2026-06, builds arm64.

## (b) Fizick's DeSpot

**What it does (from the bundled doc, [vapoursynth/despot doc/despot.html](https://github.com/vapoursynth/despot/blob/master/doc/despot.html), also [avisynth.nl/users/fizick/despot/despot.html](http://avisynth.nl/users/fizick/despot/despot.html)):** pixel-precise *spot segmentation*, not 8x8 blocks — based on Kevin Atkinson's Conditional Temporal Median Filter. Detection primitives:
- `p1` (default 24): pixel must differ from temporal neighbors by >= p1 to seed noise; `p2` (12): adjacent pixels differing >= p2 are flood-grown into the same spot; `pwidth x pheight` caps spot size; `maxpts/minpts` cap pixel count; `p1percent` = min % of high-contrast (p1) pixels per spot; `ranked` = "ranked ordered difference spot detector with 6 points instead of 2".
- `sign` — remove only dark spots (+1/+2), only light (-1/-2), or both (0). **This is the killer feature for film: positive prints have black dirt, negatives/dust on scans is white; halving the removal domain halves false positives.**
- Motion protection: separate motion map (`mthres`, block denoise `mwidth/mheight/merode` erode/dilate stages), `motpn=true` = motion detected prev→next (since v3.0), `seg` = 0/1/2 controls whether whole spots / line segments / pixels overlapping motion are spared (2 = safest), `mscene` = scene-change % cutoff, `extmask` = external protection mask clip OR-ed into the motion mask.
- Removal: temporal median restricted to detected spots, `dilate` morphological growth, `fitluma` local luminosity fixup, `blur 0-4` at spot borders, `tsmooth` optional temporal smoothing of static areas, `median=true` = plain conditional temporal median mode.
- `mc=true` (v3.6.3, Firesledge): "Uses a 3-fold interleaved stream to allow motion-compensated analysis. Only the second frame every three frames is processed... The input stream should be in the form: Interleave(forward, original, backward)". Helper from the repo (`doc/despot-helpers.avsi`, verbatim):
```avisynth
Function DeSpot_analyse_mc (clip c, string outfile, int "pel", int "blksize", string "addparam")
{
    ...
    s     = MSuper (pel=pel)
    bvec  = MAnalyse (s, isb=false, blksize=blksize, overlap=8, delta=1)
    fvec  = MAnalyse (s, isb=true, blksize=blksize, overlap=8, delta=1)
    backw = MCompensate (s, bvec)
    forw  = MCompensate (s, fvec)
    Interleave (backw, last, forw)
    Eval ("DeSpot (outfile=outfile, mc=true" + addparam + ")")
    SelectEvery (3, 1)
}
```
- `outfile` writes every detected spot to an **.ass subtitle file** (rectangles) for human review/editing — a ready-made manual-QC / supervised-removal workflow, with `spotmax1/spotmax2` sanity caps.

**VapourSynth port status — important negative finding:** [github.com/vapoursynth/despot](https://github.com/vapoursynth/despot) ("A combined VapourSynth+Avisynth version of the DeSpot filter written by Fizick et al", GPL-2.0, last commits Nov 2023) includes `VapourSynth4.h`/`VSHelper4.h` in `despot.hpp` and uses `VS_RESTRICT` throughout the core, **but the tree contains no VS entry point** (only `src/despot.cpp` = AviSynth wrapper with `AvisynthPluginInit3`, `src/despot-f.cpp` = 1602-line portable core, `msvc/` solution; zero releases). The sole open issue ("Ping": "having this filter for Vapoursynth would be really cool") confirms it never shipped. **No usable VS DeSpot exists anywhere.** arm64 feasibility of finishing it: high — the core is plain C++ (zero SIMD intrinsics, zero asm; I grepped), ~2200 lines total; needs a VS4 filter wrapper + meson file; only Windows-ism is `__declspec` in the AVS wrapper you'd discard. GPL-2.0 is compatible with the app's GPL-3.0. This is the single highest-value "code a new solution" target from the classic ecosystem: pixel-precise spots + `sign` + `extmask` + MC interleave + ASS-outfile review, none of which RemoveDirt/SpotLess offer.

## (c) KillerSpots / SpotLess variants / helpers / JET

**KillerSpots** (orig. Didée's SpotRemover idea, [doom9 p=1402690](https://forum.doom9.org/showthread.php?p=1402690#post1402690), adapted by GMJCZP, maintained as [FranceBB/KillerSpots](https://github.com/FranceBB/KillerSpots) v2.0; VS port verbatim in [Selur killerspots.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/killerspots.py)):
```python
def KillerSpots(clip, limit=10, advanced=False):
  osup = MV.Super(clip=clip, pel=2, sharp=2, blksize=8, overlap=4)
  bv1  = MV.Analyse(super=osup, isb=True,  delta=1, blksize=8, overlap=4, search=4)
  fv1  = MV.Analyse(super=osup, isb=False, delta=1, blksize=8, overlap=4, search=4)
  bc1  = MV.Compensate(clip, osup, bv1)
  fc1  = MV.Compensate(clip, osup, fv1)
  clip = core.std.Interleave([fc1, clip, bc1])
  clip = RemoveDirtMod(clip, limit) if advanced else core.zsmooth.Clense(clip)
  return core.std.SelectEvery(clip=clip, cycle=3, offsets=1)

def RemoveDirtMod(clip, limit=10):   # "original adaptation thanks to johnmeyer"
  clensed = core.zsmooth.Clense(clip)
  alt = core.zsmooth.RemoveGrain(clip, mode=1)
  return core.rdvs.RestoreMotionBlocks(clensed, clip, alternative=alt,
           pthreshold=4, cthreshold=6, gmthreshold=40, dist=3, dmode=2, noise=limit, noisy=12)
```
i.e., MCompensate-interleaved Clense (simple mode) or MC RestoreMotionBlocks (advanced). Difference vs RemoveDirtMC: `Compensate` (block copy, robust to bad vectors) instead of `Flow` (per-pixel warp, smoother but smears on vector errors).

**SpotLess** (StainlessS, [doom9 t=181777](https://forum.doom9.org/showthread.php?t=181777)): MCompensate ±1..radT + temporal median over 2*radT+1 aligned frames. AVS defaults: RadT=1, ThSAD=4080, ThSAD2=ThSAD-64, pel=2, blksize=8, overlap=blksize/2, chroma=true. Community caveats from the thread: not for anime; RadT too high blurs; **several users report `tm=false` (truemotion off) works better on fast motion** — worth exposing in FilmRestore since the current SpotLess path presumably uses truemotion defaults.

**SpotLessDelta / SpotDelta** (chmars 2021, [doom9 p=1946031](https://forum.doom9.org/showthread.php?p=1946031); full VS port verbatim in [Selur SpotLess.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/SpotLess.py)) — the most interesting SpotLess evolution and directly relevant to "hit and miss": instead of trusting the median output, it computes **delta masks** between source and SpotLess result and only accepts changes that look like dirt:
- `_luma_delta_mask` — pixels where source deviates from filtered beyond a brightness-ratio threshold, direction-aware ('<' = bright dust on scans, '>' = dark dirt), with `_remove_small_spots` (N x erode + Hysteresis restore) to kill 1-px grain hits;
- `_chroma_delta_mask` — Euclidean sqrt(du²+dv²) chroma outliers;
- `_scharr` edge mask + `_must_not_overlap` (Hysteresis-based) so repairs never touch real edges;
- `_delta_restore` = `MaskedMerge(filtered, source, mask, first_plane=True)` — i.e., **keep the original everywhere except confirmed dirt**, the inverse of blanket temporal filtering;
- `_restore_grain(val1=10, val2=20)` — soft-limited MakeDiff/Expr grain re-injection so cleaned areas keep film texture;
- outputs stacked/interleaved comparison modes for tuning. Deps: mvtools, tmedian (or zsmooth), misc/hysteresis, akarin (falls back to `std.Expr`). All arm64-available.

**LostFunc/havsfunc:** the despot-relevant pieces of havsfunc/lostfunc are exactly the RemoveDirt/SpotLess derivatives above (Selur's repo is the maintained collection point); no additional distinct algorithm found.

**JET / vs-jetpack ([github](https://github.com/Jaded-Encoding-Thaumaturgy/vs-jetpack/), [docs](https://jaded-encoding-thaumaturgy.github.io/vs-jetpack/)):** vsdenoise is deprecated into vs-jetpack; it provides modern typed MVTools wrappers (mvtools submodule with presets, motion-compensated degrain), BM3D/DFTTest/NLM, vsmasktools, vsrgtools — but **no dedicated film-dirt/despot function**. The JET ecosystem is anime/encode-focused; for film dirt the community still points back to RemoveDirt/SpotLess. Worth borrowing: their MVTools preset machinery and mask tooling, not a cleanup algorithm.

## (d) Concrete community workflows for 8mm/16mm/35mm scans

1. **johnmeyer's 8mm chain** ([doom9 t=165975](https://forum.doom9.org/showthread.php?t=165975), script reposted verbatim at [videohelp 378183](https://forum.videohelp.com/threads/378183-8mm-restoration-script-question)): DePanEstimate/DePanStabilize (on a cropped, contrast-boosted estimate clip, `est_cont=1.6`) → `RemoveDirtMC` (two-step MAnalyse/MRecalculate + MFlow, strength ~23-30 via `dirt_strength`) → `MDegrain2(thSAD=600, blksize=8, overlap=4)` (thSAD 300-3000 by grain level; MDegrain3 for worst) → UnsharpMask(120,3) → levels/tweak → optional MFlowFps/InterFrame. Plus his `filldrops` function (MFlowInter-interpolated replacement of duplicated damaged frames) — a cheap manual-repair tool FilmRestore lacks.
2. **videoFred's restoration script** (same thread lineage, [doom9 t=144271](https://forum.doom9.org/archive/index.php/t-144271.html)): border removal → stabilize → RemoveDirt/RemoveDirtMC → MDegrain2/3 → four-step sharpening (UnsharpMask pre-sharp + LimitedSharpenFaster) → autolevels/autowhite variants with side-by-side comparison outputs (`resultS1..S4` stackhorizontal against source — good UI idea for FilmRestore's A/B). Fred: "averaging many frames (10) in MVDegrainMulti() is also removing lots of dirt spots".
3. **Selur's Hybrid (VapourSynth, current)**: deflicker → choice of DeSpot(AVS-only)/KillerSpots/SpotLess/RemoveDirtMC via the exact .py files quoted above; his ranking from [forum.selur.net thread-2850](https://forum.selur.net/thread-2850.html): "DeSpot is probably the most aggressive of them, then SpotLess and then KillerSpots"; he personally favors DeSpot and KillerSpots, rarely SpotLess; notes RemoveDirt was "partially broken in Vapoursynth" (pre-pinterf-v1.1 era — fixed by v1.1's SCSelect fix).
4. **doom9 SpotLess practice**: RadT 2-3, `tm=false`, ThSAD ~4080 baseline, plus SpotDelta mask-gating for grain-preserving cleanup ([t=181777](https://forum.doom9.org/showthread.php?t=181777)).

## (e) arm64/macOS feasibility + license matrix

| Component | Source/prebuilt | Build | arm64 status | License |
|---|---|---|---|---|
| pinterf/RemoveDirt v1.1 (removedirt ns, AVS+VS4) | [repo](https://github.com/pinterf/RemoveDirt) | CMake, no deps | vs-plugin-build has darwin recipe (`libremovedirt.dylib`); trivial local build | GPL-2.0 |
| RET vapoursynth-removedirt (rdvs ns) | [repo](https://github.com/Rational-Encoding-Thaumaturgy/vapoursynth-removedirt) | CMake | compiles clean; unmaintained since 2021 | GPL-2.0 |
| DeSpot (Fizick/Firesledge 3.6.3) | [vapoursynth/despot](https://github.com/vapoursynth/despot) | MSVC only; **VS wrapper missing** | portable C++ (no SIMD/asm) — write VS4 glue + meson, ~1-2 days | GPL-2.0 |
| MVTools v24 | [dubhater](https://github.com/dubhater/vapoursynth-mvtools) | meson | active (2026), arm64 OK (already in app) | GPL-2.0 |
| zsmooth (Clense/Repair/RemoveGrain/TemporalMedian/TemporalRepair/TTempSmooth/DegrainMedian/FluxSmooth/InterQuartileMean/Median/CCD) | [adworacz/zsmooth](https://github.com/adworacz/zsmooth) | Zig, prebuilt macos-aarch64 releases | native | MIT |
| misc (SCDetect/Hysteresis), tmedian, motionmask, rgvs | [vs-plugin-build plugins/](https://github.com/Stefan-Olt/vs-plugin-build) | per-recipe | darwin-aarch64 recipes exist | mixed GPL/MIT |
| KillerSpots 2.0 (script) | [FranceBB/KillerSpots](https://github.com/FranceBB/KillerSpots) / [Selur port](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/killerspots.py) | pure script | runs today on existing plugin set | no SPDX license declared (AVSI); Selur repo scripts unlicensed — check before bundling |
| SpotLess/SpotDelta (script) | [Selur SpotLess.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/SpotLess.py) | pure script; akarin optional (std.Expr fallback) | runs today | same caveat |

## Actionable ranking for FilmRestore (given "hit and miss" verdict)

1. **Adopt johnmeyer's RestoreMotionBlocks parameterization + MFlow-MC front end** (gmthreshold=40, dist=3, noisy=4, alt=RemoveGrain(2), two-step MAnalyse+MRecalculate on prefiltered super) — pure .vpy change, zero new plugins; directly targets the global-motion shutoff that makes block-based cleaning erratic on 35mm.
2. **Implement SpotDelta-style delta-mask gating** around the existing SpotLess path (Selur's SpotLess.py is a complete VS reference implementation): edge-protected, direction-aware (dark-dirt-only for prints), small-spot-eroded masks + grain restore. Pure Python/Expr; biggest expected quality jump for "restore only what is provably dirt".
3. **Finish the DeSpot VS port** (vapoursynth/despot core + new VS4 wrapper, meson, GPL-2): pixel-precise spots, `sign`, `extmask`, MC interleave mode, ASS outfile for human review — the only classic filter whose detection is per-spot rather than per-block/per-pixel-median.
4. Expose `tm=false`, RadT, and blksize/overlap in the SpotLess UI; add `filldrops`-style single-frame MFlowInter repair.

(ML side, briefly: no community-standard VS-integrated dirt-removal model exists; the known research repos are "Bringing Old Films Back to Life" (raywzy, CVPR 2022) and DeepRemaster (Iizuka, SIGGRAPH Asia 2019) — neither was fetched/verified in this session; treat as leads for the ML angle.)

Sources: [avisynth.nl RemoveDirt](http://avisynth.nl/index.php/RemoveDirt) · [pinterf/RemoveDirt](https://github.com/pinterf/RemoveDirt) · [Selur removeDirt.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/removeDirt.py) · [Selur killerspots.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/killerspots.py) · [Selur SpotLess.py](https://github.com/Selur/VapoursynthScriptsInHybrid/blob/master/SpotLess.py) · [vapoursynth/despot](https://github.com/vapoursynth/despot) · [avisynth.nl DeSpot](http://avisynth.nl/index.php/DeSpot) · [Fizick DeSpot doc](http://avisynth.nl/users/fizick/despot/despot.html) · [Selur forum thread-2850](https://forum.selur.net/thread-2850.html) · [videohelp 378183](https://forum.videohelp.com/threads/378183-8mm-restoration-script-question) · [doom9 t=165975](https://forum.doom9.org/showthread.php?t=165975) · [doom9 t=144271](https://forum.doom9.org/archive/index.php/t-144271.html) · [doom9 SpotLess t=181777](https://forum.doom9.org/showthread.php?t=181777) · [doom9 SpotRemover p=1402690](https://forum.doom9.org/showthread.php?p=1402690#post1402690) · [FranceBB/KillerSpots](https://github.com/FranceBB/KillerSpots) · [realfinder RemoveDirtMC_SE](https://github.com/realfinder/AVS-Stuff/blob/Community/avs%202.5%20and%20up/RemoveDirtMC_SE.avsi) · [Stefan-Olt/vs-plugin-build](https://github.com/Stefan-Olt/vs-plugin-build) · [adworacz/zsmooth](https://github.com/adworacz/zsmooth) · [dubhater/vapoursynth-mvtools](https://github.com/dubhater/vapoursynth-mvtools) · [RET vapoursynth-removedirt](https://github.com/Rational-Encoding-Thaumaturgy/vapoursynth-removedirt) · [vs-jetpack](https://github.com/Jaded-Encoding-Thaumaturgy/vs-jetpack/) · [vs-jetpack docs](https://jaded-encoding-thaumaturgy.github.io/vs-jetpack/)