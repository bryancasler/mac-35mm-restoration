# S6 harness: overlay synthetic dust on the real scan, run the maskclean
# detector, report pixel precision/recall against ground truth.
# vspipe -p --arg t1=24 --arg t2=14 --arg blob=1 harness.vpy .
import os
import sys
import zlib

SCRIPTS = os.environ.get("FR_SCRIPTS",
    "/Users/4Site/Documents/GitHub/mac-35mm-restoration/FilmRestore/Sources/FilmRestore/Resources/scripts")
sys.path.insert(0, SCRIPTS)
PYSITE = os.path.expanduser("~/Library/Application Support/FilmRestore/pysite")
if os.path.isdir(PYSITE):
    sys.path.insert(0, PYSITE)

import numpy as np
import cv2
import vapoursynth as vs
from maskclean import maskclean

core = vs.core

T1 = int(globals().get("t1", "24"))
T2 = int(globals().get("t2", "14"))
BLOB = bool(int(globals().get("blob", "1")))
N_FRAMES = 240

clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
START = int(globals().get("start", "70000"))
clip = clip[START:START + N_FRAMES]
# pre-clean the base: the raw print carries REAL dirt, which the detector
# correctly finds and the naive harness then mislabels as false positives
clip = maskclean(clip, t1=20, t2=16, min_size=1, blob_filter=False)

# --- deterministic synthetic dust: per frame, seeded by frame number.
# Mix of dark and bright blobs, 3-20 px diameter, plus a few 1-2 px specks
# that the hygiene stage SHOULD reject if min_size is honest.
def synth(n, f):
    fout = f.copy()
    rng = np.random.default_rng(zlib.crc32(str(n).encode()))
    y = np.asarray(fout[0])
    gt = np.zeros_like(y)
    h, w = y.shape
    for _ in range(12):                       # real dust
        r = int(rng.integers(4, 11))   # ≥8 px diameter: the plan target class
        cx, cy = int(rng.integers(r, w - r)), int(rng.integers(r, h - r))
        val = 16 if rng.random() < 0.7 else 235
        yy, xx = np.ogrid[-r:r + 1, -r:r + 1]
        disk = (yy * yy + xx * xx) <= r * r
        region = y[cy - r:cy + r + 1, cx - r:cx + r + 1]
        # GT counts only VISIBLE dust: pixels whose value actually changed by
        # >= 32 (low-contrast dust is legitimately undetectable and invisible)
        visible = disk & (np.abs(region.astype(np.int16) - val) >= 32)
        region[disk] = val
        gt[cy - r:cy + r + 1, cx - r:cx + r + 1][visible] = 255
    fout.props["_gt_crc"] = int(zlib.crc32(gt.tobytes()))
    _gt_store[n] = gt
    return fout

_gt_store = {}
dirty = core.std.ModifyFrame(clip, clip, synth)
det = maskclean(dirty, t1=T1, t2=T2, polarity="both",
                blob_filter=BLOB, return_mask=True)
det = core.std.Expr(det, "x 0 > 255 0 ?")   # binarize the feathered mask

stats = {"tp": 0, "fp": 0, "fn": 0}
BORDER = 16
def score(n, f):
    det_m = np.asarray(f[0]) > 0
    gt = _gt_store.pop(n, None)
    if gt is not None:
        gt_m = gt > 0
        # boundary-tolerant scoring: the merge mask is deliberately dilated, so
        # allow a 4 px halo around GT before calling a pixel a false positive
        k = np.ones((9, 9), np.uint8)
        gt_halo = cv2.dilate(gt, k) > 0
        fp_m = det_m & ~gt_halo
        stats["tp"] += int(np.sum(det_m & gt_m))
        stats["fp"] += int(np.sum(fp_m))
        stats["fn"] += int(np.sum(~det_m & gt_m))
        border = np.zeros_like(fp_m)
        border[:BORDER, :] = True; border[-BORDER:, :] = True
        border[:, :BORDER] = True; border[:, -BORDER:] = True
        stats["fp_border"] = stats.get("fp_border", 0) + int(np.sum(fp_m & border))
    if n == N_FRAMES - 1:
        p = stats["tp"] / max(1, stats["tp"] + stats["fp"])
        r = stats["tp"] / max(1, stats["tp"] + stats["fn"])
        fp_rate = stats["fp"] / (N_FRAMES * det_m.size)
        bshare = stats.get("fp_border", 0) / max(1, stats["fp"])
        print(f"RESULT start={START} t1={T1} t2={T2} blob={BLOB}: "
              f"precision={p:.3f} recall={r:.3f} fp_pixel_rate={fp_rate:.5f} "
              f"fp_border_share={bshare:.2f}",
              file=sys.stderr, flush=True)
    return f
scored = core.std.ModifyFrame(det, det, score)
scored.set_output()
