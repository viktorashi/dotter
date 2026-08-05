# Dotter fork: design

Goal: a dotfile manager where (a) one source file can go to different places per
machine, and (b) when an app rewrites its own config in place, that edit finds its
way back into the right template branch instead of being lost or silently clobbered.

Everything here is additive. Existing `global.toml` / `local.toml` must keep working
unchanged.

## The problem, stated precisely

Two regimes:

- **Symlinked file** — target *is* the repo file. App rewrites it, `lazygit` shows it.
  Nothing to build. (SuperCuber, dotter#51: *"in case of a symlink, the filesystem
  already keeps both locations in sync"*.)
- **Templated file** — target is a rendered *copy*. App rewrites it, and the edit is
  stranded: it is not in the repo, and the next deploy wants to overwrite it.

Dotter already **detects** this. `filesystem::compare_template` (`src/filesystem.rs:782`)
compares `.dotter/cache/` against the target and yields `TemplateComparison::Changed`,
at which point deploy refuses:

```
[ERROR] Updating template ".gitconfig" -> "C:\Users\USER/.gitconfig" but target contents were changed. Skipping
```

What is missing is everything after detection. Open, unimplemented:

- dotter#51 "read-only rendered files" — maintainer stalled on it:
  *"the `Changed` comparison is between cache (how I left the file) and target, but
  diff is between rendered and target... :/ my brain hurts"*
- dotter#193 "offer to launch a merge tool when target contents were changed" —
  **zero maintainer response**
- dotter#186 "symlink config to multiple locations" — *"pretty highly requested...
  I'm welcoming PRs on this :)"*

## Prior art: nobody shipped this

Fork audit (GitHub API, 2026-08):

- **dotter**: 75 forks, 7 ahead of upstream. Their total divergence is CI/ARM builds
  (orhun), dependabot bumps, feature-flags for scripting/watch (einetuer), a watch
  debounce (Juemuren, +21/-3 in `src/watch.rs`), template recursion (faffeldt).
  **None touch reverse-sync or multi-target.**
- **rotz**: 13 forks, 2 ahead. `bltavares` (+9, his 5 ignored PRs), `kaerum` (+1).
  **None.**

Closest shipped things elsewhere:

| Tool | Reverse-sync on a template | Mechanism |
|---|---|---|
| chezmoi | partial, manual | `chezmoi merge` → 3-way in your editor: Destination (live) / Source (the raw `.tmpl`) / Target (rendered). You hand-type the template edit. |
| chezmoi | lossy | `add --autotemplate` regenerates a template by greedy string→`{{ .var }}` substitution; discards your existing conditionals and comments |
| chezmoi | refuses | `re-add` — silent `continue` on `Attr().Template` |
| dotdrop | refuses | `update -P` prints a `diff -u tmp live \| patch template` one-liner; docs say "not bullet-proof" |
| yadm | none | `yadm alt` overwrites the render |
| rotz | n/a | dodges it — templates the *manifests*, deploys dotfiles as raw symlinks |
| `mermonia/peridot` (Go, 0★) | none | renders to an artifact dir and **symlinks the artifact** — good idea, one-directional |
| `cebarks/dotm` | vaporware | advertises `dotm adopt`; `adopt` appears in README/CHANGELOG/docs and **zero times in `src/`** |

Conclusion: wanted by many, shipped by none, one maintainer publicly gave up.

## Architecture: what we build vs. what we delegate

Unix seams. Dotter's contribution is **merge base + branch classification**. Everything
else is an existing tool.

| Job | Owner |
|---|---|
| Which source file → which target(s) on this machine | **dotter** |
| What did I last write there (the merge base) | **dotter** — `.dotter/cache/` already is exactly this |
| Detect that the target drifted | **dotter** — `compare_template` already does this |
| Produce a 3-way conflict | **git** — `git merge-file --diff3` |
| Resolve it structurally | **mergiraf** |
| Remember the resolution | **git rerere** |
| Decide which template branch an edit belongs to | **dotter** (the new part) |
| Show me the result | lazygit / editor |

### mergiraf

<https://mergiraf.org> — Rust, ★414, active (last commit 2026-08-04), tree-sitter based
syntax-aware git merge driver. Supported declarative formats: **TOML, YAML, JSON, INI,
HCL, XML, Java properties, devicetree, go.mod**, plus Lua, Nix, Bash. Falls back to
line-based merging when a file cannot be parsed — which is exactly the desired
degradation for formats with no structure.

**Depend on the binary, never the crate.** It carries ~30 tree-sitter grammars; linking
it in would dwarf dotter's own 4400 lines in build time and binary size.

**It is an optional runtime dependency.** Only needed when a conflict actually occurs.
Without it dotter falls back to plain `git merge-file`.

### rerere

`git rerere` records a conflict resolution and replays it automatically next time. Not
available via libgit2 — verified: `libgit2/include/git2/merge.h` exposes only
`default_driver` (`text`/`binary`/`union`), with **no custom merge driver registration
and no rerere at all**. Reimplementing it inside dotter is out of scope and out of
character.

The cascade `mergiraf → rerere → human` is what git already does natively once both are
registered: the merge driver runs first, rerere then checks for a recorded resolution,
the remainder lands on you. **Nothing to build.**

**Sharing resolutions across machines — verified working.** `rr-cache` lives at
`$GIT_DIR/rr-cache` and is not configurable, but symlinking it works:

```sh
rm -rf .git/rr-cache
ln -s "$DOTFILES/.rr-cache" .git/rr-cache
```

Tested: resolution recorded through the symlink, and replayed automatically on a repeat
of the same conflict.

> **Caveat:** rr-cache stores conflict pre/post images, i.e. *fragments of the
> conflicting files*. Committing it commits config snippets. Fine for dotfiles;
> dangerous if a conflict ever occurs in a file containing a credential.

## The new part: branch classification

Getting a merged *output* back into a `.hbs` requires inverting the render. Handlebars is
not invertible. The trick that avoids needing it:

> **Render every declared machine's variant of the template. Diff the renders against
> each other.** Lines identical across all N renders are generic. Lines that differ are
> machine-specific, and you know exactly which branch produced them.

That yields a line-range → branch map with **zero template introspection** — no
handlebars AST, no provenance instrumentation.

An incoming live edit then classifies itself:

- entirely within generic lines → apply to the template body
- entirely within one machine's exclusive lines → apply to that `{{#if}}` branch
- spans both, or lands inside a `{{variable}}` substitution → **emit the artificial
  conflict**, hand to mergiraf → rerere → human

### The constraint this requires

Rendering all variants from one machine is only possible if every branching input is
data dotter already has.

> **A content template may branch only on variables whose complete set of possible
> values is declared in a tracked file. It may not branch on live probing
> (`env_var`, `eval "shell cmd"`, filesystem checks).**

This applies to file **contents** only. Target **paths** are a different code path and
may still use env expansion — `${APPDATA:-/nonexistent}` already works today.

A content template that genuinely needs live env opts out of classification and always
routes to manual conflict. Acceptable degradation.

## Declared machines

```toml
[settings.machines]
arch-laptop = { os = "linux", distro = "arch" }
desktop     = { inherits = "arch-laptop" }
work-rhel   = { inherits = "arch-laptop", distro = "rhel" }
win-work    = { os = "windows", version = "10" }
```

Keyed by hostname. Dotter **already** falls back to `<hostname>.toml` when `local.toml`
is missing (`config.rs:159-171`), so a new machine self-identifies with zero config;
`--machine` overrides. `inherits` is a BTreeMap merge (~30 lines).

Per-machine, not per-OS: arch-laptop, desktop and work-rhel are all `linux` and must be
allowed to differ.

Backlog: a TUI picker that proposes an existing machine to inherit from based on detected
distro / Windows version. Not core.

## Multi-target

`FileTarget` is already an untagged serde enum (`config.rs:48-55`), so adding a variant is
**fully backwards compatible** — every config that parses today still parses.

```toml
"vscode/settings.json" = [
  { target = "~/.config/Code/User/settings.json",   if = "dotter.linux" },
  { target = "${APPDATA:-/nonexistent}/Code/User/settings.json", if = "dotter.windows" },
]
```

The diff engine is **already pair-keyed** — `deploy.rs:265-285` collapses to
`BTreeSet<(PathBuf, PathBuf)>` before diffing. Only three declarations assume one-to-one:

- `Files = BTreeMap<PathBuf, FileTarget>` (`config.rs:74`)
- `Cache { symlinks: BTreeMap<PathBuf,PathBuf>, templates: ... }` (`config.rs:210`)
- `desired_symlinks: BTreeMap<PathBuf, SymbolicTarget>` (`deploy.rs:80`)

plus `.remove(source)` at `deploy.rs:293,305,325,347` must become target-aware.

**The one real break is `cache.toml`.** It is generated, never hand-authored, so: add a
`version` field defaulting to 0 and migrate on read.

**Semantics that must be pinned down** (SuperCuber's two stated blockers on #186 — having
crisp answers here is most of what gets it merged):

- `target = ""` disables a file. With an array: whole-value `""` disables everything;
  individual entries carry their own `if` instead.
- local.toml overriding a source key **replaces the entire array**, not element-wise.
  Predictable, and matches existing override semantics.

## Bootstrap

Dotter already publishes prebuilt binaries: `dotter-linux-x64-musl`,
`dotter-linux-arm64-musl`, `dotter-macos-arm64`, `dotter-windows-x64-msvc.exe`.

So the installer is ~30 lines:

```
detect os/arch → download release binary → git clone <repo> → dotter deploy
```

Target UX: `curl <host>/install.sh | sh -s viktorashi` — defaults to
`viktorashi/dotfiles`, accepts a full remote URL, picks the machine from
`settings.machines` (hostname first, prompt as fallback).

**Explicitly out of scope:**

- **Package-manager abstraction** (scoop/yay/brew/cargo). Known tarpit, and dotter
  already has the right extension point: `pre_deploy` hooks. "Install my packages" is a
  user hook script, not dotter's job.
- **mergiraf as a hard dependency.** Only needed at conflict time. Install lazily.

## Git setup

libgit2 cannot do this, so shell out to real git (`std::process::Command`; no `git2`
dependency needed):

```
dotter deploy   → notices merge.mergiraf.driver / rerere.enabled unset
                → "run `dotter setup-git`"

dotter setup-git → git config rerere.enabled true
                 → git config merge.conflictStyle diff3
                 → git config merge.mergiraf.driver '...'
                 → writes `* merge=mergiraf` to .gitattributes
                 → warns if the mergiraf binary is not on PATH
```

Fresh system → `dotter deploy` → one prompt → configured.

## Phases

Each phase is an independently PR-shaped unit.

### Phase 0 — golden config test corpus

**Verified: dotter has no `tests/` directory and 19 unit tests total.** `--dry-run` only
bumps verbosity (`args.rs:123`); there is no validate-only path.

A `validate` subcommand risks rejection as redundant with `--dry-run`. A **golden-file
config test corpus** — parse fixture configs, assert the merged output — is pure
addition, zero risk to existing behaviour, and is the backwards-compatibility proof every
later phase depends on. Maintainers merge test PRs.

Secondary probe: cherry-pick `Juemuren/dotter`'s watch debounce (+21/-3, `src/watch.rs`
only), which closes open issue **#196** (watch + post-deploy hook infinite recursion).
Not our code, near-zero cost, and it measures the single most important unknown: does the
maintainer merge a small obviously-correct fix, and how fast?

