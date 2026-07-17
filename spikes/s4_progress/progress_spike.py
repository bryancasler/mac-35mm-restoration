#!/usr/bin/env python3
"""S4 spike: progress parsing -> ETA for both pipeline backends. THROWAWAY.

Usage:
    python3 progress_spike.py phase1   # ffmpeg-only (deflicker + hevc_videotoolbox, -f null)
    python3 progress_spike.py phase2   # vspipe chain60.vpy | ffmpeg (-f null)
    python3 progress_spike.py both

Prints one progress/ETA line ~1/s; records (elapsed_s, frame, eta_s) samples and
dumps a summary table + monotonicity check at the end. Writes no video output.
"""

import os
import subprocess
import sys
import threading
import time

REPO = "/Users/4Site/Documents/GitHub/mac-35mm-restoration"
FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"
VSPIPE = "/opt/homebrew/bin/vspipe"
CLIP = os.path.join(REPO, "spikes/s1_deflicker/clip60.mkv")
VPY = os.path.join(REPO, "spikes/s3_pipeline/chain60.vpy")
PLUGIN_DIR = os.path.expanduser("~/Library/Application Support/FilmRestore/plugins")
LOG = os.path.join(REPO, "spikes/s4_progress/run.log")

logf = open(LOG, "a")


def log(line):
    print(line, flush=True)
    logf.write(line + "\n")
    logf.flush()


def probe_total_frames(path):
    """Total frames the app-side way: nb_frames if present, else duration * fps.
    Gotcha: on MKV both stream-level nb_frames and stream-level duration are N/A;
    the container (format) duration is what's populated."""
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=nb_frames,avg_frame_rate,duration:format=duration",
         "-of", "default=noprint_wrappers=1", path],
        capture_output=True, text=True, check=True).stdout
    kv = {}
    for l in out.splitlines():
        if "=" in l:
            k, v = l.split("=", 1)
            if kv.get(k, "N/A") in ("N/A", ""):  # keep first non-N/A value
                kv[k] = v
    if kv.get("nb_frames", "N/A") not in ("N/A", "", "0"):
        return int(kv["nb_frames"]), "nb_frames"
    num, den = kv["avg_frame_rate"].split("/")
    return round(float(kv["duration"]) * int(num) / int(den)), "duration*fps"


class ProgressTracker:
    """Parses ffmpeg -progress key=value blocks; emits ETA once per block, ~1/s."""

    def __init__(self, total, label):
        self.total = total
        self.label = label
        self.t0 = time.monotonic()
        self.samples = []          # (elapsed_s, frame, fps, eta_s)
        self.cur = {}
        self.saw_end = False

    def feed_line(self, line):
        line = line.strip()
        if "=" not in line:
            return
        k, v = line.split("=", 1)
        self.cur[k] = v
        if k == "progress":              # block boundary
            self._block_done(v)
            self.cur = {}

    def _block_done(self, status):
        if status == "end":
            self.saw_end = True
        elapsed = time.monotonic() - self.t0
        try:
            frame = int(self.cur.get("frame", "0"))
            fps = float(self.cur.get("fps", "0"))
        except ValueError:
            return
        eta = (self.total - frame) / fps if fps > 0 else float("inf")
        self.samples.append((elapsed, frame, fps, eta))
        eta_str = f"{eta:6.1f}s" if eta != float("inf") else "   inf"
        log(f"[{self.label}] t={elapsed:5.1f}s frame={frame:4d}/{self.total} "
            f"fps={fps:6.1f} speed={self.cur.get('speed','?'):>6} eta={eta_str}"
            + ("  [progress=end]" if status == "end" else ""))


def read_cr_delimited(stream, callback):
    """vspipe stderr progress is CR-delimited ('Frame: N/M\\r'); readline() would
    buffer forever. Read raw bytes, split on both \\r and \\n."""
    buf = b""
    while True:
        chunk = stream.read(256)
        if not chunk:
            break
        buf += chunk
        while True:
            # split on whichever separator comes FIRST (a buffer can hold
            # '...\nFrame: 1/1440\r' — checking \r before \n glues two lines)
            idxs = [i for i in (buf.find(b"\r"), buf.find(b"\n")) if i >= 0]
            if not idxs:
                break
            i = min(idxs)
            callback(buf[:i].decode("utf-8", "replace"))
            buf = buf[i + 1:]
    if buf:
        callback(buf.decode("utf-8", "replace"))


def check_monotonic(samples, warmup_s=3.0, jitter_s=2.0):
    """ETA must decrease after warmup, allowing jitter_s of upward wobble."""
    post = [(t, f, fps, eta) for (t, f, fps, eta) in samples
            if t >= warmup_s and eta != float("inf")]
    bad = []
    for prev, cur in zip(post, post[1:]):
        if cur[3] > prev[3] + jitter_s:
            bad.append((prev, cur))
    return post, bad


