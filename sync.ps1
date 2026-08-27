#!/usr/bin/env pwsh
#
# Portable Windows auto-sync for the Claude config repo — PowerShell port of sync.sh:
#   1. commit any local changes,
#   2. pull (rebase) ONLY if the remote advanced since our last fetch,
#   3. push if ahead.
#
# Triggered by:
#   - the ClaudeConfigSync scheduled task (watch.ps1 FileSystemWatcher) on any
#     change to a tracked file, and
#   - an async Claude SessionStart hook, so a session opens on the newest config.
#
# Safe to run anytime: no-ops when clean and already up to date, and serializes
# itself with a named mutex so overlapping triggers can't race the git index.
#
# FAILURES ARE NEVER SWALLOWED. This runs unattended, so a git error nobody sees
# means the repo drifts for days while every session believes it is synced. Each
# git step checks $LASTEXITCODE; a failure is logged with its stderr, raises a
# toast, drops a .FAILED marker beside the log, and leaves the repo untouched
# (no auto-abort) so the half-finished state can be diagnosed. Exits non-zero,
# which Task Scheduler records as a failed run.

# NOT SilentlyContinue: that hid every git error this script has ever produced.
$ErrorActionPreference = 'Continue'

# Repo is wherever this script lives (portable; no hard-coded path).
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $Repo

$log    = Join-Path $env:LOCALAPPDATA 'claude-config-sync.log'
$marker = Join-Path $env:LOCALAPPDATA 'claude-config-sync.FAILED'

function Log($m) {
  "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) sync: $m" | Add-Content -LiteralPath $log
}

function Notify($m) {
  # Best-effort desktop notification; never let the notifier itself break sync.
  try {
    [void][reflection.assembly]::LoadWithPartialName('System.Windows.Forms')
    $n = New-Object System.Windows.Forms.NotifyIcon
    $n.Icon = [System.Drawing.SystemIcons]::Error
    $n.BalloonTipTitle = 'Claude config sync FAILED'
    $n.BalloonTipText  = $m
    $n.Visible = $true
    $n.ShowBalloonTip(10000)
  } catch { }
}

function Fail($msg, $detail) {
  Log "FAILED: $msg"
  if ($detail) { ($detail | Out-String).TrimEnd() -split "`n" | ForEach-Object { Log "    $_" } }
  # The marker makes a past failure discoverable without reading the whole log.
  "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg" | Set-Content -LiteralPath $marker
  Write-Error "sync.ps1: $msg`n$detail`nRepo left as-is for inspection: $Repo`nLog: $log"
  Notify "$msg - see $log"
  exit 1
}

