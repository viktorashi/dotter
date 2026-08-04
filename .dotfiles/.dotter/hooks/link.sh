#!/bin/sh
# hooks/link.sh — the ONE place that knows "canonical path -> real OS path".
#
# Everything here is a lookup in `table`, not imperative branching per-file:
# adding a new cross-platform link is a new line, not new code. deploy and
# undeploy read the exact same table, so removal can never drift from
# creation (that's the whole point of keeping this declarative).
#
# Called by:
#   .dotter/post_deploy.sh / .dotter/post_deploy.bat   -> "$0" deploy
#   .dotter/pre_undeploy.sh / .dotter/pre_undeploy.bat -> "$0" undeploy
#
# Columns:  name  kind  canonical-source (relative to dotfiles repo root)  unix-target  windows-target
#   kind = dir | file  - only matters on Windows: junctions (/J) need a
#          directory, hardlinks (/H) need a file. Unix `ln -sfn` doesn't care.
# Use "-" in a target column to skip that OS for that row entirely.
#
# IMPORTANT: windows-target may (and often should) use a raw env var like
# $APPDATA/$LOCALAPPDATA instead of a literal path. Unlike global.toml's
# `target` field (expanded once at config-parse time by Dotter's own
# shellexpand, config.rs:186-198 - which can't safely special-case every OS
# folder and would crash on OSes lacking that var), THIS script only runs on
# the OS it's relevant for, and `eval echo "$var"` reads the *live* process
# environment at hook-run time - so folder redirection (GPO / OneDrive Known
# Folder Move) on the actual machine is respected, not baked-in from a
# default guess.

set -eu
mode="${1:?usage: link.sh deploy|undeploy}"
# Always invoked as ".dotter/hooks/link.sh" from the dotfiles repo root
# (Dotter runs hooks with CWD = wherever `dotter` was invoked from) - so
# "up two directories" from this script's own path is the repo root.
dotfiles_dir="$(cd "$(dirname "$0")/../.." && pwd)"

table='
nvim           dir  ~/.dotfiles-deployed/nvim              ~/.config/nvim               $LOCALAPPDATA/nvim
vscode-settings file ~/.dotfiles-deployed/vscode/settings.json ~/.config/Code/User/settings.json $APPDATA/Code/User/settings.json
'

is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

link_unix() {
    canonical=$1 target=$2
    target=$(eval echo "$target")
    case "$mode" in
        deploy)
            mkdir -p "$(dirname "$target")"
            ln -sfn "$(eval echo "$canonical")" "$target"
            ;;
        undeploy)
            [ -L "$target" ] && rm "$target"
            rmdir -p "$(dirname "$target")" 2>/dev/null || true
            ;;
    esac
}

link_windows() {
    kind=$1 canonical=$2 target=$3
    target=$(cygpath -w "$(eval echo "$target")")
    src=$(cygpath -w "$(eval echo "$canonical")")
    flag='/J'   # directory junction: no admin/dev-mode needed
    [ "$kind" = "file" ] && flag='/H'   # hardlink: no admin/dev-mode needed, files only
    case "$mode" in
        deploy)
            mkdir -p "$(dirname "$target")"
            if [ "$kind" = "dir" ]; then cmd //c rmdir "$target" >/dev/null 2>&1 || true
            else cmd //c del "$target" >/dev/null 2>&1 || true; fi
            cmd //c mklink "$flag" "$target" "$src" >/dev/null
            ;;
        undeploy)
            if [ "$kind" = "dir" ]; then cmd //c rmdir "$target" >/dev/null 2>&1 || true
            else cmd //c del "$target" >/dev/null 2>&1 || true; fi
            ;;
    esac
}

echo "$table" | while read -r name kind canonical unix_target win_target; do
    [ -z "${name:-}" ] && continue
    if is_windows; then
        [ "$win_target" = "-" ] && continue
        link_windows "$kind" "$canonical" "$win_target"
        echo "$mode: $name ($kind) -> $win_target"
    else
        [ "$unix_target" = "-" ] && continue
        link_unix "$canonical" "$unix_target"
        echo "$mode: $name -> $unix_target"
    fi
done
