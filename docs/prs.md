# Upstream Pull Requests

## Branch: `up/self-overwrite-guard`
It fixes the issue with number 218.

**Description:**
Guards against a data loss bug where a whole-directory symlink (`recurse = false`) combined with a template entry for a file inside that directory causes dotter to resolve the target back to its own source. With `--force`, this deletes the source file and then fails reading it. This PR adds a `check_not_self` guard in `src/actions.rs` using the `same-file` crate to refuse deployment when the source and target are the same physical file, preventing data loss.

## Branch: `up/watch-filter`
It fixes the issue with number 196.

**Description:**
Fixes an infinite recursion loop in `dotter watch`. The root cause was that `!`-prefixed globs (intended as excludes) were being passed as the `filters` argument instead of `ignores` to `GlobsetFilterer::new`. The `watchexec-filterer-globset` parses `!` as a gitignore negation (whitelist). This meant zero excludes were registered, and file writes to `.dotter/cache/` continuously retriggered the watcher. The fix moves the globs to the `ignores` argument without the `!` prefix, establishing them correctly as exclusion rules.

## Branch: `up/template-detection`
*(You need to create an issue for this: "Asymmetry in template detection logging / Silent false positives on files with `{{`")*

**Description:**
Fixes a silent failure/asymmetry when detecting templates. Currently, in `filesystem.rs`, if a file is not UTF-8, it logs a warning and explains how to skip the file using `type = "symbolic"`. However, if the file is valid UTF-8 and contains `{{` (e.g., standard code or config like `yazi` theme), it silently treats it as a template. If the file is not valid Handlebars, dotter crashes during deployment on a line the user didn't write as a template. This PR adds a symmetric `warn!` for the `{{` detection branch, reusing the maintainer's existing wording, and suggests using `.tmpl` or `type = "symbolic"` to silence it. 

## Branch: `up/windows-link-fallback`

<!-- TODO: when im back at a windows machine actually check this and build n shit see if it works, cuz otherwise it's waste of everyones time  -->
*(You need to create an issue for this: "Feature: Support hard links and junctions on Windows when symlinks are unavailable")*

**Description:**
Improves the fallback behavior on Windows. Currently, if Developer Mode is off (e.g., corporate laptops), `symlinks_enabled` returns false, and dotter falls back to copying 100% of files. This breaks round-tripping for live edits. This PR changes the fallback to use NTFS junctions for directories and hard links for files, both of which are privilege-free on Windows and preserve round-tripping. It handles `same-file` detection across hard links (which fail `read_link`) so they aren't treated as foreign files. Note: This is foundational for keeping the required reverse-sync/template surface area small on Windows.

## Branch: `up/dotter-toml`
It addresses the issue with number 51 (as mentioned by the maintainer).

**Description:**
Adds a `dotter.toml` settings file, as proposed by the maintainer in 2021. This separates *how the tool runs* (e.g., `force`, `noconfirm`, `verbosity`, `diff_context_lines`) from *how files are deployed* (which stays in `global.toml`'s `[settings]`). It respects git's precedence order: compiled defaults < `~/.config/dotter/dotter.toml` < `<repo>/dotter.toml` < CLI flags. This is highly useful for defining repo-specific defaults and avoiding long aliases.

## Branch: `up/machine-field`
*(You need to create an issue for this: "Machines as a first-class concept to eliminate hand-edited untracked local.toml")*
*(This can be stacked on top of `up/dotter-toml` or developed independently, but let's keep it independent initially to follow the one-concern-per-PR rule)*

**Description:**
Introduces `LocalConfig.machine: Option<String>` which resolves to a `.dotter/machines/<name>.toml` file. Currently, users have to maintain untracked, hand-edited `local.toml` files that often drift. By defining a machine concept, users can declare `packages` and `variables` in tracked files and just point to them. This PR guards that exactly one of `machine` or `packages` must be present.
