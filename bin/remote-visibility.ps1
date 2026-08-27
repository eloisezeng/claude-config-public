#!/usr/bin/env pwsh
#
# Windows sibling of bin/remote-visibility.sh. Same contract, same words:
#
#   local | private | public | unknown   on stdout, one line, always exit 0.
#
# The verdict is the OUTPUT, not the status, so a caller cannot mistake "could not tell" for
# "fine". `unknown` is a refusal signal, never a pass. A one-line reason goes to stderr.
#
# Reimplemented rather than shelling out to the .sh because a Windows box is not guaranteed to
# have bash on PATH -- and the whole point of this file is that the recipients most likely to
# fork a config repo and autosync it are exactly the ones who must not be left unguarded.

param([Parameter(Position = 0)] [string] $Url = '')

$ErrorActionPreference = 'Continue'

function Emit([string] $verdict, [string] $why) {
  # Written straight to the process's stderr handle: this script is normally dot-invoked by
  # sync.ps1, whose own log already records the verdict, and a human running it by hand gets the
  # reason on the console.
  [Console]::Error.WriteLine("remote-visibility: $why")
  Write-Output $verdict
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Url)) { Emit 'unknown' 'no remote url given' }

# ------------------------------------------------------------------------------------------------
# A filesystem remote is not published BY URL: a POSIX path, a file:// url, a drive-letter path or
# a UNC share. It may sit on a shared volume, but that is a different question from
# world-readable-over-the-internet, and not one this script can answer.
if ($Url -match '^(/|\./|\.\./|file://)' -or $Url -match '^[A-Za-z]:[\\/]' -or $Url -match '^\\\\') {
  Emit 'local' "$Url is a path on this machine"
}

# ------------------------------------------------------------------------------------------------
# Normalise to an https url that can be probed anonymously. Userinfo is dropped: the probe must
# ask what a STRANGER sees, and a stranger has no username. Leaving `someone@` in place makes git
# prompt for a password even on a PUBLIC repo, which -- with prompts disabled -- reads as
# `private` and would let the push through. An `@` is only userinfo when it precedes the first
# `/`; a repo path may legitimately contain one.
function Strip-Userinfo([string] $rest) {
  $hostpart = ($rest -split '/', 2)[0]
  if ($hostpart -match '@') { return $rest.Substring($rest.IndexOf('@') + 1) }
  return $rest
}

$probe = $null
if ($Url -match '^(https?)://(.*)$') {
  $scheme = $Matches[1]
  $probe = "${scheme}://$(Strip-Userinfo $Matches[2])"
}
elseif ($Url -match '^ssh://(.*)$') {
  $rest = Strip-Userinfo $Matches[1]              # host[:port]/owner/repo
  $parts = $rest -split '/', 2
  $h = ($parts[0] -split ':')[0]                  # drop any :port
  $p = if ($parts.Count -gt 1) { $parts[1] } else { '' }
  $probe = "https://$h/$p"
}
elseif ($Url -match '^[^/@]+@[^:/]+:.+$') {
  $hostpath = $Url.Substring($Url.IndexOf('@') + 1)   # scp-style: git@host:owner/repo.git
  $parts = $hostpath -split ':', 2
  $probe = "https://$($parts[0])/$($parts[1])"
}
else {
  Emit 'unknown' "unrecognised remote form: $Url"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Emit 'unknown' 'git is not on PATH' }

# ------------------------------------------------------------------------------------------------
# Probe with NO credentials of any kind. This is the whole test: a credential helper that silently
# authenticates would make a PRIVATE repo answer, and this script would then call it public.
#
# PowerShell has no per-command environment, so the overrides are set on the process and restored
# in a finally block -- otherwise sync.ps1's own later git calls would inherit a neutered config
# and could not push at all. `-c credential.helper=` on the command line is the load-bearing half
# and holds regardless of how a given git build treats /dev/null for GIT_CONFIG_*.
$keys = @('GIT_TERMINAL_PROMPT', 'GIT_ASKPASS', 'SSH_ASKPASS', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM')
$saved = @{}
foreach ($k in $keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$out = ''
$rc = 1
try {
  $env:GIT_TERMINAL_PROMPT = '0'
  $env:GIT_ASKPASS = '/nonexistent/askpass'
  $env:SSH_ASKPASS = '/nonexistent/askpass'
  $env:GIT_CONFIG_GLOBAL = '/dev/null'
  $env:GIT_CONFIG_SYSTEM = '/dev/null'
  $out = (git -c credential.helper= ls-remote $probe HEAD 2>&1 | Out-String)
  $rc = $LASTEXITCODE
}
finally {
  foreach ($k in $keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}

if ($rc -eq 0) { Emit 'public' "$probe served its refs to an unauthenticated reader" }

# A refusal to serve an anonymous reader is the answer we want. Every host phrases it
# differently, and GitHub deliberately answers "not found" for a private repo so the repo's
# existence is not itself leaked -- which is also what a genuine typo returns, so a mistyped
# remote reads as private here and then fails at push time on its own.
$refusals = @(
  'Authentication failed', 'could not read Username', 'terminal prompts disabled',
  'not found', 'Not Found', 'not exist',
  'Permission denied', 'access denied', '403', '401'
)
foreach ($r in $refusals) {
  if ($out -like "*$r*") { Emit 'private' "$probe refused an unauthenticated reader" }
}

$first = ($out -split "`n" | Select-Object -First 1).Trim()
Emit 'unknown' "could not classify ${probe}: $first"
