<#
.SYNOPSIS
  v3-007 install.ps1 — Windows entry point (thin shell) for the dev-env deployer.

.DESCRIPTION
  This is a THIN SHELL. It does NOT re-implement Mode A / Mode B / preflight —
  all of that lives in install.sh (pure bash, 3.2 compatible). On Windows the
  hooks themselves run under Git Bash (Claude Code executes hook command strings
  via Git Bash when it is present), so the whole deployer runs the same bash
  scripts. This script does three things and three things only:

    1. DETECT Git Bash's bash.exe (CLAUDE_CODE_GIT_BASH_PATH, then PATH, then the
       common absolute install locations).
    2. If found, SET the user-level environment variable CLAUDE_CODE_GIT_BASH_PATH
       to point at it — this forces Claude Code to run hook commands through Git
       Bash (rather than cmd / a bare `bash` that may not be on PATH), so the
       literal $(git rev-parse --show-toplevel) inside the wired hooks expands.
    3. FORWARD to install.sh through that bash.exe, passing every argument through
       unchanged.

  If Git Bash is NOT found, it prints clear guidance (install Git for Windows,
  with the download link) and exits non-zero. It NEVER auto-installs Git.

  WHY Git Bash is required on Windows
  -----------------------------------
  The Claude Code hooks docs state hook command strings are handed to a shell:
  `sh -c` on macOS/Linux, and on Windows to Git Bash (falling back to PowerShell
  only if Git Bash is absent). Because we REQUIRE Git Bash, Claude Code runs the
  existing `bash "$(git rev-parse --show-toplevel)/hooks/..."` hook commands under
  Git Bash, so the $(...) command substitution expands as on macOS/Linux — the
  wired hooks need NO Windows-specific rewrite.

  Known Windows gotchas this script handles / the README documents:
    - CC may default to cmd or a bare `bash` that is not on PATH (GitHub issue
      #22700). Mitigation: set CLAUDE_CODE_GIT_BASH_PATH (step 2 above).
    - CRLF line endings break the shebang under Git Bash (`bash\r` not found),
      silently disabling hooks. Mitigation: .gitattributes forces *.sh to LF on
      checkout. If the repo was cloned BEFORE .gitattributes existed, re-normalize
      with `git add --renormalize .` (see README).
    - bash.exe lives in `Git\bin`, but some installs only add `Git\cmd` to PATH.
      So detection checks common absolute paths, not just PATH.

.NOTES
  TESTABILITY (honest disclosure): this script CANNOT be auto-tested or even
  `bash -n`-checked on the maintainer's machine (macOS, no PowerShell installed).
  It is BEST-EFFORT and MUST be verified by the operator on a real Windows host —
  specifically the three steps: (1) bash.exe detection, (2) setting the User env
  var, (3) forwarding to install.sh. The core logic it forwards to (install.sh +
  lib/*.sh) is covered by the 116-test bash suite; only this Windows wrapper is
  unverified here.

.EXAMPLE
  # Interactive menu (choose Mode A / Mode B / both):
  ./install.ps1

.EXAMPLE
  # Non-interactive machine-level install:
  ./install.ps1 --mode-a --auto

.EXAMPLE
  # Adopt the guard into a target project repo:
  ./install.ps1 --adopt 'C:\path\to\your\repo'
#>

[CmdletBinding()]
param(
    # All arguments are forwarded verbatim to install.sh. ValueFromRemaining lets
    # callers pass install.sh's own flags (--auto, --mode-a, --adopt <repo>,
    # --preflight-only, --update, --help) straight through.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardArgs
)

$ErrorActionPreference = 'Stop'

# --- 1. Detect Git Bash's bash.exe ------------------------------------------
# Order: an already-set CLAUDE_CODE_GIT_BASH_PATH, then PATH, then the common
# absolute install locations (because some installs only add Git\cmd to PATH,
# while bash.exe lives in Git\bin).
function Find-GitBash {
    # (a) Honour an existing CLAUDE_CODE_GIT_BASH_PATH if it points at a real file.
    $fromEnv = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
    if ([string]::IsNullOrEmpty($fromEnv)) {
        $fromEnv = $env:CLAUDE_CODE_GIT_BASH_PATH
    }
    if (-not [string]::IsNullOrEmpty($fromEnv) -and (Test-Path -LiteralPath $fromEnv -PathType Leaf)) {
        return $fromEnv
    }

    # (b) bash.exe on PATH.
    $onPath = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        # Prefer a Git-shipped bash; avoid pointing at the WSL `bash.exe`
        # (System32\bash.exe), which is NOT Git Bash.
        foreach ($c in @($onPath)) {
            $p = $c.Source
            if ($p -and $p -notmatch '\\System32\\') {
                return $p
            }
        }
    }

    # (c) Common absolute install locations for Git for Windows.
    $candidates = @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'),
        (Join-Path $env:ProgramW6432 'Git\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrEmpty($c) -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return $c
        }
    }

    return $null
}

$bash = Find-GitBash

# --- 2. Not found -> guide the user, do NOT auto-install ---------------------
if ([string]::IsNullOrEmpty($bash)) {
    Write-Host ''
    Write-Host 'ERROR: Git Bash (bash.exe) was not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'This deployer requires Git for Windows (which ships Git Bash). On Windows,'
    Write-Host 'Claude Code runs hook commands through Git Bash, so the same bash hooks work'
    Write-Host 'unchanged. Please install Git for Windows, making sure "Git Bash" is included:'
    Write-Host ''
    Write-Host '    https://git-scm.com/download/win' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'After installing, re-run:  ./install.ps1'
    Write-Host ''
    exit 1
}

Write-Host "Found Git Bash: $bash"

# --- 3a. Set the user-level CLAUDE_CODE_GIT_BASH_PATH ------------------------
# Forces Claude Code to run hook command strings through THIS bash.exe rather
# than cmd / a bare `bash` that may not be on PATH (GitHub issue #22700). User
# scope so it persists; it takes effect in NEW terminals / a restarted Claude
# Code (the current process keeps its old environment).
$existing = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', 'User')
if ($existing -ne $bash) {
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bash, 'User')
    Write-Host "Set user environment variable CLAUDE_CODE_GIT_BASH_PATH = $bash"
    Write-Host 'NOTE: open a NEW terminal (and restart Claude Code) for this to take effect.' -ForegroundColor Yellow
}
else {
    Write-Host 'CLAUDE_CODE_GIT_BASH_PATH already set correctly — no change.'
}
# Also export into the CURRENT process so the install.sh run below inherits it.
$env:CLAUDE_CODE_GIT_BASH_PATH = $bash

# --- 3b. Forward to install.sh through Git Bash ------------------------------
# install.sh sits next to this script. We translate its Windows path to a bash
# path and invoke it with `bash -lc 'exec "<path>" "$@"' install.sh <args...>`,
# so install.sh receives our forwarded args as positional parameters with their
# original spacing/quoting preserved (no manual re-quoting into one string).
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installSh = Join-Path $scriptDir 'install.sh'

if (-not (Test-Path -LiteralPath $installSh -PathType Leaf)) {
    Write-Host "ERROR: install.sh not found next to install.ps1 (expected at $installSh)." -ForegroundColor Red
    exit 1
}

# Convert a Windows path (C:\a\b) to a bash/MSYS path (/c/a/b) via cygpath, which
# ships with Git Bash. Falls back to a best-effort manual conversion.
function ConvertTo-BashPath {
    param([string] $WinPath, [string] $BashExe)
    $bashDir = Split-Path -Parent $BashExe
    $cygpath = Join-Path $bashDir 'cygpath.exe'
    if (Test-Path -LiteralPath $cygpath -PathType Leaf) {
        $converted = & $cygpath -u $WinPath
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrEmpty($converted)) {
            return $converted.Trim()
        }
    }
    # Fallback: C:\a\b -> /c/a/b
    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') {
        return ('/' + $matches[1].ToLower() + $matches[2])
    }
    return $p
}

$installShBash = ConvertTo-BashPath -WinPath $installSh -BashExe $bash

# Build the argument list for bash: -lc runs a login shell so PATH/git resolve as
# in a normal Git Bash session. `exec "$0" "$@"` runs install.sh with the
# forwarded args as "$@"; we pass install.sh's bash path as $0 and the rest after.
$bashArgs = @('-lc', 'exec "$0" "$@"', $installShBash)
if ($ForwardArgs) {
    $bashArgs += $ForwardArgs
}

Write-Host "Forwarding to install.sh via Git Bash..."
& $bash @bashArgs
exit $LASTEXITCODE
