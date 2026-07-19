# ml_mask_pass.py — ML scratch-detection mask pass (FilmRestore Phase 3).
#
# Runs INSIDE the app-managed mlenv (invoked as `mlenv/bin/python3 ml_mask_pass.py`).
# Decodes frames from a video via an ffmpeg rawvideo gray pipe, runs the BOPBTL
# scratch-detection UNet (see scratch_unet.py, MIT) per frame, thresholds the
# sigmoid output into a binary 0/255 mask, and writes the masks as a gray FFV1
# MKV at the source frame rate. The mask MKV is consumed by the VapourSynth
# pipeline via bestsource + MaskedMerge.
#
# CLI:
#   mlenv/bin/python3 ml_mask_pass.py --input in.mkv --output mask.mkv \
#       --weights scratch_detector.pt [--start-frame N] [--num-frames N] \
#       [--device mps|cpu] [--threshold 0.4] [--tile 0]
#
# Progress: prints "MLMASK frame=N/M" to stderr every 24 frames (app parses it).
# Restartable: output is written to <output>.part and atomically renamed on
# success, so a killed/failed run never leaves a truncated file at --output.
# Exits nonzero on any failure.

import argparse
import os
import subprocess
import sys
import tempfile
from fractions import Fraction

import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scratch_unet import load_scratch_detector  # noqa: E402

FFMPEG = "/opt/homebrew/bin/ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe"

PROGRESS_EVERY = 24


def die(msg, code=1):
    print("MLMASK error: %s" % msg, file=sys.stderr)
    sys.exit(code)


def probe(path):
    """Return (width, height, fps_str, fps_fraction, est_total_frames)."""
    cmd = [
        FFPROBE, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,nb_frames:format=duration",
        "-of", "default=noprint_wrappers=1", path,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        die("ffprobe failed on %s: %s" % (path, e.stderr.strip()))
    info = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k] = v
    try:
        w, h = int(info["width"]), int(info["height"])
        fps_str = info["r_frame_rate"]
        fps = Fraction(fps_str)
    except (KeyError, ValueError, ZeroDivisionError):
        die("could not parse ffprobe output for %s" % path)
    total = None
    nb = info.get("nb_frames", "N/A")
    if nb.isdigit():
        total = int(nb)
    else:
        dur = info.get("duration", "N/A")
        try:
            total = int(round(float(dur) * float(fps)))
        except ValueError:
            total = None
    return w, h, fps_str, fps, total


def pick_device(requested):
    if requested == "mps":
        if torch.backends.mps.is_available():
            return torch.device("mps")
        print("MLMASK warning: MPS not available, falling back to CPU", file=sys.stderr)
    return torch.device("cpu")


def infer_mask(model, frame_u8, device, threshold, tile, pad_hw):
    """frame_u8: (H, W) uint8 gray. Returns (H, W) uint8 mask, 0 or 255."""
    h, w = frame_u8.shape
    pad_b, pad_r = pad_hw
    # .copy(): frame_u8 comes from a read-only np.frombuffer view
    x = torch.from_numpy(frame_u8.copy()).float().div_(127.5).sub_(1.0)  # Normalize([0.5],[0.5])
    x = x.unsqueeze(0).unsqueeze(0)  # 1x1xHxW
    if pad_b or pad_r:
        x = F.pad(x, (0, pad_r, 0, pad_b), mode="reflect")  # to multiples of 16

    with torch.no_grad():
        if tile > 0:
            prob = _tiled_forward(model, x, device, tile)
        else:
            prob = torch.sigmoid(model(x.to(device))).cpu()

    mask = (prob[0, 0, :h, :w] >= threshold)  # crop padding back off
    return (mask.numpy().astype(np.uint8)) * 255


