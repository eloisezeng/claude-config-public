#!/usr/bin/env pwsh
#
# Persistent, self-healing file watcher for the Claude config repo - the Windows
# analog of the macOS launchd WatchPaths agent / the Linux systemd .path unit.
# Blocks on the filesystem until a tracked file changes, debounces the burst,
# then runs sync.ps1. Ignores .git/ (git's own writes during a commit would
# otherwise re-trigger the watcher in a loop).
#
# Launched at logon (hidden) by the ClaudeConfigSync scheduled task.
#
# Durability: a FileSystemWatcher can go stale across system sleep/resume. So the
# loop NEVER exits - it recreates the watcher on any error AND on each idle cycle,
# and the process is also relaunched at every logon (plus a 15-min task watchdog).
# The Claude SessionStart hook (sync.ps1) is the independent per-session backstop.
#
# Uses the synchronous FileSystemWatcher.WaitForChanged rather than
# Register-ObjectEvent -Action: a dedicated watcher process has no event pump
# (its main thread sits blocked), so async action blocks would never fire.
#
# NOTE: ASCII only. Windows PowerShell 5.1 reads .ps1 files as the system ANSI
# codepage, so a non-ASCII char (e.g. an em-dash) in a *string literal* corrupts
# and breaks parsing. Keep code strings ASCII.

$ErrorActionPreference = 'SilentlyContinue'

$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$sync = Join-Path $Repo 'sync.ps1'
$log  = Join-Path $env:LOCALAPPDATA 'claude-config-watch.log'

function WLog($m) {
  "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) watch: $m" | Add-Content -LiteralPath $log
}

function Invoke-Sync {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $sync
}

function New-Watcher {
  $w = New-Object System.IO.FileSystemWatcher
  $w.Path = $Repo
  $w.IncludeSubdirectories = $true
  $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor `
                    [System.IO.NotifyFilters]::FileName  -bor `
                    [System.IO.NotifyFilters]::DirectoryName
  return $w
}

WLog "started (pid $PID)"

# Initial sync on startup: catch edits made while logged off / asleep, and pull
# anything new pushed from another machine.
Invoke-Sync

$fsw = New-Watcher
while ($true) {
  try {
    # Block up to 10 min for a change. On timeout we recreate the watcher below,
    # which heals the case where sleep/resume silently kills its event stream.
    $change = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, 600000)

    if ($change.TimedOut) {
      # Idle cycle: refresh the (possibly stale) watcher. No network, no commit.
      try { $fsw.Dispose() } catch {}
      $fsw = New-Watcher
      continue
    }

    # Ignore git's own internal writes (.git\...), or we'd loop on every commit.
    if ($change.Name -like '.git*' -or $change.Name -like '*\.git\*') { continue }

    # Debounce: editors write a temp file then rename, firing several changes in
    # a burst. Pause so they settle; sync.ps1 then commits the final state once.
    Start-Sleep -Milliseconds 1500
    Invoke-Sync
  }
  catch {
    WLog ("error: " + $_.Exception.Message + " - recreating watcher")
    try { $fsw.Dispose() } catch {}
    Start-Sleep -Seconds 2
    $fsw = New-Watcher
    Invoke-Sync   # catch up on anything missed during the gap
  }
}
