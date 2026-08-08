# TODO

Ordered. Each entry is an independently reviewable unit. See `docs/DESIGN.md` for the
reasoning behind every one of these — **do not start an item without reading its section
there.**

Status legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` dropped

---

Make it as issue-oriented as possible. No matter which PR you file, make it mention as if it closes a certain issue. If there's not an issue for it already, make one, for feature request or something, then solve it yourself lol.

## Phase 0a — port the dotfiles using only what ships today  → **DONE**

Executed in a scratch clone at `/tmp/opencode/dotfiles`, branch `reconcile`, **not pushed**.
Five commits: three merges, one restructure, two fixups. The reasoning and the measurements
are in `docs/DESIGN.md` → *Measured: what drift actually looks like* and → *Phase 0a,
measured: what actually conflicts*.

`[x]` Clone, tag the five pre-port branches (`pre-port/*`, local only) as Phase 5 ground truth.
`[x]` Reconcile all four distinct states into one tree, as its own commit, before any dotter
      config existed. 40 conflicts total: 20 from `mac`, 14 from `windows10`, 6 from `main`.
`[x]` Restructure to the two-root layout, write `.dotter/`, delete every workaround script.
`[x]` Verify end to end: deploy creates 33 links under a scratch `HOME`; undeploy removes
      all of them.
`[x]` Collapse `read-me.md` + `justfile` into one `README.md` — the pandoc split existed
      only to inline script bodies, and nothing is inlined any more.

### What it decided

- **Intra-file variation after reconciliation: zero.** Every machine-specific line was
  absorbed by `files/shell/machines/<name>.{sh,zsh}`, sourced from `.profile`/`.bashrc`/
  `.zshrc`. **The corpus needs no templates at all.** This is the gate on Phases 4 and 5 —
  see *What is now unjustified* below.
- Four distinct states, not five: `arch-wsl` and `leanoox` are the same commit.
- `main` was a fifth diverged state carrying only bare-repo machinery. It died with the model.

### Three defects found by running it, not by reading it

1. **`type` is mandatory on any complex target.** `FileTargetInnerRepr` is
   `#[serde(tag = "type")]` (`src/config.rs:65`), so `{ target = …, recurse = false }` fails
   to parse with a misleading `data did not match any variant of untagged enum
   FileTargetOuterRepr` pointing at **line 1**. `default_target_type` applies only to
   bare-string entries. This is the wart Phase 3c's `link` field removes; the error message
   is separately worth fixing.
2. **Handlebars in a hook's own comments is parsed, not ignored.** A comment reading
   `# The {{#each}} below …` aborted the deploy with an unbalanced-block parse error.
3. **Scripts escape the scratch `HOME`.** `systemctl --user` resolves the real user, not
   `$HOME`, so `scripts/systemd/10-enable.sh` enabled a unit in the *actual* session during
   a sandboxed test (cleaned up afterwards). Any future test of a tree containing `scripts/`
   must skip the dispatcher or accept real side effects.

### What is now unjustified

`[ ]` **Re-gate Phases 4 and 5.** The count they depend on came out **zero**. Reverse-sync
      into templates has no user in this corpus. Do not build `dotter merge`'s template
      path, or the branch classifier, until something actually needs a template. The
      `.gnupg` case below is the only candidate and it is one line.

### Handed back to the user, unresolved

`[ ]` `.gnupg/gpg-agent.conf` — mac needs `pinentry-program /opt/homebrew/bin/pinentry-mac`
      and the format has no include directive. Two sources, one linked per machine.
`[ ]` `.codex/config.toml` `[mcp_servers.complaints]` hardcodes
      `/mnt/c/Users/istan/repos-projects/…` — work-WSL-specific.
`[ ]` `.ssh/config` carries corporate hostnames on a public repo. The deferred *secrets* gap.
`[ ]` Dropped from `windows10` deliberately: the `proiect` alias, a ~50-line commented-out
      ltex-ls block, and a `.bashrc` that had **stale conflict markers committed** since a
      botched historical merge, wrapping a ~400-line arduino-cli completion (regenerable
      with `arduino-cli completion bash`).
`[ ]` Push the reconciled tree to `github.com/viktorashi/dotfiles` once reviewed. It is a
      history rewrite of the working model, so it is the user's call, not ours.

---

## Phase 0b — golden config test corpus  → upstream `up/config-tests`

`[ ]` Add `tests/` with fixture configs asserting merged output.

Verified: dotter has **no `tests/` directory** and 19 unit tests total. `--dry-run` only
bumps verbosity (`args.rs:123`); there is no validate-only path.

A `validate` subcommand risks rejection as redundant with `--dry-run`. A golden-file corpus
is pure addition, zero risk, and is the backwards-compatibility proof every later phase
depends on.

### Split out: `up/watch-filter` — one concern, its own branch

The watch fix below is a **bug fix, not a test addition**. It goes on its own branch,
`up/watch-filter`, cut from `origin/master`, closing #196. Bundling it with the test corpus
would violate one-concern-per-PR and drag a same-day-bucket fix behind a larger change.

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

## Phase 0c — refuse to deploy onto your own source  → upstream `up/self-overwrite-guard`

**Data loss, verified against the release binary.** With a whole-directory symlink
(`recurse = false`) plus a template entry for a file inside that directory, the template's
target resolves *through* the symlink back to its own source.

- without `--force`: refuses with `target file already exists. Skipping.`
- **with `--force`: deletes the source, then fails reading it** —
  `read template source file / read from file / No such file or directory (os error 2)`.
  The repo file was gone.

`[ ]` Guard in `src/actions.rs`: before deleting/overwriting a target, refuse if it is the
same file as the source. Use the `same-file` crate — already required by Phase 1, so no new
dependency.

`[ ]` Test in the Phase 0b corpus: whole-dir symlink + inner template + `--force` must fail
without touching the source.

Small, obviously correct, data-loss class — the bucket this maintainer merges same-day. Cut
from `origin/master`, independent of every other branch.

---

## Phase 1 — Windows hard link + junction fallback  → upstream `up/windows-link-fallback`

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
conflicts with `up/machine-field`).

---

## Phase 3 — machine selection  → upstream `up/machine-field`, then fork-only

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

`[ ]` **Reject `[files]` in a machine file.** A machine declares `packages` and
`variables` only; machine-exclusive files become a package named after the machine.
Upstream allows the override (`config.rs:408-410`) — this fork does not. Rationale:
`docs/DESIGN.md` → *A machine declares packages, never files*. **Fork-only.**

`[ ]` **Per-machine target-collision check.** For every `.dotter/machines/*.toml`, resolve
the package set including the `depends` closure, flatten, and report targets that collide.
The machine named in `local.toml` → hard error; every other machine → warn. Exclude
`target = ""` (the disable form). Compare by **containment**, not equality, so a
whole-directory link and a separate entry for a file inside it is caught — that is the
Phase 0c data-loss combination. **Fork-only** (upstream has no machine files to iterate).

`[ ]` Fix the Phase 0a `reconcile` branch of the dotfiles repo: the four
`.dotter/machines/*.toml` currently carry `[files]` blocks overriding
`files/shell/machines/<name>.{sh,zsh}`. Convert each to a package named after the machine.

---

## Phase 3b — `dotter.toml` settings file  → upstream `up/dotter-toml`, then fork-only

**The maintainer proposed this himself** and nobody built it. Verified via the API (comment
`770217516`, 2021-01-30, issue #51), while declining to hardcode a behaviour:

> "I'm open to implementing this as a flag though. Maybe it's about time we had a
> `dotter.toml` for these kinds of settings…"

Full design, including the two-files-one-job-each split and the reversal of the earlier
rejection, in `docs/DESIGN.md` → *Reversed: a `dotter.toml` settings file is worth building*.

`[ ]` **Upstream half — `up/dotter-toml`, cut from `origin/master`.** A settings struct of
`Option<T>` fields resolved in git's precedence order: compiled defaults <
`~/.config/dotter/dotter.toml` < `<repo>/dotter.toml` < CLI flags. No new subcommand, no
behaviour change when neither file exists. Open the PR quoting his own comment.

`[ ]` Settings that earn their place: `repo` (global-file-only — a repo declaring its own
location is circular), `merge.tool`/`merge.args` (Phase 4), `files_root`/`scripts_root`
(Phase 4 doctor), and the behaviour flags `force` / `noconfirm` / `diff_context_lines` /
`verbosity` — the last group being exactly the category the quote describes. The nine
`.dotter/*` path options come free with the mechanism; do not advertise them.

`[ ]` Wiki/README note on package hygiene (see `docs/DESIGN.md` → *Package hygiene*): the
source-side rule is already enforced, so document the two that are not — prefer a machine
`[files]` override over two mutually-exclusive packages sharing a source key, and know that
**target** collisions are caught only at deploy time.

`[ ]` **Guard:** `machine` must **not** move into `dotter.toml`. The deployed copy may be
rendered per machine, so naming the machine there is circular. It stays in
`.dotter/local.toml`.

`[ ]` Document the split against the existing `[settings]` table in `global.toml`
(`config.rs:89`): `[settings]` = **how files in this repo are deployed**; `dotter.toml` =
**how the tool runs**. State it, or it becomes the next confusion.

`[ ]` **Fork-only half — bootstrap.** `--clone <url>`: clone **once** into a temp dir, read
its `dotter.toml`, then `mv` the tree to the configured location. Never fetch twice. Then
route into `init-machine` (Phase 3), which short-circuits if `local.toml` is already valid.

`[ ]` The "you are in a dotter repo that git does not track" warning goes in **`dotter
doctor`**, not on every invocation — a warning printed every run is one nobody reads.

`[ ]` Supersedes the `dot` alias and makes `up/directory-flag` unnecessary: `repo` in the
global file answers "where is my dotfiles repo" from anywhere. Revisit the *Unscheduled*
trigger for `-C` once this lands.

---

## Phase 3c — one abstraction: everything deployed is a link  → fork-only

**Gated on Phase 0a finding that templates are needed at all.** The measurement says ~11
genuinely OS-specific lines in the whole corpus; if reconciliation removes them, most of
this phase is unnecessary. Design: `docs/DESIGN.md` → *One abstraction: everything deployed
is a link* and *The cache is the artifact, and git is the merge base*.

**Blocked on Phase 1.** On Windows without Developer Mode a symlink fails and a template
falls back to a copy — the exact problem this phase removes. Do not ship before
`up/windows-link-fallback`.

`[ ]` Track `.dotter/cache/` in the dotfiles repo and link the target at the cache entry
instead of `copy_file` (`actions.rs:597`). **There is no `.dotter/rendered/`** — the earlier
two-directory design is retracted; the merge base is `git show HEAD:.dotter/cache/…`.

`[ ]` Guard before writing a render: `git diff --quiet` on the cache entry. Clean → write.
Dirty → an unabsorbed live edit exists, so merge instead of overwriting. Untracked → first
deploy, write.

`[ ]` **Move the content comparison from cache↔target to git-HEAD↔worktree.** Required, not
cosmetic: `get_file_state` (`filesystem.rs:695`) calls `read_link` first, so a symlinked
target returns `FileState::SymbolicLink` and `compare_template` (`filesystem.rs:782`) falls
through to `_ => TargetNotRegularFile`. **A symlinked template target is an error state
today.** The target's own check becomes `compare_symlink`.

`[ ]` Machine-key the cache path (`cache_directory.join(source)`, `deploy.rs:304`) —
mandatory, or two machines conflict on every pull. Needs a `cache.toml` version bump and a
migration that moves the tree; the `AGENTS.md` rule is not optional.

`[ ]` **`link = "symbolic" | "hard" | "copy"` as a second, orthogonal field** — this is
what makes "a template that is also symlinked" expressible. `type` conflates two axes
(*what the source is* vs *how the target attaches*), which is why the two are mutually
exclusive today.

`[ ]` **Do not repurpose `type`.** `type = "symbolic"` currently means "do not template
this" (the maintainer's own prescribed escape hatch, #192). Reinterpreting it as a link
kind would silently *start* templating exactly those files — the ones containing `{{` —
mangling them instead of erroring. `type` stays deprecated-but-functional; the warning must
name both replacements, since one old value maps to each axis.

`[ ]` `.tmpl` as the explicit template discriminant, stripped on deploy. Collapses
`FileTarget::{Symbolic, ComplexTemplate}` to one struct with every field optional — trivially
backwards compatible under serde. `owner`, `if`, `recurse`, `append`, `prepend` all survive;
only `type` is retired, and only once `link` and `.tmpl` both exist.

`[ ]` Copy survives as a **loud fallback, never a choice** — cross-volume Windows hard links
are impossible, and root-owned system files must not resolve into a user-writable `$HOME`.
Deploy reports it; `doctor` lists every breadcrumb-less copied path.

`[ ]` Note in the docs that the cache stops being disposable and that **renders become
public** — this tightens the deferred *Secrets* gap. Ensure `detect-private-key` scope
covers the cache tree, not just `files/`.

`[ ]` Fork-only. **Do not attempt to upstream any of this.**

---

## Phase 3c-recon — verify before writing the copy-fallback rule

`[ ]` Does sudo/sshd actually reject a symlinked config that resolves to a user-writable
file? Currently **asserted, not verified** in `docs/DESIGN.md`. Run it before the claim is
written up as fact.

---

## Phase 3c-b — `up/template-detection`  → upstreamable, small

**Not gated on Phase 0a.** The bug is upstream's and bites anyone whose config contains
`{{{`; it stands even if reconciliation leaves zero templates in our corpus.

`[ ]` **Do not open a new feature request.** Already filed and closed twice: **#20**
(2020, "Some file are recognized as template when they are not" — closed by merging into
#18, which is where `type = "symbolic"` came from) and **#192** (2025, yazi `theme.toml`
with vim fold markers — answered *"use `type = "symbolic"`"*, working as designed).
Re-litigating the design loses.

`[ ]` File the **asymmetry** instead, which is unfiled and is a real bug.
`filesystem.rs:821-838`: the non-UTF-8 branch `warn!`s *and* says how to silence it; the
`buf.contains("{{")` branch is **silent**. A false positive therefore surfaces only as a
handlebars parse error on a line the user never wrote — or not at all, if the file happens
to be valid handlebars, in which case the deployed config is silently wrong.

`[ ]` Fix = one symmetric `warn!` reusing his own wording, plus `.tmpl` to silence it.
One concern, real bug, obviously correct.

## Phase 3d — reconciliation hook via `prek`  → fork-only

Design: `docs/DESIGN.md` → *Git setup* → *Reconciliation: when it runs, and what runs it*.

`[ ]` Tracked `prek.toml` at the dotfiles repo root with the six `repo = "builtin"` hooks.
The decisive one is **`destroyed-symlinks`**: `arch-wsl` tracks a real symlink (mode
`120000`, `.config/systemd/user/default.target.wants/agents-render.path`), and a git that
cannot make symlinks — the Windows default — turns it into a text file that a commit then
destroys silently.

`[ ]` `dotter reconcile --check` as a `repo = "local"` hook scoped to
`files = "^\.dotter/rendered/"`: for each staged artifact, if it differs from a fresh
render of its template, the template is stale — block and name `dotter merge`.

`[ ]` Commit time, not deploy or push. Deploy is when things go out and the capture already
happened via the symlink; push is too late because the history would already claim a truth
it does not have.

`[ ]` `dotter setup-git` gains `core.hooksPath` and runs `prek install` **if prek is on
PATH**, printing a one-line note otherwise. **Optional dependency, exactly like mergiraf** —
`bootstrap/` still installs only `git` + `dotter`, or *bootstrap from nothing* breaks.

`[ ]` prek is not installed on this host (`command -v prek` → missing). Install before
writing the config, and verify with `prek validate-config` + `prek run --all-files` against
the corpus clone, which should immediately flag the 1.28 MB `autohotkeys.exe` and any CRLF.

---

## Phase 4 — `dotter merge` + `dotter setup-git`  → gated on Phase 0a

`[ ]` On `TemplateComparison::Changed`, emit the 3-way (base = `.dotter/cache/`,
ours = live target, theirs = fresh render) and shell out to `merge.tool`. Implements
**#193**; SuperCuber said in #51 he is *"open to implementing this as a flag"*.

`[ ]` `dotter setup-git` — `rerere.enabled`, `merge.conflictStyle diff3`, the mergiraf
driver, `.gitattributes`. Shell out to real git: libgit2 has neither custom merge drivers
nor rerere.

`[ ]` `dotter doctor` — git, mergiraf, rerere, driver, machine, cache validity.

`[ ]` **`dotter doctor` layout assertions** — the thing that makes `files/` vs `scripts/`
enforceable rather than merely conventional (`docs/DESIGN.md` → *Imperative setup*):

- every path under `files/` appears as a source key in the merged config (else it is
    deployed nowhere and is silently dead);
- no path under `scripts/` appears as a source key;
- every `scripts/<name>/` matches a declared package (`undeploy/` is a reserved
    subdirectory name, not a package) name (else it silently never runs).
    Note a script-only package is legal — `Package.files` is `#[serde(default)]`, verified —
    so `certs` may declare zero files;
- **for every deployed directory, target-side files with no source entry.** Expanded
    directories silently drop anything the app writes into them (`lazy-lock.json` was
    verified invisible). Same orphan-detection as the `files/` rule, pointed the other way.
    This one must **also report during `deploy`**, not only under `doctor` — the
    constitution's "guaranteed, no edge-cases" is not satisfied by a check you have to
    remember to run.

  Roots are configurable, defaulting to `files/` and `scripts/`; absent roots skip the
  check, so this is inert for existing users. Plausibly upstreamable on its own as
  `up/doctor-layout`, but only after the fork demonstrates it.

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

## Deferred — `run_once` / `run_onchange` script hashing

Scripts under `scripts/<package>/` run on every deploy and must be idempotent. Hash-based
run-once semantics are deliberately **not** built yet.

Cheap when wanted, because it belongs inside dotter rather than in shell: rendered hooks
already land in `.dotter/cache/`, and `filesystem::compare_template` already answers "did
the rendered content change". No new state file, no `sha256sum`/`certutil` split.

**Trigger to watch for:** ~~two or more scripts growing a hand-written marker guard~~ —
**superseded.** The real trigger is the first use of `dotter watch` on a tree that has any
`scripts/`, because watch redeploys on every source edit and the dispatcher re-runs every
script of every selected package on every deploy. Editing one line of `.zshrc` would re-run
`install-init-stuff.sh`. Idempotent is not the same as cheap. See `docs/DESIGN.md` →
*Gaps* → *`dotter watch` re-runs every script on every save*. Interim mitigation if needed
sooner: skip the dispatcher when running under `watch`.

---

## Deferred — secrets

Wanted, explicitly low priority. `.ssh/config` is the live case (internal corporate
hostnames on a public repo); the holding pattern until then is to keep it out of the repo
by hand.

Three options, unchosen, in `docs/DESIGN.md` → *Gaps* → *Secrets*. The private-repo layer
is the cheapest because `bootstrap/` already clones one repo; in-repo encryption is the
awkward one because the key must arrive before bootstrap can decrypt anything.

---

## Deferred — multi-target (`FileTarget::Many`)

Not scheduled. Requirement clarified as *"different places on different machines"*, which is
one target per machine and needs no schema change. See `docs/DESIGN.md` →
*Multi-target: dropped*.

**Deferring is free and this was verified**, not assumed:

- `FileTarget` is an untagged serde enum → `Many` is purely additive, every current config
  still parses.
- Collides with `up/windows-link-fallback` only, in the `deploy.rs` file-classification loop. One
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

`[ ]` **Trigger to watch for:** the first *non-shell* caller of dotter (systemd unit, a
script, PowerShell). One `dot` alias is fine; needing a PowerShell function and a `.bat` too
means three copies of one line, and a `-C`/`--directory` flag (~5 lines, one
`set_current_dir` in `main`, the `git -C` convention) becomes the smaller thing. Would be its
own branch, `up/directory-flag`. Record instances here.

`[ ]` File the two upstream issues: the expansion-before-`if` ordering bug (unreported,
verified), and the `${VAR:fallback}` vs `${VAR:-fallback}` doc error from #86.

`[ ]` Decide the fate of `.dotfiles/` — it is the abandoned hook-based `link.sh` design and
contradicts everything current. Deferred until the plan is settled.

`[ ]` Backlog: share `rerere` resolutions across machines by symlinking `.git/rr-cache` into
the dotfiles repo. Verified working. Only matters if Phase 0a's number is non-zero.
Caveat: rr-cache stores conflict pre/post images — fragments of the conflicting files.
