# TODO

Ordered. Each entry is an independently reviewable unit. See `docs/DESIGN.md` for the
reasoning behind every one of these — **do not start an item without reading its section
there.**

Status legend: `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` dropped

---

## Phase 0a — port the dotfiles using only what ships today

**Input**: `github.com/viktorashi/dotfiles`, five branches. **Already measured** — the
numbers, the topology and what they decide are in `docs/DESIGN.md` → *Measured: what drift
actually looks like*. Read that section before touching anything here; it is the
justification for the whole plan.

Headline results, so this phase is actionable without re-measuring:

- Deployment today is a bare repo with `--work-tree=$HOME`, so **the repo is `$HOME`** and
  a destination cannot be chosen. That single constraint produced every workaround in the
  tree.
- `main` is **not** a base — it is behind every machine branch by 156–372 commits. Do not
  treat it as the shared layer; build the shared layer from what the machine branches
  *agree* on.
- `arch-wsl` and `leanoox` are **byte-identical**. Two machine files, same layers.
- **98% of the divergence is drift** (1478 changed lines between `arch-wsl` and
  `windows10`; 29 OS-flavoured; ~11 genuinely OS-specific once the README is excluded).
- **~15 files of 94 are truly machine-bound** (`auto-hotkey/`, `docs/vindovs/`,
  `security-crypto/*.ps1`, `.bash_profile` on Windows; `.config/systemd/user/` and
  `/etc/mc/mc.vim.keymap` on Linux).

`[ ]` Design the target tree **from the dotter model, not from the current repo layout.**
The existing structure is shaped by the `$HOME`-mirror constraint, which this fork removes.
Where the current tree only looks the way it does because a destination could not be
expressed, do not carry the shape over. Specifically:

  - `docs/startup-scripts/link-nvim.{ps1,bat}` — 90 lines of PowerShell + a `.bat` twin,
    junctioning one directory, demanding admin it does not need. **Delete both**; Phase 1
    plus a machine file replaces them.
  - `docs/linkables/link_them.sh` — one `sudo ln -s` into `/etc`. **Delete**; dotter has
    `owner = "root"`.
  - `docs/` currently mixes real config, one-shot setup scripts and dead `legacy-shi/`.
    Split deliberately; do not port it as one blob.

`[ ]` Reconcile the drift **first, as its own commit, before any dotter config exists.**
The 1478-line divergence is not machine-specific and must not be encoded as if it were.
Pick a winner per file (usually the newest branch), and only what survives that pass is
eligible to become a machine difference. Skipping this step bakes two years of accident
into the new structure permanently.

`[ ]` Adopt the two-root layout — `files/` for anything placed somewhere, `scripts/<package>/`
for anything executed. Rationale, the failure modes each one has, and the verified hook
dispatcher are in `docs/DESIGN.md` → *Imperative setup*. The dispatcher needs **no dotter
source change**; write `.dotter/post_deploy.sh` as the template shown there and it works
today.

`[ ]` Convert the existing imperative scripts into `scripts/<package>/` entries. From the
corpus these are `docs/startup-scripts/setup-certficates.sh` (→ `scripts/certs/`),
`docs/git-settings.sh`, `docs/startup-scripts/install-init-stuff.sh`,
`docs/vindovs/manage-startup-apps.ps1`. Each must be **idempotent** — they run on every
deploy.

`[ ]` Note which of `docs/` is neither: `docs/cfg-bin/git` is a wrapper meant to be on
`PATH`, so it is a `files/` entry, not a script. `docs/legacy-shi/` is dead — delete it.

`[ ]` Place the **on-demand** commands — the third category, neither placed nor run on
deploy. Rules and the per-file verdicts are in `docs/DESIGN.md` → *The third category:
things you run yourself*. Concretely:

  - `restore-nvim-session.sh`, `tmux-config.sh` — one line each. **Delete**, make them shell
    aliases.
  - `no-exe-wrapper-scripts.sh` — generates two static 2-line wrappers. **Delete**; commit
    `files/bin/wt` and `files/bin/im` instead.
  - `generate-readme.sh` **and** `docs/Makefile` — the same `pandoc` line, twice. Both go;
    one `just generate-readme` recipe replaces them. That is the **only** recipe left.
  - `backup-remove-and-clone.sh` — **delete**. It is the current bootstrap and every line is
    replaced (see `docs/DESIGN.md` → *Gaps*).
  - `startup-scripts/configupdatemason.sh` — **delete**. It snapshots `ls
    ~/.local/share/nvim/mason/packages`, which is the cause of the drift, not a fix for it.
    Declare one shared roster as a plain file instead.

