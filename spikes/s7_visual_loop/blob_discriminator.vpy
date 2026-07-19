# Discriminator diagnostic (S7 iter13): for one frame (env FRAME), rebuild the
# maskclean detector head (MC refs + spike test + chroma OR + opening) and
# print stats for every over-cap component (area > 600) of the TARGET frame:
#   area, anomaly p90 (blob-guard metric), refdiff p90 (|compP-compN|),
#   neighbor-mask pixels within a 48px-padded bbox (large-radius isolation).
# Purpose: find a gate that separates the frame-14654 debris clump (single-
# frame transient) from the 15461-15503 leaf swirls (fast content) so the
# mcMaxSize cap can gain a safe exception path.
import os
import sys

sys.path.insert(0, os.path.expanduser("~/Library/Application Support/FilmRestore/pysite"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "FilmRestore", "Sources", "FilmRestore",
                                "Resources", "scripts"))
import cv2
import numpy as np
import vapoursynth as vs

core = vs.core

FRAME = int(os.environ["FRAME"])
T1, T2, T1C, T2C = 24, 22, 12, 10
MIN_SIZE, CAP = 2, 600

clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
win = clip[FRAME - 3:FRAME + 4]  # 7 frames, target at index 3

# --- identical MC construction to maskclean()
prefiltered = core.zsmooth.RemoveGrain(win, mode=[2, 2, 2])
supf = core.mv.Super(prefiltered, hpad=32, vpad=32, pel=2)
sup = core.mv.Super(win, hpad=32, vpad=32, pel=2)
bv = core.mv.Analyse(supf, isb=True, blksize=16, overlap=2, delta=1, truemotion=True)
fv = core.mv.Analyse(supf, isb=False, blksize=16, overlap=2, delta=1, truemotion=True)
bv = core.mv.Recalculate(sup, bv, blksize=8, overlap=0, thsad=100)
fv = core.mv.Recalculate(sup, fv, blksize=8, overlap=0, thsad=100)
comp_p = core.mv.Compensate(win, sup, bv)
comp_n = core.mv.Compensate(win, sup, fv)


def _luma(c):
    return core.std.ShufflePlanes(c, planes=0, colorfamily=vs.GRAY)


def _plane(c, i):
    return core.std.ShufflePlanes(c, planes=i, colorfamily=vs.GRAY)


y, yp, yn = _luma(win), _luma(comp_p), _luma(comp_n)
conds = [f"x y - abs {T1} >", f"x z - abs {T1} >", f"y z - abs {T2} <",
         "x y - x z - * 0 >"]
expr = " ".join(conds) + " and" * (len(conds) - 1) + " 255 0 ?"
mask = core.std.Expr([y, yp, yn], expr)
cexpr = (f"x y - abs {T1C} > x z - abs {T1C} > and y z - abs {T2C} < and "
         f"x y - x z - * 0 > and "
         f"a b - abs {T1C} > a c - abs {T1C} > and b c - abs {T2C} < and "
         f"a b - a c - * 0 > and or 255 0 ?")
cmask = core.std.Expr([_plane(win, 1), _plane(comp_p, 1), _plane(comp_n, 1),
                       _plane(win, 2), _plane(comp_p, 2), _plane(comp_n, 2)], cexpr)
cmask = core.resize.Point(cmask, width=mask.width, height=mask.height)
mask = core.std.Expr([mask, cmask], "x y max")
for _ in range(MIN_SIZE):
    mask = core.std.Minimum(mask)
for _ in range(MIN_SIZE):
    mask = core.std.Maximum(mask)

yblur = core.std.BoxBlur(y, hradius=4, vradius=4)
u = core.resize.Point(_plane(win, 1), width=y.width, height=y.height)
v = core.resize.Point(_plane(win, 2), width=y.width, height=y.height)
ublur = core.std.BoxBlur(u, hradius=4, vradius=4)
vblur = core.std.BoxBlur(v, hradius=4, vradius=4)

prev_m = mask[0] + mask[:-1]
next_m = mask[1:] + mask[-1]


def cb(n, f):
    if n != 3:
        return f[0]
    m = np.asarray(f[0][0])
    yv = np.asarray(f[1][0]).astype(np.int16)
    bl = np.asarray(f[2][0]).astype(np.int16)
    uv_ = np.asarray(f[3][0]).astype(np.int16)
    ub = np.asarray(f[4][0]).astype(np.int16)
    vv = np.asarray(f[5][0]).astype(np.int16)
    vb = np.asarray(f[6][0]).astype(np.int16)
    pm = np.asarray(f[7][0])
    nm = np.asarray(f[8][0])
    ypv = np.asarray(f[9][0]).astype(np.int16)
    ynv = np.asarray(f[10][0]).astype(np.int16)
    anomaly = np.maximum(np.abs(yv - bl), (np.abs(uv_ - ub) + np.abs(vv - vb)) * 3 // 2)
    refdiff = np.abs(ypv - ynv)
    count, labels, stats, cents = cv2.connectedComponentsWithStats(
        (m > 0).astype(np.uint8), connectivity=8)
    H, W = m.shape
    rows = []
    for i in range(1, count):
        area = int(stats[i, cv2.CC_STAT_AREA])
        if area <= CAP:
            continue
        comp = labels == i
        x0 = max(0, stats[i, cv2.CC_STAT_LEFT] - 48)
        y0 = max(0, stats[i, cv2.CC_STAT_TOP] - 48)
        x1 = min(W, stats[i, cv2.CC_STAT_LEFT] + stats[i, cv2.CC_STAT_WIDTH] + 48)
        y1 = min(H, stats[i, cv2.CC_STAT_TOP] + stats[i, cv2.CC_STAT_HEIGHT] + 48)
        rows.append((area,
                     float(np.percentile(anomaly[comp], 90)),
                     float(np.percentile(refdiff[comp], 90)),
                     int((pm[y0:y1, x0:x1] > 0).sum()),
                     int((nm[y0:y1, x0:x1] > 0).sum()),
                     int(cents[i][0]), int(cents[i][1])))
    print(f"FRAME {FRAME}: {len(rows)} over-cap blobs", file=sys.stderr, flush=True)
    for area, an, rd, pa, na, cx, cy in sorted(rows, key=lambda t: -t[0]):
        print(f"  area={area:6d} @({cx:4d},{cy:4d}) anomaly_p90={an:5.1f} "
              f"refdiff_p90={rd:5.1f} nbr_mask_px prev={pa:5d} next={na:5d}",
              file=sys.stderr, flush=True)
    return f[0]


out = core.std.ModifyFrame(y, [mask, y, yblur, u, ublur, v, vblur,
                               prev_m, next_m, yp, yn], cb)
out.set_output()
