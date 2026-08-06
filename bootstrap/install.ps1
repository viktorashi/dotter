# Dotter bootstrap for Windows. PowerShell 5.1+ (ships with Win10/11).
#
#   irm <host>/install.ps1 | iex                      # prompts for repo
#   & ([scriptblock]::Create((irm <host>/install.ps1))) viktorashi
#
# Entry condition: PowerShell. Everything else is bootstrapped from here.

param(
  [string]$Repo = "",
  [switch]$NoMergiraf
)

$ErrorActionPreference = "Stop"

$Prefix    = if ($env:DOTTER_PREFIX) { $env:DOTTER_PREFIX } else { "$env:LOCALAPPDATA\dotter" }
$Bin       = Join-Path $Prefix "bin"
$Dotfiles  = if ($env:DOTFILES_DIR) { $env:DOTFILES_DIR } else { "$env:USERPROFILE\.dotfiles" }
$MergirafVersion = "v0.18.0"

function Say  ($m) { Write-Host ":: $m" -ForegroundColor Blue }
function Warn ($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "xx $m" -ForegroundColor Red; exit 1 }
function Have ($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------- git
#
# The only thing needing a package manager. winget ships with Win10 21H2+ and Win11.

function Ensure-Git {
  if (Have git) { Say "git present ($(git --version))"; return }
  Say "installing git"
  if     (Have winget) { winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements }
  elseif (Have scoop)  { scoop install git }
  elseif (Have choco)  { choco install git -y }
  else { Die "no winget/scoop/choco found. Install Git from https://git-scm.com/download/win then rerun." }

  # winget updates the machine PATH but not this session's.
  $env:PATH = [Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
              [Environment]::GetEnvironmentVariable("PATH","User")
  if (-not (Have git)) { Die "git installed but not on PATH; open a new terminal and rerun" }
}

# ---------------------------------------------------------------- binaries

function Install-Dotter {
  if (Have dotter) { Say "dotter present"; return }
  Say "downloading dotter"
  $url = "https://github.com/SuperCuber/dotter/releases/latest/download/dotter-windows-x64-msvc.exe"
  Invoke-WebRequest -Uri $url -OutFile (Join-Path $Bin "dotter.exe") -UseBasicParsing
}

function Install-Mergiraf {
  if ($NoMergiraf) { Say "skipping mergiraf"; return }
  if (Have mergiraf) { Say "mergiraf present"; return }

  # Prefer a package manager: avoids codeberg, whose release downloads are
  # observably unreliable. The zip also expands to ~71 MB (bundled grammars).
  Say "installing mergiraf (optional, improves conflict resolution)"
  try {
    if     (Have scoop) { scoop install mergiraf; }
    elseif (Have choco) { choco install mergiraf -y }
  } catch { }
  if (Have mergiraf) { Say "mergiraf installed from package manager"; return }

  $url = "https://codeberg.org/mergiraf/mergiraf/releases/download/$MergirafVersion/mergiraf_x86_64-pc-windows-gnu.zip"
  $tmp = Join-Path $env:TEMP "mergiraf.zip"
  try {
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Expand-Archive -Path $tmp -DestinationPath $Bin -Force
    Remove-Item $tmp -Force
    Say "mergiraf installed to $Bin"
  } catch {
    # Optional: never fail the bootstrap over it. `dotter doctor` reports it.
    Warn "could not install mergiraf; continuing (dotter falls back to git merge-file)"
  }
}

# ---------------------------------------------------------------- repo

function Resolve-Remote ($r) {
  if (-not $r)                { Die "usage: install.ps1 <github-user|git-remote-url>" }
  if ($r -match '://|.+@.+:') { return $r }
  if ($r -match '/')          { return "https://github.com/$r.git" }
  return "https://github.com/$r/dotfiles.git"
}

# ---------------------------------------------------------------- main

New-Item -ItemType Directory -Force -Path $Bin | Out-Null
if ($env:PATH -notlike "*$Bin*") { $env:PATH = "$Bin;$env:PATH"; $PathWarn = $true }

Ensure-Git
Install-Dotter
Install-Mergiraf

if (-not (Test-Path (Join-Path $Dotfiles ".git"))) {
  $remote = Resolve-Remote $Repo
  Say "cloning $remote -> $Dotfiles"
  git clone --recurse-submodules $remote $Dotfiles
} else {
  Say "dotfiles already at $Dotfiles"
}

Set-Location $Dotfiles

# Guarded. init-machine is an interactive picker: do not pipe it.
dotter init-machine; if ($LASTEXITCODE) { Die "machine selection cancelled or failed" }
dotter setup-git;    if ($LASTEXITCODE) { Die "git setup failed" }
dotter deploy;       if ($LASTEXITCODE) { Die "deploy failed - re-run with: dotter deploy -v" }

Say "done"
if ($PathWarn) {
  Warn "adding $Bin to your user PATH"
  $userPath = [Environment]::GetEnvironmentVariable("PATH","User")
  if ($userPath -notlike "*$Bin*") {
    [Environment]::SetEnvironmentVariable("PATH", "$userPath;$Bin", "User")
  }
}
