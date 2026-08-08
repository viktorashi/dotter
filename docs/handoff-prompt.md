Nothing from this turn needs saving — re-reading `watch.rs` and `watchexec-filterer-globset` only confirmed what's already written in `docs/DESIGN.md` § *Recon log*. So the handoff is clean.

---

```markdown
You're picking up work on a fork of dotter (a dotfiles manager) at `/home/istan/dotter`.

## Read these first, in order
1. `AGENTS.md` — the vision, the working rules, the branch policy. The rules are
   binding, especially: verify don't assert; never leave findings in chat, they go in
   `docs/`; no PR ever from the `viktorashi` branch.
2. `docs/DESIGN.md` — every architectural decision and, importantly, every *rejected*
   alternative with its reason. Long. The `## In one page` section at the top is the
   way in. Don't re-litigate anything in here without reading why it was decided.
3. `docs/todo.md` — the ordered work queue. This is what to do next.

Ignore `docs/session-*.md` in searches — they're chat dumps, superseded by the two docs
above.

## Where things stand
- `src/` on branch `viktorashi` is byte-identical to `origin/master`. All fork work so
  far is documentation plus one shipped upstream fix.
- Phase 0a is done: the user's dotfiles (`github.com/viktorashi/dotfiles`, five diverged
  branches) were reconciled into one tree on the `reconcile` branch. Headline result:
  **zero files needed templating** — all machine divergence fit into shell includes.
  That result re-gates Phases 4 and 5, which are now unjustified until something needs
  a template.
- Phase 0c is done and upstream: issue #218 → PR #219, branch `up/self-overwrite-guard`.

## Your next task: Phase 0b′, branch `up/watch-filter` (upstream issue #196)

`dotter watch` deploys in an infinite loop. Root cause is **certain and verified**:
`src/watch.rs` passes `!`-prefixed globs as `GlobsetFilterer::new`'s 2nd argument
(`filters`) leaving the 3rd (`ignores`) empty. A leading `!` is a gitignore *negation*,
so `filters.num_ignores() == 0`, and `watchexec-filterer-globset-8.0.0/src/lib.rs:176`
skips the entire filter block. Nothing is ever excluded, so dotter's own cache writes
retrigger it. Fix direction: move the globs to `ignores` and drop the `!`.

**It is NOT established that this fix alone stops the loop.** Some runs still looped.
Three test-methodology traps were found the hard way and are documented in
`docs/DESIGN.md` § *Recon log* — read that subsection before testing, it will save you
an afternoon.

Acceptance criteria before opening the PR:
- 0 deploys when nothing changes
- exactly 1 deploy per real source edit
- deploy target **and** log file both outside the watched tree
- identical results at `-v` and `-vvv`

Branch is cut fresh from `origin/master`, contains only `src/` (+ `Cargo.*` if needed),
named `up/watch-filter`, pushed to remote `viktorashi`. The user opens the PR, not you —
hand them a body and a title.

## How this maintainer behaves (measured, matters for scoping)
Small obviously-correct bug fixes merge same-day. Feature PRs are 0-for-5; #190 has sat
unreviewed since Nov 2024. He answers *issues* fast and politely. So: file an issue
first, let him object, then PR against it. Never open a feature PR cold.
```

Two notes for whoever picks it up, which I'd tell them out loud rather than put in the prompt: the `up/watch-filter` job is genuinely riskier than #218 was — the fix is a one-liner but the *verification* is the work, and last time three separate testing mistakes produced three different wrong answers. And there's a stale top-level `.dotfiles/` directory tracked on `viktorashi` (13 files, an abandoned early worked example) that should just be deleted when convenient.

---