def report(label, tracker):
    post, bad = check_monotonic(tracker.samples)
    n = len(tracker.samples)
    log(f"\n[{label}] {n} progress blocks, progress=end seen: {tracker.saw_end}")
    log(f"[{label}] table (elapsed_s, frame, fps, eta_s), subsampled:")
    show = tracker.samples if n <= 8 else \
        [tracker.samples[i] for i in sorted(set(
            round(i * (n - 1) / 7) for i in range(8)))]
    for t, f, fps, eta in show:
        e = f"{eta:.1f}" if eta != float("inf") else "inf"
        log(f"[{label}]   {t:6.1f}  {f:4d}  {fps:6.1f}  {e}")
    if bad:
        log(f"[{label}] NON-MONOTONIC ETA jumps (> 2s upward) after 3s warmup:")
        for p, c in bad:
            log(f"[{label}]   t={p[0]:.1f} eta={p[3]:.1f} -> t={c[0]:.1f} eta={c[3]:.1f}")
    sane = all(eta >= 0 for _, _, _, eta in post) and len(post) > 0
    verdict = "PASS" if sane and not bad else "FAIL"
    log(f"[{label}] verdict: {verdict}")
    return verdict


def run_phase1():
    total, how = probe_total_frames(CLIP)
    log(f"\n=== phase1: ffmpeg deflicker -> hevc_videotoolbox -> -f null ===")
    log(f"[p1] total frames via ffprobe ({how}): {total}")
    tr = ProgressTracker(total, "p1")
    cmd = [FFMPEG, "-y", "-i", CLIP,
           "-vf", "deflicker=mode=pm:size=10",
           "-c:v", "hevc_videotoolbox", "-q:v", "60",
           "-progress", "pipe:1", "-f", "null", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True)
    for line in p.stdout:
        tr.feed_line(line)
    rc = p.wait()
    log(f"[p1] ffmpeg exit code: {rc}")
    return report("p1", tr)


def run_phase2():
    total = 1440  # app-supplied: the .vpy's frame count (clip[14000:15440])
    log(f"\n=== phase2: vspipe chain60.vpy | ffmpeg hevc_videotoolbox -> -f null ===")
    log(f"[p2] app-supplied total frames: {total}")
    tr = ProgressTracker(total, "p2")
    vs_state = {"frame": -1, "total": -1, "lines": 0}

    def on_vspipe_line(line):
        # 'Frame: 123/1440' -- CR-delimited progress on stderr
        line = line.strip()
        if line.startswith("Frame:") and "/" in line:
            try:
                n, m = line.split(":", 1)[1].strip().split("/")
                vs_state["frame"], vs_state["total"] = int(n), int(m)
                vs_state["lines"] += 1
            except ValueError:
                pass
        elif line:
            log(f"[p2:vspipe-stderr] {line}")

    env = dict(os.environ, VAPOURSYNTH_EXTRA_PLUGIN_PATH=PLUGIN_DIR)
    vsp = subprocess.Popen([VSPIPE, "-c", "y4m", "-p", VPY, "-"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           env=env)
    ff = subprocess.Popen([FFMPEG, "-f", "yuv4mpegpipe", "-i", "-",
                           "-c:v", "hevc_videotoolbox", "-q:v", "60",
                           "-progress", "pipe:1", "-f", "null", "-"],
                          stdin=vsp.stdout, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True)
    vsp.stdout.close()  # let vspipe get SIGPIPE if ffmpeg dies

    t_err = threading.Thread(target=read_cr_delimited,
                             args=(vsp.stderr, on_vspipe_line), daemon=True)
    t_err.start()

    last_vs_print = 0.0
    for line in ff.stdout:
        tr.feed_line(line)
        now = time.monotonic()
        if now - last_vs_print >= 1.0 and vs_state["frame"] >= 0:
            log(f"[p2:vspipe] Frame: {vs_state['frame']}/{vs_state['total']} "
                f"(secondary signal, leads encoder)")
            last_vs_print = now
    rc_ff = ff.wait()
    rc_vs = vsp.wait()
    t_err.join(timeout=5)
    log(f"[p2] exit codes: vspipe={rc_vs} ffmpeg={rc_ff}; "
        f"vspipe Frame lines parsed: {vs_state['lines']}, "
        f"final vspipe frame: {vs_state['frame']}/{vs_state['total']}")
    return report("p2", tr)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "both"
    log(f"\n##### S4 run {time.strftime('%Y-%m-%d %H:%M:%S')} mode={mode} #####")
    results = {}
    if mode in ("phase1", "both"):
        results["phase1"] = run_phase1()
    if mode in ("phase2", "both"):
        results["phase2"] = run_phase2()
    log(f"\n##### S4 verdicts: {results} #####")
    logf.close()
    sys.exit(0 if all(v == "PASS" for v in results.values()) else 1)