### Phase 1 — multi-target

`FileTarget::Many`, cache versioning + migration, the two semantics above. Closes **#186**.
Port the real dotfiles to it — that is the demo.

### Phase 2 — `dotter merge` + `dotter setup-git`

Implements **#193**. On `TemplateComparison::Changed`, emit the 3-way (base =
`.dotter/cache/`, ours = live target, theirs = fresh render) and shell out to `merge.tool`.
~120 lines, two separate PRs. SuperCuber said in #51 he is *"open to implementing this as
a flag"*.

### Phase 3 — declared machines + branch classification

The research. Build in the fork, prove on real dotfiles, **do not PR until demoed**.
Closes **#51**, which the maintainer personally gave up on — which is exactly why a
working demo is worth more than a design doc.

### Phase 4 — demo repo

Real dotfiles, four machines, showing: one source → multiple per-machine targets; an app
rewriting its own config; the edit landing in the correct template branch; rerere making
it silent the second time.

## Upstreaming strategy

Maintainer record (GitHub API, 2026-08): small obviously-correct PRs merge same-day
(#213 same day, #208 in 5 days). **Feature PRs are 0 for 5** — #190 untouched for 15
months, #214/#216 zero comments. Stated position: *"mostly feature-complete... not
interested in transferring maintenance."*

So: fork first, get users, demo it. That converts the ask from "review my 600-line diff"
to "your users are already running this" — the only lever that works on this maintainer.

**Branch hygiene:** design docs and exploratory work live on `viktorashi`. Each upstream
PR is cut on a **clean branch off `origin/master`**, containing only the code for that one
phase — no `docs/`, no design notes, squashed.
