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
# Columns:  name  canonical-source (relative to dotfiles repo root)  unix-target  windows-target
# Use "-" in a target column to skip that OS for that row entirely.

set -eu
mode="${1:?usage: link.sh deploy|undeploy}"
# Always invoked as ".dotter/hooks/link.sh" from the dotfiles repo root
# (Dotter runs hooks with CWD = wherever `dotter` was invoked from) - so
# "up two directories" from this script's own path is the repo root.
dotfiles_dir="$(cd "$(dirname "$0")/../.." && pwd)"

table='
nvim ~/.dotfiles-deployed/nvim ~/.config/nvim $LOCALAPPDATA/nvim
'

is_windows() {
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac
}

link_unix() {
    name=$1 canonical=$2 target=$3
    target=$(eval echo "$target")
    case "$mode" in
        deploy)
            mkdir -p "$(dirname "$target")"
            ln -sfn "$(eval echo "$canonical")" "$target"
            echo "linked $name -> $target"
            ;;
        undeploy)
            [ -L "$target" ] && rm "$target" && echo "unlinked $name ($target)"
            ;;
    esac
}

link_windows() {
    name=$1 canonical=$2 target=$3
    [ "$target" = "-" ] && return 0
    target=$(cygpath -w "$(eval echo "$target")")
    src=$(cygpath -w "$(eval echo "$canonical")")
    case "$mode" in
        deploy)
            cmd //c rmdir "$target" >/dev/null 2>&1 || true
            cmd //c mklink /J "$target" "$src" >/dev/null
            echo "junctioned $name -> $target"
            ;;
        undeploy)
            cmd //c rmdir "$target" >/dev/null 2>&1 && echo "removed junction $name ($target)" || true
            ;;
    esac
}

echo "$table" | while read -r name canonical unix_target win_target; do
    [ -z "${name:-}" ] && continue
    if is_windows; then
        [ "$win_target" = "-" ] && continue
        link_windows "$name" "$canonical" "$win_target"
    else
        [ "$unix_target" = "-" ] && continue
        link_unix "$name" "$canonical" "$unix_target"
    fi
done
