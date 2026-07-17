# Upstream: ffmpeg vf_deflicker median-mode bug (2026-07-17)

Status: **patch prepared + validated, ready to send** (needs Bryan's SMTP credentials —
see "How to submit"). Patch file: [`0001-avfilter-vf_deflicker-fix-comparator-used-for-median.patch`](0001-avfilter-vf_deflicker-fix-comparator-used-for-median.patch)

## Root cause

`libavfilter/vf_deflicker.c` (identical in release/8.1 and master @ `0869e710e6`,
2026-07-17):

```c
static int comparef(const void *a, const void *b)
{
    const float *aa = a, *bb = b;
    return round(aa - bb);   // pointer arithmetic, not *aa - *bb
}
```

The comparator returns the sign of the element *addresses*, so `AV_QSORT` believes the
array is always sorted. It is not quite a no-op though: AV_QSORT's median-of-3 pivot
handling still applies a **fixed, value-independent permutation**. Verified with a
standalone harness compiled against ffmpeg's own `libavutil/qsort.h`: for `size=5` the
"sorted" array is the input with elements 2 and 3 swapped, so median mode returns
`luminance[3]` — the mean of an arbitrary nearby frame — instead of the window median.
This exactly reproduces ffmpeg's observed output and explains the S1 finding that a true
median matches ffmpeg's median on only ~25% of frames (chance coincidences).

Fix: `return FFDIFFSIGN(*aa, *bb);` (matches comparator idiom in vf_blurdetect,
vf_cropdetect, vf_deshake).

## Minimal reproduction (any stock ffmpeg, e.g. Homebrew 8.1.2)

Per-frame constant luma repeating 40, 200, 120, 80 → every `size=5` window's true
median is 80 or 120. The filter's own metadata exposes the smoothed target:

```sh
ffmpeg -f lavfi -i "color=c=black:s=64x64:r=25:d=0.8,format=gray,\
geq=lum='if(eq(mod(N\,4)\,0)\,40\,if(eq(mod(N\,4)\,1)\,200\,if(eq(mod(N\,4)\,2)\,120\,80)))'" \
  -vf deflicker=size=5:mode=median,metadata=mode=print -f null -
```

| frame luma | window (temporal) | true median | ffmpeg 8.1.2 reports |
|---|---|---|---|
| 40  | 40,200,120,80,40  | 80  | 80 (coincidence) |
| 200 | 200,120,80,40,200 | 120 | **40** |
| 120 | 120,80,40,200,120 | 120 | **200** |
| 80  | 80,40,200,120,80  | 80  | **120** |

Sanity: `mode=am` on the same input returns the exact window means (96, 128, 112, 104)
— the harness itself is sound; only median is broken.

## Validation of the patch

Minimal master build (`--disable-everything` + the components above) with the one-line
fix: median mode reports 80, 120, 120, 80 — the true median for every frame
(`120.000008` display noise is `luminance*factor` float32 round-trip). `mode=am`
byte-identical to unpatched. No FATE refs exist for deflicker, so no test updates needed.

## How to submit (patch to ffmpeg-devel — preferred route)

ffmpeg takes patches via mailing list, git send-email style. One-time setup (Gmail App
Password required — https://myaccount.google.com/apppasswords; Claude must not handle it):

```sh
git config --global sendemail.smtpServer smtp.gmail.com
git config --global sendemail.smtpServerPort 587
git config --global sendemail.smtpEncryption tls
git config --global sendemail.smtpUser bryan.casler@gmail.com
```

Then, from anywhere (patch is self-contained; prompts for the app password):

```sh
git send-email --to=ffmpeg-devel@ffmpeg.org \
  docs/upstream/0001-avfilter-vf_deflicker-fix-comparator-used-for-median.patch
```

Notes: subscribing first at https://ffmpeg.org/mailman/listinfo/ffmpeg-devel avoids
moderation delay. If Apple git's send-email misbehaves, `brew install git` ships a full
one. The patch applies cleanly to both master and release/8.1.

## Alternative: trac ticket (if the ML route stalls)

https://trac.ffmpeg.org — component `avfilter`, attach the patch. Suggested summary:
"vf_deflicker: median mode returns wrong values (qsort comparator compares pointers,
not values)". Body: root cause + repro table above.
