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

That yields a classification with **zero template introspection** — no handlebars AST, no
provenance instrumentation.

### The classification *is* a three-way merge (verified)

Comparing renders line-by-line and maintaining a line-range map is more machinery than
needed. The question "is this edit generic or machine-specific?" is already answered
exactly by a 3-way merge we can run with tools we depend on anyway.

For an edit observed on machine `M`, and for each other declared machine `K`:

```
base   = render(M)          # what M looked like before the app touched it == .dotter/cache/
ours   = render(K)          # what K currently renders to
theirs = live file on M     # base + the app's edit
```

- **merges cleanly** → the edited region is identical across M and K → the edit is
  **generic**
- **conflicts** → K diverges from M in that region → the edit is **M-specific**

That is precisely `git merge-file` semantics: a conflict arises iff *ours* also changed
relative to *base* in the same region — which is the definition of "this region is
machine-divergent".

No line-range map, no new parser, no template introspection. `N-1` invocations of a
binary already in the design.

Verified empirically (`git merge-file --diff3`):

| edit on `arch` | result | classification |
|---|---|---|
| `theme = dark` → `light` (identical on both renders) | exit 0, clean | generic ✓ |
| `pkg = pacman` → `yay` (differs: rhel has `dnf`) | exit 1, conflict | machine-specific ✓ |
| adds `font = mono`, not adjacent to a divergent line | exit 0, clean | generic ✓ |

Note the third row: this is exactly the case a provenance lookup **cannot** answer, since
a newly added line has no provenance to look up. Merge handles it because it classifies by
*position relative to divergence*, not by lookup.

### Known failure mode: adjacency

An addition placed **immediately adjacent** to a machine-divergent line produces a false
conflict — the diff hunk swallows both:

```
base(arch)   ...  pkg = pacman
ours(rhel)   ...  pkg = dnf
theirs(live) ...  pkg = pacman
                  font = mono     ← generic addition, but at EOF next to divergent pkg
→ CONFLICT (false "machine-specific")
```

**mergiraf does not rescue this case.** Verified: with `.toml` extensions and both with and
without a `[section]` header, mergiraf 0.18.0 produced the same conflict. It *does*
commutatively merge genuinely independent additions on both sides (verified: two new keys
added to the same `[section]` merged cleanly), but the adjacency shape above defeats it.

This is acceptable because **the failure direction is safe**: it over-reports
machine-specific, which routes to the human. It never silently files a machine-specific
edit into the generic body. Misclassification costs a prompt, not a wrong write.

### Cascade

Whatever conflicts remain go, in order, to: **mergiraf → rerere → human**. This ordering
is what git does natively once both are registered — the merge driver runs first, rerere
then replays any recorded resolution, and the remainder surfaces to you. Nothing to build.

### Rejected alternative: in-band provenance comments

Annotating the rendered output with comments saying which branch each region came from
is **self-defeating**. The apps in scope are exactly the ones that rewrite their own
config, and any app that does deserialize → mutate → serialize with a standard library
(`serde`, Go `encoding/json`, `gopkg.in/yaml`) **drops comments by construction**. The
annotation is destroyed by precisely the event it exists to survive. Strict JSON has no
comments at all. (VSCode is a counterexample — it edits jsonc in place and preserves
comments — but it is the minority.)

### Accepted, but insufficient: a sidecar provenance file

A sidecar recording *"this output came from template T, machine M, template hash H"*
survives app rewrites and is cheap. It makes the merge base bulletproof and distinguishes
*template changed* from *target changed*. Since `.dotter/cache/` already stores the render,
this is roughly "add a template hash", ~5 lines. Worth doing.

It does **not** solve classification. Provenance maps *existing* output lines back to
template nodes. An app that adds a **new** setting produces a line with no provenance to
look up — and that is the common case. Render-diff handles it because it classifies by
*position*, not by lookup.

### Why write-back stays manual in v1

Render-diff is not exact either. It misclassifies when two branches render identical text:

```hbs
{{#if linux}}editor = vim{{else}}editor = vim{{/if}}
```

Identical across variants → classified "generic" → but there is no generic body to write
into. Ambiguous.

