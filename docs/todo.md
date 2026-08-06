# TODO

Ordered. Each entry is an independently reviewable unit. See `docs/DESIGN.md` for the
reasoning behind every one of these — **do not start an item without reading its section
there.**

Status legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` dropped

---

## Phase 0a — port the dotfiles using only what ships today

**Input**: `github.com/viktorashi/dotfiles` (default branch `main`). **Not cloned on this
host** — clone it first; nothing in this phase can start without it.

The five branches are the machine entities to be collapsed into one tree:

| branch | becomes |
|---|---|
| `main` | the shared base / layers |
| `arch-wsl` | `.dotter/machines/arch-wsl.toml` |
| `leanoox` | `.dotter/machines/leanoox.toml` |
| `mac` | `.dotter/machines/mac.toml` |
| `windows10` | `.dotter/machines/windows10.toml` |

`[ ]` Clone the repo and diff the four machine branches against `main` — that diff *is* the
per-machine divergence, and it is what the machine files must encode.

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

`[ ]` **Probe PR — #196 watch recursion.** Verified: the Juemuren commit **does not
cherry-pick** (his fork predates upstream's `TaggedFilterer` → `GlobsetFilterer` migration;
the conflict is entirely in filter construction). Re-implement the 12-line debounce by hand
instead — snippet is in `docs/DESIGN.md` → *Recon log*.

`[ ]` **Root cause found — fix the filter, not the symptom.** `src/watch.rs` passes its
`!`-prefixed globs as `GlobsetFilterer::new`'s **`filters`** argument (2nd) while leaving
**`ignores`** (3rd) empty. A leading `!` is a gitignore *negation*, so it registers as a
whitelist; `filters.num_ignores()` is then `0`, and
`watchexec-filterer-globset-8.0.0/src/lib.rs:176` skips the entire filter block. **Nothing
is ever excluded.**

Verified: reproduced the loop on both Linux (132 deploys) and Windows (33) by touching one
file in `.dotter/cache`. Moving the globs to `ignores` without `!` removed the cache from
the traced changed-file set.

`[ ]` **Do not open the PR until a clean reproduction passes.** After the filter change some
runs still looped, and three test-methodology flaws were found mid-investigation. Required
before submitting:

  - deploy target **outside** the watched tree
  - `watch` log **outside** the watched tree
  - identical results at `-v` and `-vvv` (they differed; investigate why)
  - acceptance: **0 deploys** with no change, **exactly 1** per real source edit

`[ ]` Add a duplicate-**target** assertion to the corpus. Verified footgun: two packages
with different sources and the same target is *not* a config error — it fails at deploy
time, first-writer-wins by alphabetical package order. This is composition's main sharp
edge.

---

## Phase 1 — Windows hard link + junction fallback  → upstream `up/01-winlink`

**Highest-value item in the plan.** `deploy.rs:67-84` currently converts *every* file to a
rendered copy when symlinks are unavailable — so on a Windows box without Developer Mode
nothing round-trips and reverse-sync applies to 100% of files. Corporate machines are
exactly where Developer Mode is locked down.

`[ ]` Use hard links for files and NTFS junctions for directories when
`filesystem::symlinks_enabled` is false. Both are privilege-free; a hard link shares an
inode, so round-trip is preserved.

**Verified on real Windows 11, non-admin, Developer Mode OFF:** symlinks fail with
"Administrator privilege required"; hard links and junctions both succeed. Real dotter on
that box deployed a plain file as a *copy*.

`[ ]` **Directories — nearly free.** Verified: `fs::read_link` **succeeds** on a junction
and returns exactly what `filesystem::real_path(source)` returns, so the existing
`compare_symlink` already yields `Identical`. Only two things are needed: create a junction
instead of a symlink, and stop routing directories into `desired_templates` when
`symlinks_enabled` is false. **No comparison-logic changes.**

`[ ]` **Files — real work.** Verified: `fs::read_link` on a hard link fails with OS error
4390 ("not a reparse point"), so `get_file_state` returns `File(..)` and `compare_symlink`
falls to `TargetNotSymlink`.

  - `[ ]` Add a same-file check to `get_file_state` / `compare_symlink`
  - `[ ]` **Use the `same-file` crate.** Verified that
    `std::os::windows::fs::MetadataExt::file_index()` / `volume_serial_number()` are
    **unstable** (`windows_by_handle`, rust-lang#63010) and do not compile on stable.
    `same-file` returned correct results for hard links, junctions and unrelated files.

`[ ]` Document the limits honestly: hard links require **same volume**; junctions are
directory-only; fall back to copying when neither is possible.

`[ ]` Confirm `cache.toml` needs no format change (expected: none — undeploying a hard link
is the same delete as a symlink).

**Size:** smaller than the previous ~150-200 line estimate, because directories need no
comparison changes. Realistically ~80-120 lines across `filesystem.rs`, `deploy.rs` and one
new dependency.

Must land **before** Phases 4/5, or their cost estimate is wrong.

---

## Phase 2 — cherry-pick variables in target paths  → fork-only

`[ ]` Cherry-pick upstream PR **#190** (`balthild:master`, +106/-13, `src/config.rs`) into
the fork. Open and unreviewed since 2024-11-06.

**Verified**: merges cleanly onto current `origin/master`, builds, and works — one variable
in a machine file retargeted both managed files.

Syntax is shell-style `${...}`, **not** handlebars `{{ ... }}` (it uses
`shellexpand::env_with_context_no_errors`). A handlebars-style name is taken literally and
creates a directory of that name.

```toml
"nvim" = "${config_dir}/nvim"              # global.toml
```
```toml
[variables]                                # .dotter/machines/win-work.toml
config_dir = "${APPDATA:-/nonexistent}"
```

Measured precedence: config variable > environment variable; `:-fallback` works; a name
defined **nowhere** is a hard error that aborts config loading — so every env var in a
target needs a `:-fallback`.

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

## Deferred — multi-target (`FileTarget::Many`)

Not scheduled. Requirement clarified as *"different places on different machines"*, which is
one target per machine and needs no schema change. See `docs/DESIGN.md` →
*Multi-target: dropped*.

**Deferring is free and this was verified**, not assumed:

- `FileTarget` is an untagged serde enum → `Many` is purely additive, every current config
  still parses.
- Collides with `up/01-winlink` only, in the `deploy.rs` file-classification loop. One
  function, mechanically resolvable.
- No shared `cache.toml` migration to bundle: multi-target needs one, Windows linking does
  not.
- Slots in as an independent 4th branch cut from `origin/master` whenever wanted.

`[ ]` **Trigger to watch for:** a duplicate source file, or a repo-internal symlink, created
*purely* to obtain a second target. Record each instance here. Two or three justify building
it.

Known real case, currently hypothetical for this repo: VSCode + VSCodium sharing one
settings directory — `settings.json` has no include directive, so the app cannot compose it.
Workaround today is a repo-internal symlink as a second source path (needs `core.symlinks` +
Developer Mode on Windows).

If courting the maintainer ever becomes the goal, this is his most-requested unimplemented
feature (#186, *"pretty highly requested"*, *"I'm welcoming PRs on this"*) — but that is
building it for him, not for us.

---

## Unscheduled

`[ ]` File the two upstream issues: the expansion-before-`if` ordering bug (unreported,
verified), and the `${VAR:fallback}` vs `${VAR:-fallback}` doc error from #86.

`[ ]` Decide the fate of `.dotfiles/` — it is the abandoned hook-based `link.sh` design and
contradicts everything current. Deferred until the plan is settled.

`[ ]` Backlog: share `rerere` resolutions across machines by symlinking `.git/rr-cache` into
the dotfiles repo. Verified working. Only matters if Phase 0a's number is non-zero.
Caveat: rr-cache stores conflict pre/post images — fragments of the conflicting files.
