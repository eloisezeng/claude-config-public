#!/usr/bin/env python3
"""Fail if any skill body contains an interpolatable ``$<digit>`` token.

WHY
---
A skill's ``args`` are word-split and expanded into its SKILL.md body as shell-style
positional parameters BEFORE the text reaches the model. Any bare ``$5`` in skill prose
is therefore rewritten with the caller's 5th argument word. This is silent: the model
sees the corrupted text as though it were authored that way.

Two live instances were found on 2026-09-02, both in this repo:

  * ``skills/codex-converge/SKILL.md`` -- the SPEND guardrail. Its published tier
    pricing ("Sol $5/$30, Terra $2.50/$15, Luna $1/$6") was being rewritten into
    nonsense on every args-bearing invocation of that skill.
  * ``skills/email-drafter/SKILL.md`` -- eleven tokens inside the voice-profile
    examples. That skill is normally invoked WITH args, so the examples that define
    how the user writes were being silently rewritten on essentially every call.

MEASURED EXPANDER BEHAVIOUR (probe skill, args "zero one two three four INJECTED")
---------------------------------------------------------------------------------
    $5        -> INJECTED          interpolates
    \\$5       -> $5                SAFE  -- exactly one backslash escapes
    \\\\$5      -> \\\\INJECTED        interpolates (both backslashes preserved)
    \\\\\\$5     -> \\\\\\INJECTED       interpolates
    \\\\\\\\$5    -> \\\\\\\\INJECTED      interpolates
    $1        -> one               interpolates
    $9        -> $9                literal ONLY because 9 > argc; not safety
    $10       -> $10               literal ONLY because 10 > argc; parsed as one index

The escape is therefore NOT shell semantics and NOT parity. A token is safe if and
only if the run of backslashes immediately preceding it has length EXACTLY ONE.
Zero, two, three and four all interpolate. ``${5}`` is inert and backticks do not
protect. Out-of-range indices render literally, but that depends on how many words
the CALLER passed, so it is never a reason to leave a token unescaped.

FAIL-CLOSED
-----------
A scan that could not read what it was asked to read is an ERROR, never a pass:
a missing or non-directory root, a traversal error, an unreadable file, or a scan
that found zero files all exit non-zero. Directory symlinks are followed, because
``~/.claude/skills`` is a farm of symlinks into the real tree and ``Path.rglob``
does not descend into them.
"""
import argparse
import os
import pathlib
import re
import sys

DEFAULT_DIRS = ['~/.claude/skills', '~/dotfiles/claude/skills']

# Every '$' followed by a digit. Backslash-run length is measured separately,
# because a negative lookbehind cannot distinguish one backslash from two.
TOKEN = re.compile(r'\$[0-9]')

SAFE_BACKSLASH_RUN = 1  # measured: exactly one escapes; 0, 2, 3, 4 all interpolate.


def backslash_run_before(line, idx):
    """Length of the contiguous backslash run ending just before ``idx``."""
    n = 0
    while idx - n - 1 >= 0 and line[idx - n - 1] == '\\':
        n += 1
    return n


def findings_in(line):
    """Yield (column, token, backslash_run) for each interpolatable token."""
    for m in TOKEN.finditer(line):
        run = backslash_run_before(line, m.start())
        if run != SAFE_BACKSLASH_RUN:
            yield m.start() + 1, m.group(0), run


def iter_md(root):
    """Walk ``root`` following directory symlinks; raise on any traversal error."""
    def onerror(err):
        raise err
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True, onerror=onerror):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith('.md'):
                yield pathlib.Path(dirpath) / name


def scan(dirs):
    seen, findings, errors, nfiles = set(), [], [], 0
    for d in dirs:
        root = pathlib.Path(d).expanduser()
        if not root.is_dir():
            errors.append(f'requested root is missing or not a directory: {root}')
            continue
        try:
            files = list(iter_md(root))
        except OSError as e:
            errors.append(f'traversal failed under {root}: {e}')
            continue
        for f in files:
            real = os.path.realpath(f)  # dedupe: ~/.claude/skills symlinks into dotfiles
            if real in seen:
                continue
            seen.add(real)
            try:
                text = f.read_text(encoding='utf-8', errors='strict')
            except (OSError, UnicodeDecodeError) as e:
                errors.append(f'unreadable: {f}: {e}')
                continue
            nfiles += 1  # counted only after a successful read
            for lineno, line in enumerate(text.splitlines(), 1):
                for col, tok, run in findings_in(line):
                    findings.append((f, lineno, col, tok, run))
    return findings, errors, nfiles


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('dirs', nargs='*', default=None,
                    help='skill directories to scan (default: the live skill tree)')
    args = ap.parse_args()
    dirs = args.dirs if args.dirs else DEFAULT_DIRS

    findings, errors, nfiles = scan(dirs)

    for f, lineno, col, tok, run in findings:
        why = 'unescaped' if run == 0 else f'{run} backslashes (only 1 escapes)'
        print(f'FAIL {f}:{lineno}:{col}: {tok} -- {why}')
    for e in errors:
        print(f'ERROR {e}')

    if errors:
        print(f'incomplete scan: {len(errors)} error(s); refusing to report clean')
        return 2
    if nfiles == 0:
        print(f'no .md files read under {dirs}; refusing to report clean')
        return 2
    if findings:
        print(f'{len(findings)} interpolatable token(s) in {nfiles} file(s); escape each as \\$N')
        return 1
    print(f'clean: {nfiles} skill file(s), no interpolatable $N tokens')
    return 0


if __name__ == '__main__':
    sys.exit(main())
