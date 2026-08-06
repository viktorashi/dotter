# TODO

Ordered. Each entry is an independently reviewable unit. See `docs/DESIGN.md` for the
reasoning behind every one of these — **do not start an item without reading its section
there.**

Status legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` dropped

---

## Phase 0a — port the dotfiles using only what ships today

`[ ]` Express every machine as `.dotter/machines/<name>.toml` + shared layers, using
composition only, **zero content templates**. Select with `-l` for now (the `machine`
pointer does not exist yet).

`[ ]` Count the files that genuinely need *intra-file* variation which no app-native
`include` directive can absorb.

**This number gates Phases 4 and 5.** If it is zero, the reverse-sync machinery has no
users and must not be built. Nothing downstream is justified until this is measured.

---

## Phase 0b — golden config test corpus  → upstream `up/00-tests`

`[ ]` Add `tests/` with fixture configs asserting merged output.

Verified: dotter has **no `tests/` directory** and 19 unit tests total. `--dry-run` only
bumps verbosity (`args.rs:123`); there is no validate-only path.

A `validate` subcommand risks rejection as redundant with `--dry-run`. A golden-file corpus
is pure addition, zero risk, and is the backwards-compatibility proof every later phase
depends on.

`[ ]` **Probe PR:** cherry-pick `Juemuren/dotter`'s watch debounce (+21/-3, `src/watch.rs`
only), closing open issue **#196**. Not our code, near-zero cost, and it measures the one
unknown that shapes everything: does the maintainer merge a small obviously-correct fix,
and how fast?

---

## Phase 1 — Windows hard link + junction fallback  → upstream `up/01-winlink`

`[ ]` When `symlinks_enabled` is false, use hard links for files and NTFS junctions for
directories instead of copying.

**Highest-value item in the plan.** `deploy.rs:67-84` currently converts *every* file to a
rendered copy when symlinks are unavailable — so on a Windows box without Developer Mode,
nothing round-trips and the reverse-sync problem applies to 100% of files. Both hard links
and junctions are privilege-free, and a hard link shares an inode, preserving round-trip.

`[ ]` Document the limits honestly: same-volume requirement; junctions are directory-only;
fall back to copying when neither is possible.

Must land **before** Phases 4/5, or their cost estimate is wrong.

---

## Phase 2 — cherry-pick variables in target paths  → fork-only

`[ ]` Cherry-pick upstream PR **#190** (`balthild:master`, +106/-13, `src/config.rs`) into
the fork. Open and unreviewed since 2024-11-06.

Lets a destination stay next to its source while varying per machine:

```toml
"nvim" = "{{ config_dir }}/nvim"          # global.toml
```
```toml
[variables]                                # .dotter/machines/win-work.toml
config_dir = "${APPDATA:-/nonexistent}"
```

One variable per machine replaces N per-file overrides. **Do not re-open this upstream** —
duplicating a rotting PR is worse than nothing. If it ever merges, drop the cherry-pick.

`[ ]` Verify it composes with the `machine` pointer (both touch `config.rs`; expect
conflicts with `up/02-machine`).

---

## Phase 3 — machine selection  → upstream `up/02-machine`, then fork-only

`[ ]` `LocalConfig.machine: Option<String>` resolving `.dotter/machines/<name>.toml`.
Machine files may not chain.

`[ ]` **Guard:** exactly one of `machine` or `packages` must be present. Defaulting
`packages` without this turns a loud parse failure into a silent deploy-nothing.

`[ ]` Revert or complete `b07664d` — a half-applied `machine` field that **does not
compile** (`config.rs:309`, missing field in a `LocalConfig` initializer). It is the right
idea, written without agreement. Do not build on it accidentally.

`[ ]` `dotter init-machine` — `inquire` fzf-style picker listing `.dotter/machines/*.toml`,
writing the single generated line to gitignored `local.toml`. **Fork-only.**

`inquire = "0.9"` — defaults are `["macros","crossterm","one-liners","fuzzy"]` and it
requires `crossterm ^0.29.0`, which dotter already pins. No second terminal backend.

`[ ]` Bootstrap scripts (`bootstrap/install.sh`, `install.ps1`, `router.js`) — already
drafted, need the picker to exist. **Fork-only, permanently.**

---

## Phase 4 — `dotter merge` + `dotter setup-git`  → gated on Phase 0a

`[ ]` On `TemplateComparison::Changed`, emit the 3-way (base = `.dotter/cache/`,
ours = live target, theirs = fresh render) and shell out to `merge.tool`. Implements
**#193**; SuperCuber said in #51 he is *"open to implementing this as a flag"*.

`[ ]` `dotter setup-git` — `rerere.enabled`, `merge.conflictStyle diff3`, the mergiraf
driver, `.gitattributes`. Shell out to real git: libgit2 has neither custom merge drivers
nor rerere.

`[ ]` `dotter doctor` — git, mergiraf, rerere, driver, machine, cache validity.

Two separate PRs. **Do not start if Phase 0a's number is zero.**

---

## Phase 5 — branch classification  → gated on Phase 0a, demo before PR

`[ ]` Classification as N−1 three-way merges against the other variants' renders.
Verified: clean merge → generic; conflict → machine-specific.

`[ ]` Known failure mode to handle: an addition adjacent to a divergent line yields a false
conflict. Verified that **mergiraf does not rescue this**. Safe direction — over-reports
machine-specific, never silently misfiles.

`[ ]` Write-back stays **manual in v1**: show the classification as a hint, human decides.

Closes **#51**, which the maintainer personally abandoned. **Do not PR until demoed.**

---

## Phase 6 — demo repo

`[ ]` Real dotfiles, multiple machines: one source → multiple targets; an app rewriting its
own config; the edit landing in the right place; rerere making it silent the second time.

---

## Unscheduled

`[ ]` File the two upstream issues: the expansion-before-`if` ordering bug (unreported,
verified), and the `${VAR:fallback}` vs `${VAR:-fallback}` doc error from #86.

`[ ]` Decide the fate of `.dotfiles/` — it is the abandoned hook-based `link.sh` design and
contradicts everything current. Deferred until the plan is settled.

`[ ]` Backlog: share `rerere` resolutions across machines by symlinking `.git/rr-cache` into
the dotfiles repo. Verified working. Only matters if Phase 0a's number is non-zero.
Caveat: rr-cache stores conflict pre/post images — fragments of the conflicting files.
