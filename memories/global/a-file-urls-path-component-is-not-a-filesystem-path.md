---
name: a-file-urls-path-component-is-not-a-filesystem-path
description: "A file: URL's .pathname is not a filesystem path — on Windows it keeps a leading slash before the drive letter — and a spawn handed one as cwd fails ENOENT naming the EXECUTABLE, so the error accuses the wrong subject."
metadata: 
  node_type: memory
  scope: global
  type: feedback
---

Convert a `file:` URL with `fileURLToPath`, never by reading its `.pathname`.
On POSIX the two agree, which is why this ships green; on Windows `new URL("..", import.meta.url).pathname` is `/D:/a/repo/sub/`, and the leading slash in front of the drive letter makes it not a directory at all.

**The diagnostic is the valuable half, because the error names the wrong subject.**
A `spawnSync` given an invalid `cwd` fails with `code: ENOENT, syscall: "spawnSync git", path: "git"` — identical to a missing executable.
So a Windows CI job reads as "git is not installed" when the real fault is the directory you computed, and you will go looking at PATH and PATHEXT.
Settle it with a control before believing either: pass a deliberately bad `cwd` to the same call on your own machine and compare the error shape.
Measured 2026-10-08 on a private frontend repo: `unit (windows-latest)` red while every macOS and Ubuntu run was green, two census tests failing this way, and the local control reproduced the shape exactly.

Sweep the class rather than the site, and note that most `.pathname` hits in a web project are `http` URLs and are fine — the class is specifically a `file:` URL whose path is then used as a path.
Guard it by forbidding the idiom on any line that also mentions `import.meta.url`, derived from `git ls-files` and failing closed on a small census, with the line-scoped BOUND written beside the assertion (a two-statement form that stores the URL first escapes it).
Build the guard's own detector from joined fragments so its source does not match itself, and name the forbidden literal by ROLE in any comment instead of spelling it — otherwise the guard catches its own docblock and the temptation is to widen it.
Prove it fails, not merely that it passes: a planted one-line offender must redden it naming that file and nothing else — `[[a-guard-must-be-satisfiable-not-just-failable]]`.

**The sibling to sweep for is any path value COMPARED as a string**, not only one used as a path.
`path.relative` and `path.join` answer in the HOST's separator, so a test asserting `path.relative(root, file) === "lib/thing.ts"` passes on macOS and Linux and fails on Windows against `lib\thing.ts`.
Normalise with `.split(path.sep).join("/")` before any comparison, and make the assertion's message print what it found, because a bare `deepEqual` diff of two nearly-identical strings hides which character differs.
Demonstrate it without a Windows machine: `path.win32.relative` returns the backslash form on any platform, so the diagnosis never has to wait for a CI log.
Measured 2026-10-09 on a private frontend repo: a one-source-location guard I had just written reddened the REQUIRED `unit (windows-latest)` leg while the macOS gate ran green six times.

This is the same shape as `[[an-event-loop-bound-timeout-accuses-the-network]]`: an error that names what did not answer is not a verdict about it.
Only a per-platform CI job can catch this class at all, which is the argument for keeping the Windows matrix leg rather than trimming it for minutes — `[[a-subset-run-is-not-a-suite-run]]`.
