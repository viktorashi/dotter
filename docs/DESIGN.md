# Dotter fork: design

Goal: a dotfile manager where **configs do not drift across machines** — one tree, every
machine, no per-machine branches — and where an app rewriting its own config in place has
that edit find its way home instead of being lost or clobbered.

Everything here is additive. Existing `global.toml` / `local.toml` must keep working
unchanged.

**Companion files** — read all three before starting work:

| file | contents |
|---|---|
| `AGENTS.md` | project vision, working rules, the upstream maintainer's behaviour |
| `docs/todo.md` | the ordered, gated work items |
| this file | why each decision was made, and what was rejected |

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
  I'm welcoming PRs on this :)"*. **Not our problem** — see *Multi-target: dropped*.

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
| --- | --- | --- |
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
| --- | --- |
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
| --- | --- | --- |
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
write-back is deferred (see `docs/todo.md` Phase 5), gated on the hint proving reliable in practice.

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

## Composition is the whole model

Earlier drafts swung between a machine table with `inherits`, then `[settings.variants]`
axes branched on with `{{#if}}`, then a multi-target array as the primary mechanism. All
were wrong, for the same reason: they invented a schema for something dotter already
does.

One mechanism answers all three questions:

| question | answered by |
|---|---|
| **Which files exist on this machine?** | packages selected in the machine file |
| **Where does this file go here?** | `[files]` override, or a variable in the target (PR #190) |
| **What is in it?** | variables, app-native `include` directives, templating as last resort |

**`[settings.variants]` is dropped** — it existed only to enumerate branch values for
classification, which is now gated on there being any templates at all. If Phase 0a finds
none, it is never needed. If it does, reintroduce it then, scoped to the residual set.

### Composition: what dotter already does

The chain in `merge_configuration_files`:

```
global.toml packages          (must be DISJOINT — duplicate source key is a hard error,
                               config.rs:363)
  → local.includes[0..n]      (ordered override: package_global.files.extend(included),
                               config.rs:298-300)
    → the local config        (see "Machine selection" below)
      → local `[files]`       (final override: output.files.extend, config.rs:409)
```

A machine is one **tracked** file under `.dotter/machines/<name>.toml`, listing the layers
it composes, the packages it enables, and any overrides:

```toml
# .dotter/machines/desktop.toml          — tracked
includes = [".dotter/layers/arch.toml"]
packages = ["core", "gaming"]

# .dotter/machines/laptop.toml           — tracked
includes = [".dotter/layers/arch.toml"]
packages = ["core"]
```

Verified end-to-end against a scratch `HOME`: both machines pick up the shared `arch`
layer; desktop additionally deploys `gaming`; laptop does not.

Drift needs no new mechanism:

| drift | how |
|---|---|
| desktop gains a file laptop must not have | add a package, enable it in `desktop.toml` |
| several machines share a change | put it in a layer they all include |
| WSL needs interop files native Arch must not | a `wsl.toml` layer, included only by the WSL machine |
| a shared file's *contents* differ | a variable, or an app-native `include` directive |

### Machine selection: the `machine` pointer

**Hostname selection is rejected.** A Windows host and its WSL guest report the same
hostname, so `<hostname>.toml` (`config.rs:159-171`) cannot distinguish them. Setting the
WSL hostname via `/etc/wsl.conf` is circular — that file is itself deployed by dotter, so it
requires the config that requires the hostname.

Instead, `local.toml` becomes a **single generated line**, written by the picker, never by
hand:

```toml
# .dotter/local.toml    — gitignored, generated by `dotter init-machine`
machine = "desktop-wsl"
```

`LocalConfig` gains `machine: Option<String>`, resolved by loading
`.dotter/machines/<name>.toml` as the local config and layering anything in `local.toml`
on top. Machine files may not themselves set `machine` (no chaining).

> **Guard against silent failure.** `packages` must be defaulted for a one-line
> `local.toml` to parse — but then a *malformed* local config stops erroring and silently
> deploys nothing. Rule: **exactly one of `machine` or `packages` must be present**; error
> otherwise. A loud failure must not become a quiet one.

### Why this matters beyond ergonomics

Every file deployed by composition without templating is a **symlink** — the target *is*
the repo file, so an app rewriting its own config lands the change in the repo for free.
Verified: appending to a deployed file changed the source.

Reverse-sync, classification, three-way merge and rerere exist **only** for templated files.
So the doctrine is:

> **layer → app-native include → template.** Stop at the first that works.

Duplicating a 200-line file per machine to avoid a template is not composition, it is drift.
Most config formats grew an include directive (`source`, git `[include]`, ssh `Include`,
tmux `source-file`, nvim `require`, kitty `include`) precisely for this. Templating is the
residual set: single-file formats with no include mechanism that still need intra-file
variation.

**This argument has a hard dependency on symlinks actually being available — see
"Windows linking" below, where it currently fails.**

## Multi-target: dropped

**Superseded by a clarified requirement.** Earlier drafts treated "one source, many
targets" as the founding need, on the strength of the original complaint that destinations
should be declared together rather than scattered.

The clarification that kills it:

> *"I'm not gonna link the same files in multiple places on the same machine. Just in
> different places on different machines."*

Simultaneous multi-target — one source deployed to two locations **at once, on one
machine** — is #186's case (`pwsh` → both `Documents\PowerShell` and
`Documents\WindowsPowerShell`). It is not a requirement here and never was.