Neither mechanism is sound enough to justify automatic write-back into a template. So v1
does not attempt it:

> Merge on the **rendered output** (safe and exact: base = `.dotter/cache/`, ours = live
> target, theirs = fresh render). Then *show* the classification as a **hint** — "this
> edit merges cleanly against every other machine's render → likely generic; this one
> conflicts against `work-rhel` → likely machine-specific" — and open the template
> annotated with it. The human presses the button.

No template inversion, no invertibility risk, roughly a third of the code. Automatic
write-back is **Phase 3b**, gated on the hint proving reliable in practice.

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

Bare-system seamlessness is a hard requirement: a fresh Arch install has neither `git`
nor `mergiraf`.

### What is already available

- **`curl` is guaranteed on bare Arch** — verified against the Arch package API:
  `base` depends on `pacman`, and `pacman` hard-depends on `curl` (the binary package,
  not just `libcurl`). So `curl ... | sh` is a safe entry point.
- **`git` is NOT** — verified: absent from `base`'s dependency list.

### Prebuilt binaries make this mostly trivial

Both dotter and mergiraf ship static release binaries:

| | targets | download | on disk |
|---|---|---|---|
| dotter | linux-x64-musl, linux-arm64-musl, macos-arm64, windows-x64-msvc | 3–5 MB | 3–5 MB |
| mergiraf | linux x64/arm64 gnu+musl, macos x64/arm64, windows x64 | 6.4–7.1 MB | **71 MB** |

> The mergiraf tarball is ~6.7 MB but **extracts to 71 MB** (measured, v0.18.0
> x86_64-unknown-linux-gnu) — ~30 bundled tree-sitter grammars. That is 15× dotter's own
> binary, and is the concrete reason it stays an *optional* fetch with `--no-mergiraf`,
> and the reason it is depended on as a **binary rather than a crate**.

So **mergiraf is fetched exactly like dotter's own binary** — no package manager, works on
a bare system. It is also packaged in arch `extra`, homebrew, chocolatey, nixpkgs, alpine,
opensuse TW, macports, gentoo, guix and openbsd, but **not** in debian/ubuntu/fedora —
which is why direct binary download is the reliable path rather than PM delegation.
Prefer the system package when present (it is shared and already on disk); fall back to
the tarball.

### The one genuine system dependency: git

There is no portable static git. The installer therefore needs a narrow `ensure_git` step
shelling out to the native package manager — `pacman` / `apt` / `dnf` / `zypper` / `apk` /
`brew` / `winget`. One package, named literally `git` in every one of them: ~15 lines of
`case`. Needs root; use `sudo` when not already root, and fail loudly with the exact
command when neither is possible.

This is **not** the package-manager-abstraction tarpit rejected below — that concerns
installing the user's arbitrary application list.

### Installer flow

Implemented: [`bootstrap/install.sh`](../bootstrap/install.sh) (POSIX sh — verified
against `dash` and `bash`) and [`bootstrap/install.ps1`](../bootstrap/install.ps1)
(PowerShell 5.1+, ships with Win10/11).

```
detect os/arch
  → ensure git          (native PM — the ONLY package-manager use)
  → install dotter      (static binary download)
  → install mergiraf    (system package first, binary download second,
                         cargo third, skip fourth — never fatal)
  → git clone <repo>
  → dotter init-machine (fzf-style picker, below)
  → dotter setup-git    (rerere + merge driver + .gitattributes)
  → dotter deploy
```

**The entry point is self-proving:** if you can run `curl … | sh`, you have curl and a
shell. Nothing else is assumed.

Target UX:

```sh
curl -fsSL <host>/install.sh | sh -s viktorashi           # → github.com/viktorashi/dotfiles
curl -fsSL <host>/install.sh | sh -s viktorashi/my-config
curl -fsSL <host>/install.sh | sh -s git@host:me/dots.git
```

```powershell
& ([scriptblock]::Create((irm <host>/install.ps1))) viktorashi
```

Verified end-to-end on Ubuntu 26.04 x86_64: platform detection, asset-name mapping,
remote resolution for all four argument shapes, real download of `dotter` 0.13.5 and
`mergiraf` 0.18.0 into a sandbox prefix, and the graceful-degradation path when the
mergiraf download fails.

