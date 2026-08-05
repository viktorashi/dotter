#!/bin/sh
# Dotter bootstrap. POSIX sh: works on dash, ash, bash.
#
#   curl -fsSL <host>/install.sh | sh -s viktorashi
#   curl -fsSL <host>/install.sh | sh -s https://git.example/me/dotfiles.git
#
# Entry condition: you can run this, therefore you have curl (or wget) and a shell.
# Everything else is bootstrapped from here.
#
# Env overrides: DOTTER_PREFIX (default ~/.local), DOTFILES_DIR (default ~/.dotfiles),
#                NO_MERGIRAF=1, DOTTER_VERSION, MERGIRAF_VERSION

set -eu

REPO_ARG="${1:-}"
PREFIX="${DOTTER_PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
DOTFILES="${DOTFILES_DIR:-$HOME/.dotfiles}"
MERGIRAF_VERSION="${MERGIRAF_VERSION:-v0.18.0}"

DOTTER_REPO=SuperCuber/dotter
MERGIRAF_BASE=https://codeberg.org/mergiraf/mergiraf/releases/download

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- fetch

if have curl; then
  # --retry/-C: codeberg release downloads are observably flaky (HTTP/2 CANCEL,
  # truncated bodies). Resume rather than restart.
  fetch() { curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -C - "$1" -o "$2"; }
  fetch_stdout() { curl -fsSL --retry 3 "$1"; }
elif have wget; then
  fetch() { wget -q --tries=5 --waitretry=2 -c -O "$2" "$1"; }
  fetch_stdout() { wget -qO- "$1"; }
else
  die "need curl or wget"
fi

# ---------------------------------------------------------------- platform

detect_platform() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) die "unsupported OS: $os (use install.ps1 on Windows)" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported arch: $arch" ;;
  esac
}

# Release asset names are irregular upstream; map explicitly rather than compose.
dotter_asset() {
  case "$os-$arch" in
    linux-x64)   echo dotter-linux-x64-musl ;;
    linux-arm64) echo dotter-linux-arm64-musl ;;
    macos-arm64) echo dotter-macos-arm64.arm ;;
    macos-x64)   die "upstream ships no macos-x64 build; install with: cargo install dotter" ;;
    *) die "no dotter build for $os-$arch" ;;
  esac
}

mergiraf_asset() {
  case "$os-$arch" in
    linux-x64)   echo mergiraf_x86_64-unknown-linux-musl.tar.gz ;;
    linux-arm64) echo mergiraf_aarch64-unknown-linux-musl.tar.gz ;;
    macos-arm64) echo mergiraf_aarch64-apple-darwin.tar.gz ;;
    macos-x64)   echo mergiraf_x86_64-apple-darwin.tar.gz ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- git
#
# The ONLY thing that needs a native package manager. There is no portable static
# git. Everything else here is a static binary download.
#
# This is deliberately one package, named `git` in every manager. It is NOT a
# general package-manager abstraction; installing the user's own application list
# is the job of their pre_deploy hook.

as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif have sudo; then sudo "$@"
  elif have doas; then doas "$@"
  else die "need root to install git. Run as root, or install git yourself: $*"
  fi
}

ensure_git() {
  have git && { say "git present ($(git --version))"; return; }
  say "installing git"
  if   have pacman;       then as_root pacman -Sy --noconfirm --needed git
  elif have apt-get;      then as_root apt-get update -qq && as_root apt-get install -y git
  elif have dnf;          then as_root dnf install -y git
  elif have yum;          then as_root yum install -y git
  elif have zypper;       then as_root zypper --non-interactive install git
  elif have apk;          then as_root apk add --no-cache git
  elif have xbps-install; then as_root xbps-install -Sy git
  elif have emerge;       then as_root emerge --quiet dev-vcs/git
  elif have brew;         then brew install git
  elif [ "$os" = macos ]; then
    warn "triggering Xcode Command Line Tools install (provides git); rerun when it finishes"
    xcode-select --install || true
    exit 1
  else
    die "no known package manager. Install git, then rerun."
  fi
  have git || die "git install reported success but git is not on PATH"
}