What is actually needed is *different destinations on different machines*, which is
**exactly one target per machine**. `FileTarget` already expresses that. No schema change,
no `FileTarget::Many`, no `cache.toml` migration, no #186.

### The co-location objection, resolved

The original complaint stands: with composition, a destination lives in a machine file
rather than beside its source. But that is a **transposition**, not a loss — the same
facts, indexed differently:

| indexed by | easy to answer | hard to answer |
|---|---|---|
| **source** (multi-target array) | "where does `nvim` go everywhere?" | "what is different about `win-work`?" |
| **machine** (composition) | "what is different about `win-work`?" | "where does `nvim` go everywhere?" |

Given the vision is *configs must not drift across machines*, the question that matters is
the second one — **what does this machine diverge on** — and a machine file answers it by
construction: every divergence for that machine is in one place, reviewable in one diff.
The by-machine index is the better fit for the actual goal.

### Deferring is free — verified against the actual code

Two realistic same-machine cases were raised, and they are not fake:

- **VSCode + VSCodium** — same settings, two directories, one machine. `settings.json` has
  **no include directive**, so the app cannot compose it. This is a genuine hole.
- **vim + nvim** — weaker: nvim *does* have an include mechanism, and the idiomatic init is
  `set runtimepath^=~/.vim` + `source ~/.vimrc`. That is rung 2 of the ladder, not a
  multi-target need.

Zero-code workaround for the VSCodium shape: a second source path that is a **repo-internal
symlink** to the first.

```toml
"vscode/User"   = "~/.config/Code/User"
"vscodium/User" = "~/.config/VSCodium/User"    # `vscodium` is a symlink to `vscode` in-repo
```

Git tracks symlinks; dotter links the link; it resolves. Caveat: repo-internal symlinks need
`core.symlinks` and Developer Mode on Windows — the same wall as *Windows linking*, so it is
not free there.

**Why it can wait.** `FileTarget` is an untagged serde enum, so a `Many` variant is purely
additive — every config that parses today still parses. Adding it in six months costs
exactly what it costs now. Measured overlap with the planned branches:

| branch | files | collides with multi-target? |
|---|---|---|
| `up/00-tests` | `tests/` | no |
| `up/01-winlink` | `filesystem.rs`, `deploy.rs:67-84` | **yes** — same file-classification loop in `deploy.rs` |
| `up/02-machine` | `config.rs` (`LocalConfig`) | no — different struct from `FileTarget`/`Cache` |

