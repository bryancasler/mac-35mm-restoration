# Large dark transient blobs in 10:00-11:00: dark vs BOTH neighbors (transient
# signature), connected components with area > 600 (the mcMaxSize cap).
import os, sys
sys.path.insert(0, os.path.expanduser("~/Library/Application Support/FilmRestore/pysite"))
import numpy as np, cv2
import vapoursynth as vs
core = vs.core
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
START, END = 14386, 15826
seg = clip[START:END]
y = core.std.ShufflePlanes(seg, planes=0, colorfamily=vs.GRAY)
prev = y[0] + y[:-1]
nxt = y[1:] + y[-1]
found = []
def cb(n, f):
    cur = np.asarray(f[0][0]).astype(np.int16)
    pv = np.asarray(f[1][0]).astype(np.int16)
    nx = np.asarray(f[2][0]).astype(np.int16)
    dark = ((pv - cur > 24) & (nx - cur > 24)).astype(np.uint8)
    count, _, stats, cents = cv2.connectedComponentsWithStats(dark, connectivity=8)
    for i in range(1, count):
        a = stats[i, cv2.CC_STAT_AREA]
        if a > 600:
            found.append((START + n, int(a), int(cents[i][0]), int(cents[i][1])))
    if n == y.num_frames - 1:
        for fr, a, cx, cy in sorted(found, key=lambda t: -t[1])[:10]:
            print(f"BIGSPECK frame {fr}: area {a} @ ({cx},{cy})", file=sys.stderr, flush=True)
        if not found:
            print("BIGSPECK none over the 600px cap in this minute", file=sys.stderr, flush=True)
    return f[0]
out = core.std.ModifyFrame(y, [y, prev, nxt], cb)
out.set_output()
