# spotless.py — Didée's SpotLess motion-compensated dirt removal (advanced
# engine, ADR-12). Algorithm shape follows VapourBox's template (GPL-3.0):
# MVTools Super/Analyse/Compensate both directions + temporal median (zsmooth,
# NEON). Benchmarked 75 fps at radT=1 on 1440x1080 (spike S2).

import vapoursynth as vs

core = vs.core


def spotless(clip, radT=1, thsad=10000, pel=2, blksize=8):
    if not (1 <= radT <= 3):
        raise ValueError("spotless: radT must be 1..3")
    sup = core.mv.Super(clip, pel=pel)
    backward = []
    forward = []
    for delta in range(1, radT + 1):
        bv = core.mv.Analyse(sup, isb=True, delta=delta,
                             blksize=blksize, overlap=blksize // 2)
        fv = core.mv.Analyse(sup, isb=False, delta=delta,
                             blksize=blksize, overlap=blksize // 2)
        backward.append(core.mv.Compensate(clip, sup, bv, thsad=thsad))
        forward.append(core.mv.Compensate(clip, sup, fv, thsad=thsad))
    # order: most-distant forward … clip … most-distant backward
    sequence = list(reversed(forward)) + [clip] + backward
    interleaved = core.std.Interleave(sequence)
    med = core.zsmooth.TemporalMedian(interleaved, radius=radT)
    return med.std.SelectEvery(cycle=len(sequence), offsets=radT)