One conflict, in one function, mechanically resolvable. And there is **no shared
`cache.toml` migration** to bundle: multi-target needs one (source → *one* target today),
Windows linking is not expected to. So doing them together saves nothing.

Order matters strategically, not technically: `up/01-winlink` is a bug fix and lands in the
same-day bucket, while multi-target is design-blocked (#186 open since 2024). Stacking a
fast fix behind a slow feature rots both.

**The tell to watch for:** the moment a duplicate source file or a repo-internal symlink is
created *purely to obtain a second target*, write it down. Two or three instances justify
building it. Until then it is one hypothetical.

### Recovering most of the co-location anyway: upstream PR #190

`balthild:master` — *"Expand variables in target paths"*, +106/-13, `src/config.rs` only,
closes #61, **open and unreviewed since 2024-11-06**.

With it, targets can reference variables:

```toml
# global.toml — destination stays next to the source
"nvim"                 = "{{ config_dir }}/nvim"
"vscode/settings.json" = "{{ config_dir }}/Code/User/settings.json"
```

```toml
# .dotter/machines/win-work.toml — one line covers every file above
[variables]
config_dir = "${APPDATA:-/nonexistent}"
```

That collapses N per-file overrides into **one variable per machine**, which is the real
DRY win and most of what co-location was ever worth. See *Cherry-picks* below.

## Windows linking: the fallback that does not exist

**This invalidates the "everything is a symlink" argument on Windows, and it is currently
unaddressed.**

`deploy.rs:67-84`: if `filesystem::symlinks_enabled` returns false, dotter routes **every
file** into `desired_templates` — not just templated ones. All of them become rendered
copies:

```
No permission to create symbolic links.
On Windows, in order to create symbolic links you need to enable Developer Mode.
Proceeding by copying instead of symlinking.
```

Consequences on a Windows box without Developer Mode:

- No file round-trips. An app rewriting its config is a drift event for **100% of files**,
  not the residual templated set.
- The reverse-sync machinery (Phases for `merge` and classification) becomes load-bearing
  for everything, rather than a fallback.
- Corporate machines are exactly where Developer Mode is locked down — i.e. the worst case
  is the work laptop.

### The fix: hard links and junctions

Both are **privilege-free** on Windows, and a hard link shares an inode, so round-trip is
preserved exactly as with a symlink:

| source kind | mechanism | privilege |
|---|---|---|
| file | `CreateHardLink` | none |
| directory | NTFS junction | none |

Rotz already does this (`junction::create` for directories, hard links for files, selected
by `link_type = "hard"`). Dotter has no such path — its only fallback is copying.

Known limits, to be documented rather than hidden:

- Hard links require **same volume**. Repo on `C:` and target on `C:` is the normal case;
  a repo on `D:` targeting `C:` must fall back to copying.
- A hard link is not a symlink: deleting the repo file does not break the target, it just
  decrements the link count. `undeploy` must therefore delete by cache entry, which it
  already does.
- Junctions are directory-only and do not follow across volumes either.

### This is bigger than swapping a syscall — verified

`filesystem::get_file_state` (`filesystem.rs:696`) detects links with `fs::read_link`:

```rust
if let Ok(target) = fs::read_link(path) {
    return Ok(FileState::SymbolicLink(target));
}
```

**A hard link is not a symlink**, so `read_link` fails on one. The target then reads as
`FileState::File(contents)`, and `compare_symlink` (`filesystem.rs:737`) falls through to
its catch-all arm:

```rust
_ => SymlinkComparison::TargetNotSymlink   // "target already exists and isn't a symlink"
```

So dotter would treat **its own hard link** as a foreign file and refuse to touch it. Every
deploy after the first would skip, and `--force` would delete and recreate.

The work therefore includes:

1. A new `FileState` variant (or a `SymlinkComparison` arm) for "target is the same file as
   source".
2. **Same-file detection**, which is platform-split: `st_dev`/`st_ino` via
   `std::os::unix::fs::MetadataExt` on unix; `dwVolumeSerialNumber` + `nFileIndex{High,Low}`
   from `GetFileInformationByHandle` on Windows.
3. `compare_symlink` extended to accept it as `Identical`.
4. Junction detection for directories — a junction *is* a reparse point, so `read_link` may
   succeed on it; verify rather than assume.

Revised size: **~150-200 lines** across `filesystem.rs` and `deploy.rs`, not a small patch.
Still self-contained, still a bug fix, but not an afternoon.

### Cache impact: none expected

`Cache { symlinks, templates }` maps source → target. Undeploying a hard link is the same
operation as undeploying a symlink — delete the target — so no format change is expected.
Confirm this before writing the migration-free assumption into the PR.

### Ordering

This lands **before** any reverse-sync work. If Windows can link, the residual templated set
stays small and Phases 4/5 stay optional. If it cannot, they become mandatory — so the
link fix must be attempted first, or the whole cost estimate downstream is wrong.

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
| --- | --- | --- | --- |
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

### Why two scripts and not one

Two separate questions hide here, and they have different answers.

#### Can one *command* work on both? No — and this is provable

The command has three parts: **fetcher**, **transport**, **interpreter**. Unification fails
on two of the three.

| | bare Linux | bare Windows 10+ |
| --- | --- | --- |
| interpreters | `sh` | `cmd`, `powershell` |
| fetchers | `curl` / `wget` | `curl.exe`, `Invoke-WebRequest` |

**The interpreter intersection is empty.** There is no name that means "execute this
script" on both a bare Linux and a bare Windows box. Since the interpreter is the thing
after the pipe, and the pipe is typed by the user, no single copy-pasteable string exists.

The fetcher does not save it either: Windows 10 1803+ does ship `curl.exe`, but in
PowerShell 5.1 `curl` is an **alias for `Invoke-WebRequest`**, which rejects `-fsSL`. You
must write `curl.exe` — which does not exist on Linux.

**A polyglot script file does not help.** Even a file that is simultaneously valid `sh` and
valid PowerShell still has to be *invoked*, and the invocation (`| sh` vs `| iex`, or
`sh f` vs `./f`) is the part that differs. The polyglot solves the half of the problem that
was never the problem.

#### Can one *URL* work on both? Yes

This is the real ask — "I shouldn't have to know which command to run" is mostly "I
shouldn't have to find a different link". UA routing handles it, because the clients are
trivially distinguishable:

```
curl        →  curl/8.18.0
PowerShell  →  Mozilla/5.0 (Windows NT 10.0; ...) WindowsPowerShell/5.1.x
PowerShell7 →  Mozilla/5.0 (Windows NT 10.0; ...) PowerShell/7.4.x
```

Implemented in [`bootstrap/router.js`](../bootstrap/router.js) — a Cloudflare Worker, with
an nginx `map` equivalent in the trailing comment. An explicit `.sh`/`.ps1` suffix always
overrides the sniff, so the scripts stay directly addressable for CI and for anyone who
distrusts UA sniffing. Routing verified against 8 real user-agent strings, including both
PowerShell generations, `Microsoft-CryptoAPI`, empty UA, and explicit-suffix override.

Result — same URL, and the commands differ only in the unavoidable wrapper:

```sh
curl -fsSL https://dott.er/i | sh -s viktorashi     # Linux / macOS
```

```powershell
irm https://dott.er/i | iex                          # Windows
```

#### Where the remaining difference actually goes: the docs page

The user should never *see* both. Detect the OS in JavaScript on the install page and
render only the relevant snippet — which is what bun, deno and rustup all do. Then the
experience is genuinely "copy the one command on the page", even though two exist.

Nobody ships a polyglot installer: bun uses `curl -fsSL https://bun.com/install` **and**
`powershell -c "irm bun.sh/install.ps1 | iex"`; rustup uses `sh.rustup.rs` plus a separate
`rustup-init.exe`; starship, deno, uv and homebrew all have two entry points. That is
strong evidence the second file is not the part worth optimising away.

Answers "on a brand-new machine, which config am I?" without hand-editing anything.

1. **Probe** OS and distro — `/etc/os-release` `ID`/`VERSION_ID` on Linux, `sw_vers` on
   macOS, build number on Windows. Hostname is *not* used for selection (it collides
   between a Windows host and its WSL guest); it is only a ranking hint.
2. **List** `.dotter/machines/*.toml` — the tracked machine entities.
3. **Rank** by similarity to the probe, preselecting the best match.
4. **Present** one fzf-style filter-as-you-type list:

```
? which machine is this?  (type to filter)
> desktop         core, gaming        ← best match (linux/arch)
  laptop          core
  desktop-wsl     core, wsl-interop
  win-work        core, windows
  ──────────────
  (create a new machine)
```

5. **Write one generated line** to gitignored `.dotter/local.toml`:

```toml
machine = "desktop"
```

   Nothing is hand-written, and tracked config is untouched — a new machine needs no commit
   unless it is genuinely a *new* machine.
6. **"create a new machine"** writes `.dotter/machines/<name>.toml` too — a tracked change,
   and the correct moment for one, because a new entity now exists. Offer to seed it from
   an existing machine's `includes`/`packages`.

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

## Cherry-picks from forks and open PRs

Audited via the GitHub API, 2026-08. Of dotter's **75 forks, 7 are ahead of upstream**; of
rotz's 13, 2 are. Sizes and touched files are measured, not estimated.

### Take

| what | source | size | why |
|---|---|---|---|
| **Watch debounce** | `Juemuren/dotter` — *"Add debounce to prevent infinite loops when watch"* | **+21/-3**, `src/watch.rs` | Closes open issue **#196** (watch + post-deploy hook infinitely recurses). Not our code, near-zero risk. Doubles as the probe PR that measures the maintainer's response time. |
| **Variables in target paths** | upstream PR **#190** (`balthild:master`), open since 2024-11-06, zero reviews | **+106/-13**, `src/config.rs` | Closes #61. Collapses N per-file destination overrides into one variable per machine — recovers most of the co-location the multi-target array was going to provide. Cherry-pick into the fork; do **not** re-open it upstream, that duplicates a PR already rotting. |
| **Recursing for template targets** | `faffeldt/dotter` — *"Allow recursing for template target"* | **+43/-0**, `src/config.rs` | Templated directories currently cannot recurse the way symlinked ones do. Only matters if Phase 0a finds a non-zero residual templated set. |

### Watch, do not take yet

| what | source | size | note |
|---|---|---|---|
| `copy` deployment type with checksum caching | PR **#214** (JP-Ellis), 2026-04 | +1205/-10, 7 files | Overlaps the Windows-linking work: both concern what to do when a symlink is impossible. Hard links are the better answer (round-trip preserved), but the checksum-cache machinery here may be reusable. Read before writing Phase 1. |
| Elevate permissions on directory access | PR **#215** (archnode), 2026-05 | +822/-86, 5 files | Relevant to `/etc` targets with `owner = "root"`. Large; wait and see if it lands upstream. |
| Recursive off by default for symbolic folders | PR **#206** (Faria22), 2025-12 | +59/-2, `src/config.rs` | Behaviour change — would alter deploy semantics under us. Track it. |
| `exclude` function | PR **#216** (haojunyu), 2026-06 | +308/-3, 3 files | Unrelated to this plan, but touches `config.rs` and would conflict with `up/02-machine`. |

### Skip, with reasons

- **`einetuer/dotter`** — feature flags for `scripting`/`watch`. **Already upstream**:
  `Cargo.toml:34-37` has `default = ["scripting", "watch"]`. Redundant.
- **`orhun/dotter`** — Linux ARM build CI, `dtolnay/rust-toolchain`, `cross`. Release
  infrastructure only; upstream already ships `dotter-linux-arm64-musl`. No source value.
- **`jayvicsanantonio/dotter`** — dependabot bumps only.
- **`monomadic/dotty`** — a divergent rename, not a fork to merge from. macOS CI only.
- **rotz `bltavares` (+9)** — his five ignored PRs (clippy, dep bumps, Android binaries,
  `dirs.base.data_local`). Wrong project; the `data_local` one is already implemented at
  `rotz/src/templating/mod.rs:85` despite PR #415 claiming to add it.
- **rotz `kaerum` (+1)** — trivial.

### Ideas taken from other projects, not code

- **rotz** — `junction::create` for privilege-free Windows directory links, and hard links
  for files. The approach, reimplemented; not the code (different codebase, different
  licence surface).
- **`mermonia/peridot`** (Go, 0★) — render to an artifact dir and symlink the artifact, so
  the deployed file stays a link. One idea, no code.

## Upstreaming strategy

Maintainer record (GitHub API, 2026-08): small obviously-correct PRs merge same-day
(#213 same day, #208 in 5 days). **Feature PRs are 0 for 5** — #190 untouched for 15
months, #214/#216 zero comments. Stated position: *"mostly feature-complete... not
interested in transferring maintenance."*

So: fork first, get users, demo it. That converts the ask from "review my 600-line diff"
to "your users are already running this" — the only lever that works on this maintainer.

### Stacked PRs

Work happens on the fork's `viktorashi` branch, which carries `docs/`, `bootstrap/`,
`AGENTS.md` and exploratory commits. **None of that is ever pushed upstream.**

Each upstream PR is cut fresh from `origin/master` and contains exactly one reviewable
unit:

```
origin/master
  ├── up/00-tests     golden config fixtures + watch debounce (#196)   pure addition
  ├── up/01-winlink   hard link + junction fallback                    bug fix
  └── up/02-machine   `machine` pointer field                          small feature
```

All three are cut **independently from `origin/master`** — none depends on another, so they
review and merge in parallel. Everything else stays in the fork.

Rules a fresh implementer must follow:

1. **One concern per PR.** Never mix a refactor with a feature. The maintainer merges
   small, obviously-correct changes same-day and ignores large ones for 15 months —
   optimise for the first bucket.
2. **Cut from `origin/master`, not from the previous PR branch**, unless there is a genuine
   code dependency. Independent PRs review and merge in parallel; a chain blocks on the
   slowest link.
3. **No `docs/`, no `TODO.md`, no `AGENTS.md`, no `bootstrap/`** in any upstream branch.
   Strip them; they are fork identity, not upstream value.
4. **Every PR closes or references an existing issue** where one exists — #196 (watch
   recursion), #193 (merge tool), #51 (reverse sync). An unrequested
   feature is a much harder sell than an answer to a filed request.
5. **Answer the maintainer's stated objection in the PR body.** He names blockers
   explicitly when he has them — on #186 it was two (TOML forbids duplicate keys;
   `target = ""`-disable and local-override semantics must survive). Search the issue for
   his own words and pre-empt them; that reads as considerate, ignoring them reads as work
   for him.
6. **Squash before opening.** One commit, imperative subject, body explaining *why*.
7. **Never break `cache.toml` without a version + migration.** It is generated, so
   migration is cheap and its absence is an instant rejection.
8. **Do not open more than two PRs at once.** A queue reads as a burden; two reads as
   contribution.

### What is fork-only, permanently

- `bootstrap/install.sh`, `install.ps1`, `router.js` — a `curl | sh` installer is a
  project-identity decision belonging to the maintainer, not a contributor.
- `dotter init-machine` — depends on the `machine` field landing first, and on a
  `.dotter/machines/` convention upstream has not adopted.
- `docs/`, `TODO.md`, `AGENTS.md`.

Classification (`docs/todo.md` Phase 5) is deliberately unscheduled for upstreaming: it closes #51, which
the maintainer personally abandoned, and only a working demo will move him.
