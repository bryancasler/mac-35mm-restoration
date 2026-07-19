# maskclean.py — detect → mask → conceal dirt removal (FilmRestore's own engine).
#
# The architecture every professional tool uses (DVO Dust, MTI Shine, Resolve
# ADR, DIAMANT — see docs/research/3-pro-tools.md) and none of the classic VS
# filters do: build an explicit, reviewable defect mask from motion-compensated
# temporal evidence, apply safety filters to the mask, then conceal ONLY inside
# the mask. Pixels outside the mask pass through bit-exact — film grain and real
# detail are untouched by construction.
#
# Detector: the classic spike/blotch test (Kokaram SDIa family, tuned constants
# from Fizick's DeSpot; docs/research/4-custom-algo-design.md):
#   dirt at pixel p  ⟺  |cur−compPrev| > t1  AND  |cur−compNext| > t1
#                      AND |compPrev−compNext| < t2      (references agree)
#                      AND sign(cur−compPrev) == sign(cur−compNext)  (a spike)
# plus optional polarity restriction (dark-only for prints, bright-only for
# negative scans — halves false positives).
#
# Optional blob stage (numpy + opencv-headless from the app-managed pysite dir):
# connected-component area gating — drop grain-sized specks and object-sized
# regions (the "birds problem"). Degrades gracefully when cv2 is absent.

import vapoursynth as vs

core = vs.core

try:
    import numpy as np
    import cv2
    _HAVE_CV2 = True
except ImportError:
    _HAVE_CV2 = False


def _median3(clips):
    # per-pixel median of three: max(min(x,y), min(max(x,y), z))
    return core.std.Expr(clips, ["x y min x y max z min max"] * clips[0].format.num_planes)


def _luma(clip):
    return core.std.ShufflePlanes(clip, planes=0, colorfamily=vs.GRAY)


