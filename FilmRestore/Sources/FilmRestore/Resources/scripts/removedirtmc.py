# removedirtmc.py — johnmeyer's RemoveDirtMC, VapourSynth port.
# The community-standard motion-compensated dirt cleaner for film scans
# (videohelp thread 378183 posts #5-6; provenance + analysis in
# docs/research/1-vs-community.md).
#
# Why this beats the classic composition: RestoreMotionBlocks detects motion by
# comparing RAW prev/next neighbors — camera motion floods it and cleaning
# shuts off (the "static shots clean, moving shots don't" failure). Here the
# neighbors are per-pixel Flow-warped into alignment with the current frame
# first, so the detector sees residual defects, not global motion.
#
# Port notes (deliberate deltas from Selur's removeDirt.py port):
# - the warped/interleaved frames are the UNBLURRED originals (johnmeyer's AVS
#   original); the blurred clip is used only for the vector search
# - zsmooth provides Clense/RemoveGrain (NEON) — no RGVS dependency

import vapoursynth as vs

core = vs.core


def _remove_dirt(interleaved, strength):
    # johnmeyer's inner RemoveDirt: no SCSelect (alt = spatial RemoveGrain(2)),
    # gmthreshold=40, dist=3, noisy=4, border-line un-cleaning thresholds 6/8
    cleansed = core.zsmooth.Clense(interleaved)
    alt = core.zsmooth.RemoveGrain(interleaved, mode=[2, 2, 2])
    return core.removedirt.RestoreMotionBlocks(
        cleansed, interleaved, alternative=alt,
        pthreshold=6, cthreshold=8, gmthreshold=40,
        dist=3, dmode=2, noise=strength, noisy=4)


def remove_dirt_mc(clip, strength=8, blksize=16, refine_blksize=8):
    if clip.format.color_family != vs.YUV:
        raise ValueError("remove_dirt_mc: YUV input only")
    # vector search on a prefiltered copy; refine on the clean frames
    prefiltered = core.zsmooth.RemoveGrain(clip, mode=[2, 2, 2])
    superfilt = core.mv.Super(prefiltered, hpad=32, vpad=32, pel=2)
    sup = core.mv.Super(clip, hpad=32, vpad=32, pel=2)
    bvec = core.mv.Analyse(superfilt, isb=True, blksize=blksize, overlap=2,
                           delta=1, truemotion=True)
    fvec = core.mv.Analyse(superfilt, isb=False, blksize=blksize, overlap=2,
                           delta=1, truemotion=True)
    bvec = core.mv.Recalculate(sup, bvec, blksize=refine_blksize, overlap=0,
                               thsad=100)
    fvec = core.mv.Recalculate(sup, fvec, blksize=refine_blksize, overlap=0,
                               thsad=100)
    backw = core.mv.Flow(clip, sup, bvec)
    forw = core.mv.Flow(clip, sup, fvec)
    interleaved = core.std.Interleave([forw, clip, backw])
    cleaned = _remove_dirt(interleaved, strength)
    return core.std.SelectEvery(cleaned, cycle=3, offsets=1)
