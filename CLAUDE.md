# FilmRestore — working agreement for Claude sessions

macOS app (Apple Silicon only) restoring digitized film scans. Fixed pipeline:
**deflicker → scratch removal → dirt removal → encode** (validated; do not re-derive).
SwiftUI shelling out to ffmpeg/VapourSynth. GPL-3.0. All decisions live in docs/ADR.md.

## Process state lives in .md files — not in conversation memory

The repo, not the chat context, is the source of truth for project state. Context
windows compact and sessions end; these files don't.

| File | Role | Write rules |
|---|---|---|
| [STATE.md](STATE.md) | Current focus, next actions, blockers, fresh findings | Update whenever direction changes; **hard cap 60 lines** — prune by moving durable facts to ADR/RESULTS and deleting stale notes |
| [docs/ADR.md](docs/ADR.md) | Architecture decisions + research findings | Append-only (new ADR-N per decision); amend an ADR only with a dated note, never silent edits |
| [docs/PLAN.md](docs/PLAN.md) | Milestones M0–M5, spike definitions, verification criteria | Check off / annotate as milestones complete; scope changes get a dated note |
| [spikes/RESULTS.md](spikes/RESULTS.md) | Spike verdicts with numbers (fps, PSNR) | Fill in the verdict row + a short findings section immediately when a spike concludes — never leave results only in chat |

## Session protocol

1. **Start:** read STATE.md first. Read ADR/PLAN sections only as the task needs them
   — do not re-read everything into context.
2. **During:** when you learn something durable (a benchmark number, a gotcha, a
   decision), write it to the right file *at the moment you learn it*, then keep going.
3. **End of a work chunk:** update STATE.md (done/next/blockers), commit with the code.
   A session that ends with correct .md files needs no conversation handoff.

## Sub-agent briefings

Spawn sub-agents with **file pointers, not pasted context**. Template:

> Read CLAUDE.md, STATE.md, and <specific ADR sections / spike definition in
> docs/PLAN.md>. Then: <task>. Return: <exact deliverable — numbers, verdict,
> file diff>. Write nothing outside <scope>.

The main session (not the sub-agent) merges results into RESULTS.md/STATE.md, so
two agents never write the same file concurrently.

## Hard rules

- Never touch source video files; outputs are auto-suffixed copies.
- Spike scripts are throwaway: bash/python/.vpy under spikes/, no app code before M2.
- ffmpeg/vapoursynth come from Homebrew (/opt/homebrew); restoration plugins from the
  app-managed dir via VAPOURSYNTH_EXTRA_PLUGIN_PATH (ADR-6). Never install plugins
  into Homebrew's site-packages.
- Commit at natural checkpoints; .md updates ride in the same commit as the work
  they describe.
- **DMG stays fresh:** any chunk that changes `FilmRestore/Sources/`, `Package.swift`,
  or `FilmRestore/scripts/` must run `FilmRestore/scripts/make-dmg.sh` and include the
  regenerated `release/FilmRestore.dmg` (unsigned, ~1.5 MB) in the same commit.
- **Push authorization (standing, granted 2026-07-17):** push directly to
  origin/main whenever a chunk of work is completed — no need to ask. A "chunk"
  is a committed unit with its .md updates in place (a spike verdict, a milestone
  step, a doc revision).