def maskclean(clip, t1=24, t2=14, polarity="both",
              min_size=2, max_size=600, dilate=1, sad_max=None, adj_radius=3,
              preview_mask=False, blob_filter=True, return_mask=False,
              ml_mask=None):
    if clip.format.color_family != vs.YUV or clip.format.bits_per_sample != 8:
        raise ValueError("maskclean: 8-bit YUV input only (pipeline is yuv420p)")
    if polarity not in ("both", "dark", "bright"):
        raise ValueError("maskclean: polarity must be both/dark/bright")

    # --- motion-compensated references (same two-step search as RemoveDirtMC)
    prefiltered = core.zsmooth.RemoveGrain(clip, mode=[2, 2, 2])
    supf = core.mv.Super(prefiltered, hpad=32, vpad=32, pel=2)
    sup = core.mv.Super(clip, hpad=32, vpad=32, pel=2)
    bv = core.mv.Analyse(supf, isb=True, blksize=16, overlap=2, delta=1, truemotion=True)
    fv = core.mv.Analyse(supf, isb=False, blksize=16, overlap=2, delta=1, truemotion=True)
    bv = core.mv.Recalculate(sup, bv, blksize=8, overlap=0, thsad=100)
    fv = core.mv.Recalculate(sup, fv, blksize=8, overlap=0, thsad=100)
    comp_p = core.mv.Compensate(clip, sup, bv)
    comp_n = core.mv.Compensate(clip, sup, fv)
    # scene-change props for the safety zero (cut safety — DVO "Cut Safety")
    sc = core.mv.SCDetection(clip, bv)

    # --- pixel detector on luma
    y, yp, yn = _luma(clip), _luma(comp_p), _luma(comp_n)
    conds = [f"x y - abs {t1} >", f"x z - abs {t1} >", f"y z - abs {t2} <",
             "x y - x z - * 0 >"]
    if polarity == "dark":
        conds.append("x y - 0 <")
    elif polarity == "bright":
        conds.append("x y - 0 >")
    expr = " ".join(conds) + " and" * (len(conds) - 1) + " 255 0 ?"
    mask = core.std.Expr([y, yp, yn], expr)

    # --- optional SAD guard, OFF by default: block SAD includes the current
    # frame, so defects inflate it and suppress their own detection (measured:
    # recall → 0). The |compP−compN| cross-check above is the correct
    # occlusion guard — it excludes the current frame (DeSpot's motpn design).
    if sad_max is not None:
        sad_b = _luma(core.mv.Mask(clip, bv, kind=1))
        sad_f = _luma(core.mv.Mask(clip, fv, kind=1))
        mask = core.std.Expr([mask, sad_b, sad_f],
                             f"y {sad_max} > z {sad_max} > or 0 x ?")

    # --- mask hygiene (native): opening kills grain-sized hits
    for _ in range(max(0, min_size)):
        mask = core.std.Minimum(mask)
    for _ in range(max(0, min_size)):
        mask = core.std.Maximum(mask)

    # --- BBC US5978047 adjacent-frame suppression: real dirt is temporally
    # isolated; a blob that appears near the same spot in the PREVIOUS or NEXT
    # frame's mask is erratic motion — drop it
    if adj_radius:
        prev_m = mask[0] + mask[:-1]
        next_m = mask[1:] + mask[-1]
        adj = core.std.Expr([prev_m, next_m], "x y max")
        for _ in range(adj_radius):
            adj = core.std.Maximum(adj)
        mask = core.std.Expr([mask, adj], "y 0 > 0 x ?")

    # --- optional blob stage: area gating via connected components
    if blob_filter and _HAVE_CV2:
        lo, hi = int(min_size * min_size), int(max_size)

        def _gate(n, f):
            fout = f.copy()
            m = np.asarray(f[0])
            count, labels, stats, _ = cv2.connectedComponentsWithStats(
                (m > 0).astype(np.uint8), connectivity=8)
            keep = np.zeros_like(m)
            for i in range(1, count):
                area = stats[i, cv2.CC_STAT_AREA]
                if lo <= area <= hi:
                    keep[labels == i] = 255
            np.asarray(fout[0])[:] = keep
            return fout

        mask = core.std.ModifyFrame(mask, mask, _gate)

    # --- dilate + feather for the merge
    for _ in range(max(0, dilate)):
        mask = core.std.Maximum(mask)
    mask = core.std.BoxBlur(mask, hradius=1, vradius=1)

    # --- cut safety: zero the mask on scene-change frames
    blank = core.std.BlankClip(mask)
    inner_mask = mask  # bind pre-FrameEval node (late-binding closure trap)

    def _cut_safety(n, f):
        props = f.props
        if props.get("_SceneChangePrev", 0) or props.get("_SceneChangeNext", 0):
            return blank
        return inner_mask

    mask = core.std.FrameEval(mask, _cut_safety, prop_src=sc)

    if return_mask:
        return mask

    if preview_mask:
        # red overlay where dirt is detected (Resolve's "Show Repair Mask");
        # ML scratch regions (if provided) in yellow
        red = core.std.BlankClip(clip, color=[81, 90, 240])  # red in YUV
        out = core.std.MaskedMerge(clip, red, mask, first_plane=True)
        if ml_mask is not None:
            yellow = core.std.BlankClip(clip, color=[210, 16, 146])
            out = core.std.MaskedMerge(out, yellow, ml_mask, first_plane=True)
        return out

    # --- concealment: median of aligned (prev, cur, next) inside the mask only
    fill = _median3([clip, comp_p, comp_n])
    out = core.std.MaskedMerge(clip, fill, mask, first_plane=True)

    # --- ML scratch regions: persistent defects appear in ALL aligned frames,
    # so the temporal median can't remove them — spatial inpaint instead
    if ml_mask is not None:
        out = _spatial_inpaint(out, ml_mask)
    return out


def _spatial_inpaint(clip, mask, radius=3):
    """cv2.inpaint (Telea) of masked regions; falls back to the input when
    cv2 is unavailable. mask: GRAY8 clip, same dimensions as clip's luma."""
    if not _HAVE_CV2:
        return clip
    mask = core.std.Maximum(mask)   # small margin around the scratch

    def _paint(n, f):
        m = np.asarray(f[1][0])
        if not m.any():
            return f[0]
        fout = f[0].copy()
        mb = (m > 0).astype(np.uint8)
        y = np.asarray(fout[0])
        y[:] = cv2.inpaint(y, mb, radius, cv2.INPAINT_TELEA)
        # chroma at subsampled resolution
        sub_w = fout.format.subsampling_w
        sub_h = fout.format.subsampling_h
        if sub_w or sub_h:
            mc = mb[::1 << sub_h, ::1 << sub_w]
        else:
            mc = mb
        for p in (1, 2):
            c = np.asarray(fout[p])
            c[:] = cv2.inpaint(c, np.ascontiguousarray(mc), radius, cv2.INPAINT_TELEA)
        return fout

    return core.std.ModifyFrame(clip, [clip, mask], _paint)