def _tiled_forward(model, x, device, tile):
    """Tile-wise forward for memory-limited devices. tile is the tile edge
    (rounded up to a multiple of 16); tiles overlap by 32 px and only each
    tile's interior is kept, so seams are avoided."""
    tile = max(64, (tile + 15) // 16 * 16)
    overlap = 32
    _, _, H, W = x.shape
    out = torch.zeros(1, 1, H, W)
    ys = list(range(0, max(H - overlap, 1), tile - overlap))
    xs = list(range(0, max(W - overlap, 1), tile - overlap))
    for y0 in ys:
        y1 = min(y0 + tile, H)
        y0 = max(0, y1 - tile)
        for x0 in xs:
            x1 = min(x0 + tile, W)
            x0 = max(0, x1 - tile)
            p = torch.sigmoid(model(x[:, :, y0:y1, x0:x1].to(device))).cpu()
            ky0 = 0 if y0 == 0 else overlap // 2
            kx0 = 0 if x0 == 0 else overlap // 2
            out[:, :, y0 + ky0 : y1, x0 + kx0 : x1] = p[:, :, ky0:, kx0:]
    return out


def main():
    ap = argparse.ArgumentParser(description="BOPBTL scratch-detection mask pass")
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--start-frame", type=int, default=0)
    ap.add_argument("--num-frames", type=int, default=0, help="0 = to end of file")
    ap.add_argument("--device", choices=["mps", "cpu"], default="mps")
    ap.add_argument("--threshold", type=float, default=0.4)
    ap.add_argument("--tile", type=int, default=0, help="0 = whole frame; else tile edge px")
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        die("input not found: %s" % args.input)
    if not os.path.isfile(args.weights):
        die("weights not found: %s" % args.weights)

    w, h, fps_str, fps, total_in = probe(args.input)

    if args.num_frames > 0:
        total = args.num_frames
    elif total_in is not None:
        total = max(total_in - args.start_frame, 0)
    else:
        total = 0  # unknown; progress prints N/?

    pad_b = (-h) % 16
    pad_r = (-w) % 16

    device = pick_device(args.device)
    try:
        model = load_scratch_detector(args.weights, device)
    except Exception as e:
        die("failed to load weights: %r" % e)

    # --- decoder: ffmpeg rawvideo gray pipe ---
    dec_cmd = [FFMPEG, "-nostdin", "-v", "error"]
    if args.start_frame > 0:
        # seek to halfway between frame N-1 and N so frame N is the first out
        t = (args.start_frame - Fraction(1, 2)) / fps
        dec_cmd += ["-ss", "%.6f" % float(t)]
    dec_cmd += ["-i", args.input]
    if args.num_frames > 0:
        dec_cmd += ["-frames:v", str(args.num_frames)]
    dec_cmd += ["-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"]

    part_path = args.output + ".part"
    enc_cmd = [
        FFMPEG, "-nostdin", "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "gray", "-s", "%dx%d" % (w, h), "-r", fps_str,
        "-i", "pipe:0",
        "-c:v", "ffv1", "-pix_fmt", "gray", "-f", "matroska", part_path,
    ]

    frame_bytes = w * h
    dec_err = tempfile.TemporaryFile()
    enc_err = tempfile.TemporaryFile()
    dec = subprocess.Popen(dec_cmd, stdout=subprocess.PIPE, stderr=dec_err)
    enc = subprocess.Popen(enc_cmd, stdin=subprocess.PIPE, stderr=enc_err)

    def child_err(f):
        f.seek(0)
        return f.read().decode(errors="replace").strip()

    n = 0
    total_str = str(total) if total else "?"
    fell_back = False
    try:
        while True:
            buf = dec.stdout.read(frame_bytes)
            if not buf:
                break
            if len(buf) != frame_bytes:
                # pipes can return short reads; top up
                while len(buf) < frame_bytes:
                    more = dec.stdout.read(frame_bytes - len(buf))
                    if not more:
                        raise RuntimeError("truncated frame from decoder (%d bytes)" % len(buf))
                    buf += more
            frame = np.frombuffer(buf, dtype=np.uint8).reshape(h, w)
            try:
                mask = infer_mask(model, frame, device, args.threshold, args.tile, (pad_b, pad_r))
            except Exception as e:
                if device.type == "mps" and not fell_back:
                    print("MLMASK warning: MPS inference failed (%r), retrying on CPU" % e,
                          file=sys.stderr)
                    device = torch.device("cpu")
                    model = model.to(device)
                    fell_back = True
                    mask = infer_mask(model, frame, device, args.threshold, args.tile, (pad_b, pad_r))
                else:
                    raise
            enc.stdin.write(mask.tobytes())
            n += 1
            if n % PROGRESS_EVERY == 0:
                print("MLMASK frame=%d/%s" % (n, total_str), file=sys.stderr, flush=True)

        enc.stdin.close()
        dec_rc = dec.wait()
        enc_rc = enc.wait()
        if dec_rc != 0:
            raise RuntimeError("decoder ffmpeg exited %d: %s" % (dec_rc, child_err(dec_err)))
        if enc_rc != 0:
            raise RuntimeError("encoder ffmpeg exited %d: %s" % (enc_rc, child_err(enc_err)))
        if n == 0:
            raise RuntimeError("no frames decoded (start-frame beyond end?)")
        if args.num_frames > 0 and n != args.num_frames:
            raise RuntimeError("expected %d frames, got %d" % (args.num_frames, n))
    except BrokenPipeError:
        enc_rc = enc.wait()
        die("encoder ffmpeg died (exit %s): %s" % (enc_rc, child_err(enc_err)))
    except Exception as e:
        for p in (dec, enc):
            if p.poll() is None:
                p.kill()
        if os.path.exists(part_path):
            os.unlink(part_path)
        die(str(e))
    finally:
        dec_err.close()
        enc_err.close()

    os.replace(part_path, args.output)
    if n % PROGRESS_EVERY != 0:
        print("MLMASK frame=%d/%s" % (n, total_str), file=sys.stderr, flush=True)
    print("MLMASK done frames=%d device=%s output=%s" % (n, device.type, args.output),
          file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
