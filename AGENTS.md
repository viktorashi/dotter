# AGENTS.md

Repo-local rules for AI agents working on this fork of
[SuperCuber/dotter](https://github.com/SuperCuber/dotter).

## The vision

> **Dotfiles management with first-class support for single-source, multiple-targets and
> templates. Written in Rust.**

Things that stay true regardless of implementation:

- **One tree, all machines.** Git branches per machine are the thing being replaced — you
  are permanently checked out on one, so every machine drifts while sharing most of its
  functionality.
- **Destinations are declared next to their source.** All targets for a file live together,
  in TOML. Scattering them across per-machine files is the design that was rejected at the
  outset.
- **A machine is an entity, not a set of flags.** It composes layers it mostly shares with
  other machines.
- **Live edits must survive.** Apps rewrite their own configs — increasingly so, especially
  TUIs. An edit made in the app must find its way home, not be clobbered or lost.
- **Prefer a link over a rendered copy.** A link round-trips for free; a copy creates the
  hard problem. Template only what cannot be linked.
- **Bootstrap from nothing.** A bare machine with only a shell must reach a fully deployed
  config without hand-editing any file.
- **Nothing hand-written that is not tracked.**

## Working rules

### Do not write code until the plan is settled

**Hard rule.** No implementation until *both*:

1. the user is explicitly satisfied with the plan, and
2. you have found no remaining inconsistencies in it.

If you spot a contradiction, surface it and stop — do not "fix it while I'm here".
Jumping to `src/` mid-discussion has already broken this repo once
(`b07664d`, committed non-compiling). If in doubt, ask. Planning is the work; code is the
easy part.

### Never leave important thoughts in the chat

Chat is ephemeral and gets truncated. Any finding, decision, rejected alternative or
verified fact belongs in a file, in the same turn it is produced:

| what | where |
|---|---|
| architecture, rationale, rejected alternatives, verified facts | `docs/DESIGN.md` |
| ordered actionable work | `docs/todo.md` |
| rules for agents, project vision | `AGENTS.md` (this file) |

Record **why** something was rejected, not just what was chosen. Several decisions here
have been re-litigated because the rejection reason was only ever spoken.

### The plan must be executable by a fresh agent

Assume zero conversational context. Every item in `docs/todo.md` must be actionable from
`docs/DESIGN.md` alone — including file paths, line numbers, and the reason.

### Verify, do not assert

Every factual claim in the docs is expected to be checked against source, a running
binary, or an API — and marked as verified. Claims that turned out wrong when tested:
"mergiraf fixes adjacent-line conflicts" (it does not), "mergiraf is ~6.5 MB" (71 MB
extracted), "`base` depends on curl" (it depends on `pacman`, which depends on `curl`).
Assume the same about anything currently unverified.

## The upstream maintainer

Measured from the GitHub API, not vibes:

- Small, obviously-correct PRs merge **same day** (#213 same-day, #208 in 5 days).
- Feature PRs are **0 for 5**. #190 has sat untouched for 15 months; #214/#216 have zero
  comments.
- Stated position: *"I see the project as mostly feature-complete with some non critical
  bugs. I'm not interested in transferring maintenance."*
- No `CONTRIBUTING.md`, no PR template, discussions disabled.
- He answers *issues* quickly and politely, and says "PRs welcome" often — but open PRs
  rot.

What follows from that:

- **Optimise for the same-day bucket.** One concern per PR, squashed, small.
- **Answer his stated objections in the PR body.** On #186 he named two blockers (TOML
  forbids duplicate keys; `target = ""`-disable and local-override semantics must survive).
  Pre-empting them reads as considerate; ignoring them reads as work for him.
- **Close an existing issue** where one exists — #196, #186, #193, #51. An unrequested
  feature is a much harder sell.
- **Never break `cache.toml` without a version + migration.**
- **Two open PRs maximum.** A queue reads as a burden.
- For anything he has personally given up on (#51), a **working demo beats a design doc**.

Full branch layout and the fork-only list are in `docs/DESIGN.md` → *Upstreaming strategy*.

## Repo layout

```
docs/DESIGN.md    the architecture and every decision behind it
docs/todo.md      ordered work items, gated on each other
bootstrap/        install.sh, install.ps1, router.js  — fork-only, never upstreamed
src/              dotter itself
```

Branch `viktorashi` is the fork's working branch and carries all of the above. Upstream
branches are cut fresh from `origin/master` and contain **only** `src/` + `tests/`.

## Current state

- `master`/`viktorashi` contains a **non-compiling** `src/config.rs` from commit `b07664d`
  — a half-applied `machine` field. It is the right idea (Phase 3) but was written without
  agreement. Revert or complete it deliberately; do not build on it accidentally.