# Serialize with a named mutex. If another run holds it, let that one handle
# this round (mirrors sync.sh's atomic mkdir lock).
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeConfigSync')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
  # Debounce: editors often write a temp file then rename, firing the watcher in
  # a burst. A brief pause lets the dust settle before we read the tree.
  Start-Sleep -Seconds 1

  $ts = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')

  # 0. Refuse to touch a repo that is already mid-operation. Committing or
  #    pulling on top of an interrupted rebase/merge compounds the damage and
  #    destroys the evidence of what went wrong.
  $gitDir = (git rev-parse --git-dir 2>&1)
  if ($LASTEXITCODE -ne 0) { Fail "not a git repo: $Repo" $gitDir }
  foreach ($state in @('rebase-merge','rebase-apply','MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir.Trim() $state)) {
      Fail "a previous git operation is unfinished ($state); resolve it by hand, then sync will resume" ''
    }
  }

  # 1. Commit local changes, if any.
  if (git status --porcelain) {
    $out = (git add -A 2>&1)
    if ($LASTEXITCODE -ne 0) { Fail 'git add failed' $out }
    $out = (git commit -q -m "auto: sync config $ts" 2>&1)
    if ($LASTEXITCODE -ne 0) { Fail 'git commit failed' $out }
    Log "committed $((git rev-parse --short HEAD).Trim())"
  }

  # 2. Pull ONLY if the remote tip actually advanced since our last fetch (a new
  #    push elsewhere). `git ls-remote` is a light ref lookup, so an idle tick
  #    costs one network call instead of a full pull + rebase.
  $branch = (git rev-parse --abbrev-ref HEAD).Trim()
  $remote = git config "branch.$branch.remote"
  if (-not $remote) { $remote = 'origin' }

  # Being offline is normal, not a sync failure: skip the remote half quietly.
  $lsOut = (git ls-remote $remote "refs/heads/$branch" 2>&1)
  if ($LASTEXITCODE -ne 0) {
    Log "offline or remote unreachable; skipped pull/push ($(($lsOut | Out-String).Trim() -split "`n" | Select-Object -First 1))"
    exit 0
  }

  $remoteSha  = (($lsOut | Select-Object -First 1) -split '\s+')[0]
  $headSha    = (git rev-parse HEAD).Trim()
  $trackedSha = (git rev-parse "$remote/$branch" 2>$null)
  if ($trackedSha) { $trackedSha = $trackedSha.Trim() }

  if ($remoteSha -and $remoteSha -ne $headSha -and $remoteSha -ne $trackedSha) {
    $out = (git pull --rebase --autostash -q 2>&1)
    if ($LASTEXITCODE -ne 0) {
      # Deliberately NOT `git rebase --abort`: the conflicted state is the only
      # record of what diverged between two machines editing the same file.
      Fail 'git pull --rebase failed (likely a conflict with another machine)' $out
    }
    Log "pulled (remote advanced) -> $((git rev-parse --short HEAD).Trim())"
  }

  # 3. Push only if the local branch is ahead of its upstream.
  $ahead = 0
  $aheadRaw = (git rev-list --count '@{u}..HEAD' 2>$null)
  if ($aheadRaw) { $ahead = [int]$aheadRaw }
  if ($ahead -gt 0) {
    # This repo carries memories, transcripts, hook wiring and machine paths. Pushing it to a
    # WORLD-READABLE remote publishes all of that at once, and this script runs unattended from
    # the ClaudeConfigSync scheduled task -- so the moment nobody is watching is exactly the
    # moment it must refuse.
    #
    # bin/remote-visibility.ps1 answers local, private, public or unknown. Only local and private
    # may proceed. A missing, unreadable or inconclusive helper yields `unknown`, and unknown
    # FAILS: "we could not tell" and "it is safe" are not the same fact, and a guard that passes
    # when its own probe broke is not a guard.
    $remoteUrl = (git remote get-url $remote 2>$null)
    if ($remoteUrl) { $remoteUrl = ($remoteUrl | Select-Object -First 1).Trim() }
    $visHelper = Join-Path $Repo (Join-Path 'bin' 'remote-visibility.ps1')
    $visibility = 'unknown'
    if (-not $remoteUrl) {
      $visWhy = "no url is configured for remote '$remote'"
    }
    elseif (-not (Test-Path -LiteralPath $visHelper)) {
      $visWhy = "$visHelper is missing; install it alongside sync.ps1"
    }
    else {
      try {
        $visOut = (& $visHelper $remoteUrl)
        $visibility = (($visOut | Select-Object -Last 1) -replace '\s', '')
      }
      catch {
        $visibility = 'unknown'
      }
      if (-not $visibility) { $visibility = 'unknown' }
      $visWhy = "bin/remote-visibility.ps1 classified the remote as '$visibility'"
    }
    if ($visibility -ne 'local' -and $visibility -ne 'private') {
      if ($env:CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH -eq '1') {
        Log "WARNING: pushing to $remoteUrl regardless: $visWhy (CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1)"
      }
      else {
        Fail 'refusing to push: the remote is not private' @"
remote:  $remoteUrl
verdict: $visibility
reason:  $visWhy

This repo is only ever pushed to a private remote or a local path. Point it at a private
remote, or set CLAUDE_CONFIG_ALLOW_PUBLIC_PUSH=1 for one run if this remote really is
meant to be world-readable.
"@
      }
    }
    $pushOut = (git push -q 2>&1)
    if ($LASTEXITCODE -ne 0) {
      # Raced with another machine's push: rebase on the new tip and retry once.
      $pullOut = (git pull --rebase --autostash -q 2>&1)
      if ($LASTEXITCODE -ne 0) {
        Fail 'push rejected, and the follow-up rebase failed' "$pushOut`n$pullOut"
      }
      $pushOut2 = (git push -q 2>&1)
      if ($LASTEXITCODE -ne 0) {
        Fail 'push failed after rebasing on the new remote tip' $pushOut2
      }
    }
    Log "pushed $((git rev-parse --short HEAD).Trim())"
  }

  # Got all the way through: clear any stale failure marker.
  if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
}
finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
