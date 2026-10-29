---
name: colima-delete-leaves-its-data-disk
description: "`colima delete -p <profile>` removes the VM but KEEPS its persistent data disk — the space is not reclaimed until `colima delete -d` or `LIMA_HOME=~/.colima/_lima limactl disk delete <colima-profile>`"
metadata:
  node_type: memory
  type: reference
  scope: global
---

`colima delete -p <profile>` tears down the VM and the profile, and `colima list` then reports no instance — while the profile's **persistent data disk stays on disk under its own name**. Measured 2026-09-23: after a delete that reported `done`, `~/.colima` still held 5.7 GB in `_lima/_disks/colima-<profile>/datadisk` (a 60 GiB sparse file). The flag that would have taken it is `-d` / `--data`, which the obvious command line omits.

Reclaim it afterwards with colima's own vendored lima, which is already on PATH:

```bash
export LIMA_HOME="$HOME/.colima/_lima"
limactl disk ls                       # NAME, SIZE, and IN-USE-BY — empty means no instance holds it
limactl disk delete colima-<profile>
```

`limactl list` naming no instance is the dependent check: nothing can be using the disk, so the delete is an orphan removal rather than a guess. After it, `~/.colima` was 28 KB.

The general shape, which is the reason to remember it: **a teardown command's success message is about the thing it names, never about the space it implies.** Measure the footprint before and after (`du -sh`) and say the number, exactly as with [[recoverable-is-not-unused]] — a "deleted" that leaves gigabytes is a deletion nobody would have noticed for months.

A related trap from the same clean-up: `ps -Ao pid,command | grep -i '[c]olima\|[l]ima'` prints the grep's own shell command line, so the sweep appears to find survivors of the VM it just deleted. Read the rows before believing them — the waiter matches itself ([[a-standdown-must-disarm-the-shell-watchers]]).