# ---------------------------------------------------------------- binaries

install_dotter() {
  if have dotter && [ -z "${DOTTER_VERSION:-}" ]; then
    say "dotter present ($(dotter --version 2>/dev/null || echo unknown))"; return
  fi
  asset=$(dotter_asset)
  ver="${DOTTER_VERSION:-latest}"
  if [ "$ver" = latest ]; then
    url="https://github.com/$DOTTER_REPO/releases/latest/download/$asset"
  else
    url="https://github.com/$DOTTER_REPO/releases/download/$ver/$asset"
  fi
  say "downloading dotter ($asset)"
  fetch "$url" "$BIN/dotter"
  chmod +x "$BIN/dotter"
}

install_mergiraf() {
  [ "${NO_MERGIRAF:-0}" = 1 ] && { say "skipping mergiraf (NO_MERGIRAF=1)"; return; }
  have mergiraf && { say "mergiraf present ($(mergiraf --version))"; return; }

  # Prefer a system package. It is shared, kept updated, and avoids codeberg —
  # whose release downloads are observably unreliable. The tarball also extracts
  # to ~71 MB thanks to ~30 bundled tree-sitter grammars.
  say "installing mergiraf (optional, improves conflict resolution)"
  {
    if   have pacman; then as_root pacman -Sy --noconfirm --needed mergiraf
    elif have apk;    then as_root apk add --no-cache mergiraf
    elif have brew;   then brew install mergiraf
    elif have zypper; then as_root zypper --non-interactive install mergiraf
    elif have nix-env; then nix-env -iA nixpkgs.mergiraf
    elif have emerge; then as_root emerge --quiet dev-vcs/mergiraf
    fi
  } >/dev/null 2>&1 || true
  have mergiraf && { say "mergiraf installed from system packages"; return; }

  asset=$(mergiraf_asset) || { warn "no mergiraf build for $os-$arch; skipping"; return 0; }
  tmp=$(mktemp -d)
  if fetch "$MERGIRAF_BASE/$MERGIRAF_VERSION/$asset" "$tmp/m.tar.gz" \
     && tar xzf "$tmp/m.tar.gz" -C "$tmp" 2>/dev/null; then
    mv "$tmp/mergiraf" "$BIN/mergiraf"
    chmod +x "$BIN/mergiraf"
    say "mergiraf installed to $BIN"
  elif have cargo; then
    warn "binary download failed; building from source (slow)"
    cargo install mergiraf --root "$PREFIX" >/dev/null 2>&1 || warn "cargo install mergiraf failed"
  else
    # Optional dependency: never fail the bootstrap over it. `dotter doctor`
    # will report it as missing with the right install command.
    warn "could not install mergiraf; continuing (dotter falls back to git merge-file)"
  fi
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- repo

resolve_remote() {
  case "$1" in
    "")            die "usage: install.sh <github-user|git-remote-url>" ;;
    *://*|*@*:*)   echo "$1" ;;                      # full remote
    */*)           echo "https://github.com/$1.git" ;;  # user/repo
    *)             echo "https://github.com/$1/dotfiles.git" ;;  # bare user
  esac
}

clone_repo() {
  remote=$(resolve_remote "$REPO_ARG")
  if [ -d "$DOTFILES/.git" ]; then
    say "dotfiles already at $DOTFILES"; return
  fi
  say "cloning $remote -> $DOTFILES"
  git clone --recurse-submodules "$remote" "$DOTFILES"
}

# ---------------------------------------------------------------- main

detect_platform
mkdir -p "$BIN"
case ":$PATH:" in *":$BIN:"*) ;; *) export PATH="$BIN:$PATH"; PATH_WARN=1 ;; esac

ensure_git
install_dotter
install_mergiraf
clone_repo

cd "$DOTFILES"
say "selecting machine profile"
dotter init-machine          # fzf-style picker; writes local.toml, may extend global.toml
dotter setup-git             # rerere + mergiraf merge driver + .gitattributes
dotter deploy

say "done"
[ "${PATH_WARN:-0}" = 1 ] && warn "add $BIN to your PATH"
exit 0