#### Codeberg is unreliable; plan for it

mergiraf's only binary source is codeberg, and its release downloads fail often —
observed `HTTP/2 stream CANCEL (err 8)` and truncated HTTP/1.1 bodies on repeated
attempts within minutes. There is **no GitHub release mirror** (`qundao/mirror-mergiraf`
mirrors source only, no release assets).

Mitigations, in the script:

1. **System package first** — arch `extra`, alpine, homebrew, opensuse, nixpkgs, gentoo,
   chocolatey. Shared, updated, and avoids codeberg entirely.
2. `--retry 5 --retry-delay 2 --retry-all-errors -C -` (resume, not restart). Verified:
   the download that failed three times in a row succeeded with these flags.
3. `cargo install mergiraf` if cargo is present.
4. Warn and continue. mergiraf is optional by design.

Not in debian/ubuntu/fedora/scoop; **is** in chocolatey (verified).

### `dotter init-machine` — the machine picker

Answers "on a brand-new machine, which existing config do I fork from?" without
hand-editing TOML.

1. **Probe** hostname, OS, and distro — `/etc/os-release` `ID`/`VERSION_ID` on Linux,
   `sw_vers` on macOS, build number on Windows.
2. **Read** `[settings.machines]` from the freshly cloned `global.toml`.
3. **Rank** candidates by similarity to the probe (same os+distro first), preselecting the
   best match.
4. **Present** an fzf-style filter-as-you-type list, plus a "blank profile" entry:

```
? which machine should this one inherit from?  (type to filter)
> arch-laptop    linux/arch      ← best match for this machine (linux/arch)
  desktop        linux/arch
  work-rhel      linux/rhel
  win-work       windows/10
  ─────────────
  (blank profile)
```

5. **Write** the choice:
   - `.dotter/local.toml` ← `packages` from the chosen machine *(untracked, per-machine)*
   - `[settings.machines.<hostname>] inherits = "<chosen>"` appended to `global.toml`
     *(tracked — this is the "fork")*
6. **Print** `review and commit .dotter/global.toml`.

So a new machine is: run the installer, pick from a list, commit one line.

**Implementation: `inquire`.** Its default features are
`["macros", "crossterm", "one-liners", "fuzzy"]` and it requires `crossterm ^0.29.0` —
which dotter **already pins at 0.29.0**. So `inquire = "0.9"` gives fuzzy filtering while
reusing the existing terminal backend, with no feature fiddling and no second terminal
stack. `dialoguer` was rejected: it hard-depends on `console`, an entire parallel
terminal library.

### `dotter doctor`

Precedent: `chezmoi doctor` ("Check for potential problems"). No dotter issue requests it,
so the design space is uncontested.

Reports: git version, mergiraf presence and version, `rerere.enabled`, merge driver
registered, `merge.conflictStyle`, detected machine, cache validity.

**mergiraf is an optional dependency, but a loud one.** Dotter degrades to plain
`git merge-file` without it. It is advertised in three places: `doctor`, the post-install
summary, and — most importantly — at the moment of pain, when `TemplateComparison::Changed`
fires and mergiraf is absent, printing the exact install command for the detected OS.

If upstream later wants it first-class, that is the maintainer's call to make once the
value is demonstrated.

### Explicitly out of scope

- **Package-manager abstraction for arbitrary applications** (scoop/yay/brew/cargo
  install lists). Known tarpit, and dotter already has the right extension point:
  `pre_deploy` hooks. "Install my packages" is a user hook script.
- **Reimplementing rerere or a merge driver inside dotter.**

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

### Phase 1b — `dotter init-machine` + bootstrap scripts

`inquire`-based machine picker, plus the two installer scripts (already drafted in
`bootstrap/`). Depends on declared machines existing, but not on classification, so it can
land before Phase 3.

**Stays in the fork, not upstreamed.** The bootstrap scripts assume `settings.machines`
and `dotter setup-git`, neither of which exists upstream; and a `curl | sh` installer is a
project-identity decision that belongs to the maintainer, not a contributor.

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
