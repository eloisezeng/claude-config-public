---
name: flock-absent-on-macos-validate-boolean-probes
description: "flock(1) does not exist on macOS — `flock -n FILE true` exits 127, so a branch reading non-zero as \"lock held\" reports HELD for every input including no watcher at all; prove a lease with perl flock(LOCK_EX|LOCK_NB) plus a zeroing control"
metadata:
  node_type: memory
  type: reference
  scope: global
---

`flock(1)` is a util-linux binary and is **not present on macOS**. A lease probe written as
`flock -n "$LEASE" true; [ $? -ne 0 ] && echo held` therefore exits **127** on every call and prints
`held` for any input — a lease nobody holds, a path that does not exist, no watcher running at all.
It fails in the direction that looks healthy, which is why it survives review.

The sound proof is perl, and it needs a **zeroing control** to be a probe at all:

```perl
perl -e 'use Fcntl qw(:flock);
  for my $spec (@ARGV) { my ($l,$p)=split /=/,$spec,2;
    unless (-e $p) { print "$l: MISSING\n"; next }
    open(my $fh,"<",$p) or next;
    if (flock($fh,LOCK_EX|LOCK_NB)) { print "$l: FREE\n"; flock($fh,LOCK_UN) }
    else { print "$l: HELD\n" } }' "LEASE=$rec.watch.$gen" "CONTROL=$(mktemp)"
```

Read it only when **LEASE=HELD and CONTROL=FREE**. If the control also says HELD the probe is a
constant and proves nothing. `ps`/`pgrep` showing the pid is corroboration, never the proof.

Generalisation, and the reason this is worth its own memory: **a boolean probe must be run against a
control that forces the opposite answer.** The same session that got burned by `flock` also "verified"
a record was ANSI-clean by counting `033` in `od -c` output — but `od -c` prints **octal offsets**, so
`0001033` matches as readily as a real ESC; it reported 4 escape bytes in a file containing none. The
fix in both cases is the same shape: run the probe against a dirty control and a clean control and
require them to disagree.

Related: [[absence-needs-a-probe-that-could-see-presence]], [[verify-claims-against-artifacts]],
[[a-probe-is-part-of-the-population-it-measures]], [[worker-liveness-must-reflect-progress]].
