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
├── windows/scoop-config.json
└── arch/pacman.conf
```

## The four cases, and which tool handles each

| Case | Example | Handled by |
|---|---|---|
| Same content, same path everywhere | `.zshrc` | plain `target` in `global.toml`, no OS logic |
| Same content, different real path per OS | nvim config | canonical `target` in `global.toml` + one row in `hooks/link.sh`'s table |
| Only makes sense on one OS | `scoop-config.json`, `pacman.conf` | Dotter's own `if = "dotter.windows"` / `"dotter.linux"` |
| Outside `$HOME` | `/etc/pacman.conf` | just a `target`, plus `owner = "root"` |

`hooks/link.sh` is deliberately **data, not code**: one `table` variable, one
row per cross-platform link. Deploy and undeploy read the same table, so you
never hand-write matching create/remove pairs — add a link once, both
directions follow automatically.

`post_deploy.bat`/`pre_undeploy.bat` do not reimplement anything: they are
one-line launchers for the real logic in `hooks/link.sh`, using the `sh`
already required by this machine's setup (see `~/docs` MSYS2 requirement).
This avoids maintaining Windows and POSIX versions of the same script.

## Usage

```sh
cd .dotfiles
dotter deploy      # writes .zshrc, ~/.dotfiles-deployed/nvim, OS-gated files,
                    # then post_deploy hook creates the nvim symlink/junction
dotter undeploy     # pre_undeploy hook removes the nvim symlink/junction first,
                    # then Dotter removes everything it tracked in cache.toml
```

## Affordances / things to know before relying on this

- **Dotter's cache never learns about the hook-created link.** `undeploy`
  only removes what's in `.dotter/cache.toml` (Dotter-managed symlinks and
  templates). The nvim symlink/junction is *only* removed because
  `pre_undeploy` calls `hooks/link.sh undeploy` — if you ever bypass the
  hook (delete it, rename it, `dotter undeploy` from a checkout that lacks
  it), the link is orphaned and you clean it up by hand.
- **Adding a new cross-platform link** = one new row in `hooks/link.sh`'s
  `table`, plus a plain canonical `target` entry in `global.toml` (case 2 in
  the table above). No new hook code, no new `if` conditions.
- **Adding a new OS-exclusive file** = case 3: just an `if` field in
  `global.toml`. Don't add it to `hooks/link.sh` — that file is only for
  "same content, different location", not "exists on one OS only".
- **`$VAR` vs `%VAR%`**: Dotter's own target-path expansion
  (`shellexpand::full`, used for `~` and `$VAR`) only understands POSIX
  `$VAR`/`${VAR}` syntax, even for Windows targets — hence
  `$USERPROFILE`, not `%USERPROFILE%`, in `global.toml`. `hooks/link.sh`
  runs under `sh`, so it uses the same `$VAR` syntax throughout, including
  for `$LOCALAPPDATA` on the Windows side of its own table.
- **Windows symlink permission is sidestepped**, not solved: the hook uses
  `mklink /J` (directory junction), which needs no Developer Mode / admin
  privilege, unlike Dotter's own symlink deployment for other files.
