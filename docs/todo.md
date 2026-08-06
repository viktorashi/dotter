## Phases

Each phase is an independently PR-shaped unit.

### Phase 0a — port the dotfiles with composition only, zero templates

Before any code: express all machines as `<hostname>.toml` + shared layers, using only
what ships today. Then measure how many files actually need *intra-file* variation that no
app-native include can absorb.

That number decides whether Phases 2 and 3 are worth building at all. If it is zero, the
reverse-sync machinery has no users and should not exist.

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

`inquire`-based variant picker, plus the two installer scripts (already drafted in
`bootstrap/`). Depends on declared variants existing, but not on classification, so it can
land before Phase 3.

**Stays in the fork, not upstreamed.** The bootstrap scripts assume `settings.variants`
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
