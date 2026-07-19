# Scan 10:00-11:00 for white vertical gashes: bright anomalies whose connected
# components are tall (h>=25), thin (h/w >= 3), reported per frame.
import os, sys
sys.path.insert(0, os.path.expanduser("~/Library/Application Support/FilmRestore/pysite"))
import numpy as np, cv2
import vapoursynth as vs
core = vs.core
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
START, END, STRIDE = 14386, 15826, 2
clip = clip[START:END:STRIDE]
y = core.std.ShufflePlanes(clip, planes=0, colorfamily=vs.GRAY)
blur = core.std.BoxBlur(y, hradius=4, vradius=4)
results = []
def cb(n, f):
    yv = np.asarray(f[0][0]).astype(np.int16)
    bl = np.asarray(f[1][0]).astype(np.int16)
    anom = ((yv - bl) > 20).astype(np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(anom, connectivity=8)
    score = 0
    for i in range(1, count):
        w = stats[i, cv2.CC_STAT_WIDTH]; h = stats[i, cv2.CC_STAT_HEIGHT]
        if h >= 25 and h >= 3 * max(1, w) and w <= 12:
            score += h
    if score > 0:
        results.append((START + n * STRIDE, score))
    if n == y.num_frames - 1:
        for fr, sc in sorted(results, key=lambda t: -t[1])[:12]:
            print(f"GASH frame {fr}: score {sc}", file=sys.stderr, flush=True)
        if not results:
            print("GASH none found", file=sys.stderr, flush=True)
    return f[0]
out = core.std.ModifyFrame(y, [y, blur], cb)
out.set_output()
