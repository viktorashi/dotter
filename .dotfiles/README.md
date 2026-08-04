# Example: OS-agnostic global.toml + declarative post-deploy links

This is a runnable demo answering "how do I keep one dotfiles repo where
Dotter picks the right target on Windows/Linux/macOS with no per-machine
`local.toml`". Layout:

```
.dotfiles/
├── .dotter/
│   ├── global.toml        # what to deploy, and where — see the 4 strategies inside
│   ├── local.toml         # identical on every machine: just enables the one package
│   ├── post_deploy.sh     # 1-liner: calls hooks/link.sh deploy   (unix)
│   ├── post_deploy.bat    # 1-liner: calls hooks/link.sh deploy   (windows, via MSYS2 sh)
│   ├── pre_undeploy.sh    # 1-liner: calls hooks/link.sh undeploy (unix)
│   ├── pre_undeploy.bat   # 1-liner: calls hooks/link.sh undeploy (windows)
│   └── hooks/
│       └── link.sh        # the ONLY file that knows canonical-path -> real-OS-path
├── zsh/zshrc
├── nvim/init.vim
├── vscode/settings.json
├── windows/scoop-config.json
└── arch/pacman.conf
```

## The four cases, and which tool handles each

| Case | Example | Handled by |
|---|---|---|
| Same content, same path everywhere | `.zshrc` | plain `target` in `global.toml`, no OS logic |
| Same content, different real path per OS | nvim config (dir), VSCode `settings.json` (file) | canonical `target` in `global.toml` + one row in `hooks/link.sh`'s table |
| Only makes sense on one OS | `scoop-config.json`, `pacman.conf` | Dotter's own `if = "dotter.windows"` / `"dotter.linux"` |
| Outside `$HOME` | `/etc/pacman.conf` | just a `target`, plus `owner = "root"` |

`hooks/link.sh` is deliberately **data, not code**: one `table` variable, one
row per cross-platform link. Deploy and undeploy read the same table, so you
never hand-write matching create/remove pairs — add a link once, both
directions follow automatically. Each row also has a `kind` (`dir`/`file`)
column: Windows junctions (`mklink /J`) only work on directories, so files
(like `settings.json`) use `mklink /H` (hardlink) instead — both need no
admin/Developer Mode, unlike a real Windows symlink.

`post_deploy.bat`/`pre_undeploy.bat` do not reimplement anything: they are
one-line launchers for the real logic in `hooks/link.sh`, using the `sh`
already required by this machine's setup (see `~/docs` MSYS2 requirement).
This avoids maintaining Windows and POSIX versions of the same script.

## Usage

```sh
cd .dotfiles
dotter deploy      # writes .zshrc, ~/.dotfiles-deployed/{nvim,vscode}, OS-gated
                    # files, then post_deploy hook creates the real-path links
dotter undeploy     # pre_undeploy hook removes those links first,
                     # then Dotter removes everything it tracked in cache.toml
```

## Affordances / things to know before relying on this

- **Dotter's cache never learns about hook-created links.** `undeploy` only
  removes what's in `.dotter/cache.toml` (Dotter-managed symlinks and
  templates). The nvim/vscode links are *only* removed because
  `pre_undeploy` calls `hooks/link.sh undeploy` — if you ever bypass the
  hook (delete it, rename it, `dotter undeploy` from a checkout that lacks
  it), the link is orphaned and you clean it up by hand.
- **Adding a new cross-platform link** = one new row in `hooks/link.sh`'s
  `table`, plus a plain canonical `target` entry in `global.toml` (case 2 in
  the table above). No new hook code, no new `if` conditions.
- **Adding a new OS-exclusive file** = case 3: just an `if` field in
  `global.toml`. Don't add it to `hooks/link.sh` — that file is only for
  "same content, different location", not "exists on one OS only".
- **Never put an OS-specific env var (`$USERPROFILE`, `$APPDATA`,
  `$LOCALAPPDATA`, ...) directly in a `global.toml` `target`.** Dotter's own
  `shellexpand::full` (`config.rs:186-198`) expands `~`/`$VAR` for *every*
  file unconditionally, at config-parse time, *before* the `if` filter runs
  (`handlebars_helpers.rs` runs strictly after `config::load_configuration`)
  — so an env var missing on the current OS hard-crashes config loading even
  if `if` would've dropped that file anyway. `~` is the one safe exception:
  shellexpand resolves it to the home dir on every OS via a real API call,
  not by reading an OS-specific var name, so it never fails regardless of
  which OS is actually running.
- **Special folders that can be redirected (`%APPDATA%`, GPO Folder
  Redirection, OneDrive Known Folder Move) must NOT be reconstructed as
  `~/AppData/Roaming/...` in `global.toml` either** — that bakes in the
  *default* location and silently diverges from wherever IT actually pointed
  it. Keep the `global.toml` target fully generic (`~/.dotfiles-deployed/...`)
  and let `hooks/link.sh` resolve `$APPDATA` live, at hook-run time, on the
  real machine — `eval echo "$var"` there reads the actual process
  environment, so redirection is respected instead of guessed at.
- **WSL and native Windows are different `dotter` binaries.** `dotter.windows`
  is `cfg!(target_os = "windows")` — compiled in, not detected at runtime. A
  WSL-compiled `dotter` always has `dotter.windows = false` (it's Linux from
  the binary's point of view) and cannot reach native Windows special
  folders through `~`. If you use the same physical machine both ways, you
  deploy twice: once with the native `dotter.exe` for Windows-only entries,
  once with WSL's `dotter` for Unix-only entries. Nothing here reconciles
  that automatically — it's a deliberate two-binary, two-environment
  situation, not something to paper over with `~`/env-var tricks.
- **Windows link permission is sidestepped, not solved**: the hook uses
  `mklink /J` (dir) / `mklink /H` (file), both privilege-free, unlike
  Dotter's own symlink deployment for other files (which needs Developer
  Mode).
