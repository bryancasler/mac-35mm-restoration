All research complete. Compiling findings.

---

# ANGLE 2 FINDINGS — ML approaches to film-defect restoration, Apple-Silicon feasibility

## Headline verdict

End-to-end "old film" nets (RTN and descendants) are all CUDA-first research code with abandonware risk and mostly restoration-quality licenses (non-commercial or none) — problematic for a GPL-3.0 app. The **highest-value, lowest-risk ML integration is a mask-then-repair split**: run a defect-DETECTION net per frame (fast, small, exportable to CoreML/ONNX), then apply your existing temporal repair (Clense/Repair/SpotLess) or inpainting **only inside the mask** via `MaskedMerge`. This directly attacks the "hit and miss" complaint: global heuristic filters must trade false positives against misses; an ML detector moves that tradeoff, and the repair stays deterministic and fast.

## Ranked candidates

### 1. Two-pass mask-gen pipeline (detector → VS MaskedMerge) — RECOMMENDED
- **Detector option A — Microsoft "Bringing Old Photos Back to Life" scratch-detection U-Net** (CVPR 2020): https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life — code **and pretrained weights MIT-licensed** (scratch detector is `Global/detection.py`, standalone, outputs binary masks). Designed for photo scratches but community-used on film frames; per-frame so no temporal deps.
- **Detector option B — train/fine-tune your own** on synthetic damage from **FilmDamageSimulator** (Eurographics 2023, Ivanova et al., https://github.com/daniela997/FilmDamageSimulator, paper https://arxiv.org/abs/2302.10004): statistical dust/scratch damage model learnt from real scans + 4K expert-restored paired dataset. Plus the brand-new **AbsoluteDegradation** benchmark (arXiv July 2026, https://arxiv.org/abs/2607.02131): physics-inspired synthetic degradation (signal-dependent grain, parametric scratches, temporally coherent motion), 81,576 real archival frames; no code URL on the abstract page yet — watch it.
- Small U-Net exists at https://github.com/Aly-Khalifa/scratch-detection (TF, hobby-grade — treat as reference only).
- **Integration:** offline pass 1: python subprocess (PyTorch MPS or CoreML) renders masks to an FFV1/gray mkv; pass 2: `.vpy` loads it with bestsource, `std.Maximum`/temporal-dilate, `MaskedMerge(source, RemoveDirt/SpotLess, mask)`. Zero new runtime inside vspipe.
- **Expected speed (estimate):** a 256-512px-receptive-field U-Net at 1440x1080 on M4 Pro via CoreML EP or MPS: ~5-15 fps mask pass; total pipeline stays near-realtime-ish. A per-frame detector is the only ML class here that plausibly exports cleanly to CoreML (plain conv U-Net, fixed shape).
- **Risk:** photo-trained detector may miss film-specific dirt (soft blotches); mitigate with FilmDamageSimulator fine-tune. License clean (MIT).

### 2. RRTN — "Restoring Degraded Old Films with Recursive Recurrent Transformer Networks" (WACV 2024, Lin & Simo-Serra)
- https://github.com/mountln/RRTN-old-film-restoration — **MIT license (verified via GitHub API)**, pretrained weights on releases (`rrtn_128_first/second.pth`, RAFT sintel). Explicitly improves RTN's **film-noise mask estimation** — the first-stage mask output alone could feed pipeline #1. Paper: https://openaccess.thecvf.com/content/WACV2024/papers/Lin_Restoring_Degraded_Old_Films_With_Recursive_Recurrent_Transformer_Networks_WACV_2024_paper.pdf
- **Risks:** 7 commits, 11 stars, last push 2024-09-01 — single-author code, weights trained at 128px patches; depends on **mmcv** and BasicVSR++ components → deformable-conv ops have **no MPS kernels** (CPU fallback via `PYTORCH_ENABLE_MPS_FALLBACK=1`, slow, or surgery to replace DCN with flow-warp). Estimate 0.1-0.5 fps at 1440x1080 on M4 Pro if it runs at all on MPS; likely needs tiling.
- **Integration:** subprocess (video-in/video-out), not vspipe-embedded. Best treated as an experiment to harvest its mask branch under MIT.

### 3. RTN — "Bringing Old Films Back to Life" (CVPR 2022)
- https://github.com/raywzy/Bringing-Old-Films-Back-to-Life, paper https://arxiv.org/abs/2203.17276. Handles scratches + dirt jointly with temporal coherence (recurrent + Swin blocks + RAFT flow, unsupervised scratch localization); flicker only implicitly.
- **State: effectively abandoned** — 9 commits, last push 2023-06-19, **no LICENSE file** (project page says academic research only); weights on a CityU OneDrive link (link-rot risk). Open issues include *"Scratches are not removed after processing"* (#17) and *"Can this run on non-nvidia cards?"* (#13, unanswered) — i.e., the same hit-and-miss behavior you're fighting, plus no non-CUDA story.
- **MPS viability:** architecture (RAFT `grid_sample` + Swin attention, no DCN found in `VP_code/models`) is MPS-representable in torch ≥2.1, but nobody has demonstrated it; expect days of porting + ~0.2-0.5 fps (estimate) at 1440x1080, VRAM undocumented (recurrent → memory grows with temporal window). **Skip in favor of RRTN (same lineage, MIT, better masks).**

### 4. ProPainter (ICCV 2023) — mask-based video inpainting for large defects
- https://github.com/sczhou/ProPainter — 6.8k stars, license **NTU S-Lab 1.0 non-commercial** (GitHub API: NOASSERTION) → cannot ship in a GPL app; user-installed optional backend at most. Documented VRAM: 25 GB fp16 @ 720p/80 frames; 8 GB fp16 @ 720x480; knobs: `--neighbor_length`, `--ref_stride`, `--resize_ratio`, fp16. Chunked fork: https://github.com/passerbya/Chunk_E2FGVI (pattern applies).
- On M4 Pro (unified memory helps vs discrete VRAM): feasible at reduced resolution in short chunks, est. <0.5 fps; flow + deformable-alignment ops risk CPU fallback on MPS. **Use only for severe damage (tears, big blotches) with masks from #1, not per-speck dirt.**

### 5. DiffuEraser (2025, diffusion video inpainting)
- https://github.com/lixiaowen-xw/DiffuEraser — **Apache-2.0 code** but uses ProPainter as prior (license taint) + BrushNet/AnimateDiff SD-class UNet. Beats ProPainter on completeness/temporal consistency. **Impractical on M4 Pro** for 1440x1080 film reels: diffusion per clip, est. minutes per second of footage. Not recommended.

### 6. E2FGVI (CVPR 2022) / DeepRemaster (SIGGRAPH Asia 2019) / TAPE (WACV 2024)
- E2FGVI: https://github.com/MCG-NKU/E2FGVI — **CC BY-NC 4.0**; superseded by ProPainter. Skip.
- DeepRemaster: https://github.com/satoshiiizuka/siggraphasia2019_remastering — **CC BY-NC-SA 4.0**, 2019-era temporal-conv net, mediocre defect removal by current standards, low-res oriented. Skip.
- TAPE: https://github.com/miccunifi/TAPE — **CC BY-NC 4.0**, weights released, but targets **VHS/videotape** artifacts (mistracking, edge waving, chroma loss), not film dirt/scratches. Wrong domain; interesting only for its CLIP zero-shot clean-frame selection idea.

### 7. All-In-One-Deflicker (CVPR 2023, blind deflicker)
- https://github.com/ChenyangLEI/All-In-One-Deflicker — ~3 GB VRAM but **per-video neural-atlas optimization** (~10k iterations per 80 frames) → hours per clip. Your ffmpeg-deflicker port is the right call; skip.

### 8. Watch list
- **AbsoluteDegradation** (arXiv 2607.02131, July 2026) — if they release code+weights, it's the first film-restoration model family with a real-footage benchmark and documented failure modes of RTN-class methods.
- **npj Heritage Science 2025** "Restoration of archival film with large areas of structural damage" (https://www.nature.com/articles/s40494-025-02235-3) — paywalled/403 during research; unverified code status.

## Mac deployment paths (verified)

| Path | Status | Notes |
|---|---|---|
| PyTorch MPS subprocess | **Works today**; the only path for RTN/RRTN/ProPainter | torch ≥2.x covers grid_sample/attention; **mmcv/torchvision deformable conv has no MPS kernel** → `PYTORCH_ENABLE_MPS_FALLBACK=1` (slow) or model surgery |
| vs-mlrt | **No macOS release builds** — v15.16 (2026-03-26) ships Windows/Linux only; source claims "Apple SoC: vsort-coreml" backend | Self-compile vsort possible, but only helps ONNX-exportable feed-forward models — recurrent flow-guided film nets don't export cleanly. GPL-3.0 (compatible). https://github.com/AmusementClub/vs-mlrt |
| ONNX Runtime CoreML EP | **Works** — official `onnxruntime` pip wheel on macOS arm64 includes CoreML EP (https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) | Best for the U-Net detector (fixed-shape, conv-only). Dynamic shapes fall back to CPU EP |
| coremltools conversion | Viable for detector U-Net only | Recurrent + optical-flow models: high-effort, high-failure conversion; don't attempt |
| ncnn Vulkan (vsncnn/MoltenVK) | No macOS builds shipped; not worth the effort vs CoreML EP | |

## Bottom line recommendation for FilmRestore

Spike order: **(1)** BOPBTL scratch U-Net (MIT) as a per-frame mask generator via PyTorch-MPS subprocess → FFV1 mask file → `MaskedMerge` gating of the existing RemoveDirt/SpotLess chain; measure false-positive/miss rate vs current DeScratch on the real 1440x1080 scan. **(2)** If masks are good but repair quality lags, add RRTN (MIT) as an optional heavy path or harvest its mask branch. **(3)** Reserve ProPainter (non-commercial, user-installed) for catastrophic frames only. Avoid RTN (no license, dead), diffusion inpainting (speed), and all CC-NC end-to-end models for anything shipped.

Sources: [RTN repo](https://github.com/raywzy/Bringing-Old-Films-Back-to-Life) · [RTN paper](https://arxiv.org/abs/2203.17276) · [RRTN repo](https://github.com/mountln/RRTN-old-film-restoration) · [RRTN paper](https://openaccess.thecvf.com/content/WACV2024/papers/Lin_Restoring_Degraded_Old_Films_With_Recursive_Recurrent_Transformer_Networks_WACV_2024_paper.pdf) · [ProPainter](https://github.com/sczhou/ProPainter) · [DiffuEraser](https://github.com/lixiaowen-xw/DiffuEraser) · [E2FGVI](https://github.com/MCG-NKU/E2FGVI) · [DeepRemaster](https://github.com/satoshiiizuka/siggraphasia2019_remastering) · [TAPE](https://github.com/miccunifi/TAPE) · [BOPBTL (Microsoft)](https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life) · [FilmDamageSimulator](https://github.com/daniela997/FilmDamageSimulator) · [Simulating analogue film damage](https://arxiv.org/abs/2302.10004) · [AbsoluteDegradation](https://arxiv.org/abs/2607.02131) · [All-In-One-Deflicker](https://github.com/ChenyangLEI/All-In-One-Deflicker) · [vs-mlrt](https://github.com/AmusementClub/vs-mlrt) · [vs-mlrt releases](https://github.com/AmusementClub/vs-mlrt/releases) · [ORT CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html) · [Aly-Khalifa/scratch-detection](https://github.com/Aly-Khalifa/scratch-detection) · [npj Heritage 2025](https://www.nature.com/articles/s40494-025-02235-3)