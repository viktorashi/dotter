# Dotter fork: design

Goal: a dotfile manager where (a) one source can declare **all** its destinations in one
place, next to that source, and (b) when an app rewrites its own config in place, that edit
finds its way home instead of being lost or clobbered.

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

## Two orthogonal mechanisms (they do not compete)

Earlier drafts here swung between a machine table with `inherits`, then
`[settings.variants]` axes branched on with `{{#if}}`, then composition-replaces-everything.
All three were confused, because they conflated two genuinely separate questions:

| question | mechanism | notes |
|---|---|---|
| **Where does this file go?** | **multi-target** (below) | co-located with the source, per the founding requirement |
| **Which files exist here, and what is in them?** | **composition** — packages, includes, machine files | dotter already implements this |

They are complementary. Multi-target answers *destination*; composition answers *existence*
and *content*. Neither subsumes the other, and the founding complaint — "I want to define
where the files go in some file, for each file" — is answered only by multi-target.
Expressing destinations as per-machine overrides scattered across machine files is exactly
the split that was rejected as ugly at the outset.

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

## Multi-target

**This is the founding requirement.** The original problem statement was: *"I want to
define where the files go in some file (probably TOML) for each file"* — all destinations
for a source, co-located with that source. Nothing else in this document replaces it.

`FileTarget` is already an untagged serde enum (`config.rs:48-55`), so adding a variant is
**fully backwards compatible** — every config that parses today still parses.

```toml
"nvim" = [
  { target = "~/.config/nvim",                     if = "(eq distro \"arch\")" },
  { target = "${LOCALAPPDATA:-/nonexistent}/nvim", if = "dotter.windows" },
]
```

One feature, two jobs, decided by how many conditions hold:

- **exactly one true** → a per-machine destination. This is the `nvim` / `vscode` case, and
  the reason this project exists.
- **more than one true** → genuinely simultaneous targets. This is #186's actual case
  (`pwsh` → both `Documents\PowerShell` and `Documents\WindowsPowerShell`).

Both fall out of the same implementation; neither needs special handling.

> **The upstream expansion-before-`if` bug bites here.** `shellexpand::full` runs over every
> target at `config.rs:186-198`, *before* `filter_files_condition` (`handlebars_helpers.rs:27`,
> reached from `deploy.rs:42`). So `${LOCALAPPDATA}` in a Windows-only entry crashes config
> loading on Linux even though the `if` would have dropped it. Verified. Until that is fixed
> upstream, **every env var in a target must carry a `:-fallback`** — `${LOCALAPPDATA:-/nonexistent}`.
> The default suppresses the lookup error (verified in `shellexpand-2.1.2/src/lib.rs:452-492`;
> the split token is `:-`, not `:`).

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

### Ordering

This lands **before** any reverse-sync work. If Windows can link, the residual templated set
stays small and Phases 2/3 stay optional. If it cannot, they become mandatory — so the
cheap fix must be attempted first, or the whole cost estimate downstream is wrong.

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
  └── up/00-tests          golden config fixtures            (pure addition, zero risk)
       └── up/01-winlink   hard link + junction fallback     (bug fix, self-contained)
            └── up/02-multitarget   FileTarget::Many + cache v1 migration
                 └── up/03-machine  `machine` pointer field  (depends on nothing above)
```

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
   recursion), #186 (multi-target), #193 (merge tool), #51 (reverse sync). An unrequested
   feature is a much harder sell than an answer to a filed request.
5. **Answer the maintainer's stated objection in the PR body.** For #186 he named two
   blockers (TOML forbids duplicate keys; `target = ""`-disable and local-override
   semantics must keep working). A PR that pre-empts both reads as considerate; one that
   ignores them reads as work for him.
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
