# deflicker.py — VapourSynth port of ffmpeg's vf_deflicker (S1 spike; becomes an
# app resource in M4). Mirrors libavfilter/vf_deflicker.c (release/8.1) exactly:
#
# - Forward-looking window: output frame i is scaled by
#   f = smooth(m[i], m[i+1], ..., m[i+size-1]) / m[i], where m[] are luma-plane
#   arithmetic means; at clip end the window pads by repeating the last frame's
#   mean (ffmpeg flushes by cloning the last frame).
# - Luma-only: dst = clip(int(src * f)) — int() truncates like the C float→int
#   conversion in av_clip_uint8(src[x] * f). Chroma copied untouched.
# - Modes: am gm hm qm cm pm median. NOTE ffmpeg 8.1's median comparator is
#   buggy (compares element addresses, so the window is never sorted and
#   "median" degrades to the positional middle m[i + size//2]). We implement a
#   true median by default; median_compat=True replicates ffmpeg's actual
#   behavior for validation.
#
# ffmpeg computes in float32; we use Python doubles. Divergence is ~1 ulp of
# float32 in the gain, at most ±1 LSB per pixel (validated in S1).

import math

import vapoursynth as vs

core = vs.core

MODES = ("am", "gm", "hm", "qm", "cm", "pm", "median")


def _factor(lum, mode, size, median_compat):
    if mode == "am":
        f = sum(lum) / size
    elif mode == "gm":
        f = math.prod(lum) ** (1.0 / size)
    elif mode == "hm":
        f = size / sum(1.0 / x for x in lum)
    elif mode == "qm":
        f = math.sqrt(sum(x * x for x in lum) / size)
    elif mode == "cm":
        f = (sum(x * x * x for x in lum) / size) ** (1.0 / 3.0)
    elif mode == "pm":
        f = (sum(x ** size for x in lum) / size) ** (1.0 / size)
    elif mode == "median":
        f = lum[size >> 1] if median_compat else sorted(lum)[size >> 1]
    else:
        raise ValueError(f"deflicker: bad mode {mode!r}")
    return f / lum[0]


def deflicker(clip, size=5, mode="am", bypass=False, median_compat=False):
    if not (2 <= size <= 129):
        raise ValueError("deflicker: size must be 2..129")
    if mode not in MODES:
        raise ValueError(f"deflicker: mode must be one of {MODES}")
    if clip.format.color_family not in (vs.YUV, vs.GRAY):
        raise ValueError("deflicker: YUV/GRAY input only")
    if clip.format.sample_type != vs.INTEGER:
        raise ValueError("deflicker: integer formats only")

    n_frames = clip.num_frames
    peak = (1 << clip.format.bits_per_sample) - 1
    stats = core.std.PlaneStats(clip, plane=0)

    # window source k: stats shifted left by k frames, padded with the last
    # frame — matches ffmpeg's EOF flush (window[k] = m[min(i + k, N-1)])
    prop_src = []
    for k in range(size):
        k = min(k, n_frames - 1)
        s = stats[k:] + stats[n_frames - 1] * k if k else stats
        prop_src.append(s)

    luma_planes = [0]

    def apply(n, f):
        lum = [fr.props.PlaneStatsAverage * peak for fr in f]
        g = _factor(lum, mode, size, median_compat)
        if bypass or g == 1.0:
            return clip
        return core.std.Lut(clip, planes=luma_planes,
                            function=lambda x: min(int(x * g), peak))

    return core.std.FrameEval(clip, apply, prop_src=prop_src)