`[ ]` **Do not hand-merge `mason.lua`.** It is *generated* (see above), so its two divergent
LSP rosters are a snapshot artifact — whichever machine ran the script last won. Reconcile
by taking the union of what is actually wanted, commit that as an ordinary file, and leave
it out of the review diff below.

`[ ]` Keep `.ssh/config` out of the ported tree by hand **before the first push** — it
carries internal corporate hostnames on a public repo. Real secrets support is deferred
(`docs/DESIGN.md` → *Gaps* → *Secrets*).

`[ ]` Rewrite `conf` and the `conflazygit`-style aliases as plain `git -C ~/.dotfiles`
wrappers. No design needed.

`[ ]` Write `.dotter/post_deploy.bat` to resolve `sh.exe` **by absolute path derived from
`git`** — `where git` → `…\Git\cmd\git.exe` → `…\Git\bin\sh.exe`. Verified on the real
box: bare `sh` is not on `PATH`, and bare `bash` is `C:\WINDOWS\system32\bash.exe`, the WSL
launcher, which would run the Windows deploy hook inside Linux and appear to succeed. See
`docs/DESIGN.md` → *Gaps*.

`[ ]` Deploy `.config/nvim/` **expanded** (dotter's default), not `recurse = false`.
Verified trade in `docs/DESIGN.md` → *Decided: directories expand by default*: expansion is
the only mode that permits templating a file inside, which the machine-specific keybindings
require. Accept that new app-written files must be added by hand until the doctor check
above exists. **Never** combine a whole-directory symlink with a template entry inside it —
that path deletes the source file (verified).

`[ ]` Define `dot` as `(cd ~/.dotfiles && dotter)` — a subshell, so the caller's CWD is
untouched. Dotter has no chdir flag and resolves every path from CWD; it fails loudly
elsewhere, so the alias is the whole fix.

`[ ]` Express every machine as `.dotter/machines/<name>.toml` + shared layers, using
composition only, **zero content templates**. Select with `-l` for now (the `machine`
pointer does not exist yet).

`[ ]` Count the files that genuinely need *intra-file* variation which no app-native
`include` directive can absorb. Expected from the measurement: **~3** (`.zshrc`,
`docs/shared.sh`, `.config/nvim/lua/config/keymaps.lua`).

**This number gates Phases 4 and 5.** If it is zero, the reverse-sync machinery has no
users and must not be built. Nothing downstream is justified until this is measured.

`[ ]` **Produce a review list, do not decide alone.** Most of the 1478 lines reconcile
mechanically (take the newest branch). Some do not — where both sides made a deliberate,
incompatible edit. Collect every such file into a single diff for the user to adjudicate.
`mason.lua` was the presumed example and is **not** one (it is generated — see above), so
this list may turn out short; report the count either way. Explicitly deferred by the user:
*"what cannot be easily reconciled from my config you give to me to look at, but not right
now."*

`[ ]` Keep the pre-port branches reachable (tag them). Phase 5's classifier needs them as
ground truth: a run over `arch-wsl` vs `windows10` should surface ≈29 candidate lines, not
1478.

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
  - every `scripts/<name>/` matches a declared package name (else it silently never runs).
    Note a script-only package is legal — `Package.files` is `#[serde(default)]`, verified —
    so `certs` may declare zero files;
  - **for every deployed directory, target-side files with no source entry.** Expanded
    directories silently drop anything the app writes into them (`lazy-lock.json` was
    verified invisible). Same orphan-detection as the `files/` rule, pointed the other way.

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

`[ ]` File the two upstream issues: the expansion-before-`if` ordering bug (unreported,
verified), and the `${VAR:fallback}` vs `${VAR:-fallback}` doc error from #86.

`[ ]` Decide the fate of `.dotfiles/` — it is the abandoned hook-based `link.sh` design and
contradicts everything current. Deferred until the plan is settled.

`[ ]` Backlog: share `rerere` resolutions across machines by symlinking `.git/rr-cache` into
the dotfiles repo. Verified working. Only matters if Phase 0a's number is non-zero.
Caveat: rr-cache stores conflict pre/post images — fragments of the conflicting files.
