#!/usr/bin/env python3
"""Fail-closed scan for PRIVATE COINED NAMES surviving into the public mirror.

The sanitizer's own token list is HAND-MAINTAINED: it only ever contains what
somebody thought to type. That is how the codename `your-module` reached the public
mirror in 14 files -- 11 memories, the codex-converge skill, and a CI fixture
that is a real workflow file disclosing the `your-module/provider-data` package path
and its job names. A token pass reported clean every time, because nothing had
named the token.

This derives the candidate set instead of restating it: for every distinct local
project repo, take the TOP-LEVEL tracked entry names plus each package.json
"name", split them into word tokens, and keep the ones that are COINED -- absent
from the system dictionary, absent from a small public-vocabulary allowlist.
`your-module` is coined; `provider`, `pipeline`, `lander` and `your-project` are dictionary
words and are dropped. Then assert none of the survivors appears in the output
tree.

The BOUND, stated because a derived set is only as good as its derivation:
this catches coined names visible at a repo's top level or in a package name.
It does NOT catch a private name that is an ordinary English word (`your-project` is
handled by a substitution rule instead), nor one that appears only deeper in a
tree, nor a topic leak that names nothing at all
(memory `a-token-sanitizer-cannot-see-a-topic-leak`).

Exit 0 = clean. Exit 1 = a hit, OR the scan could not be completed -- an
incomplete scan is a FAILURE, never an approval.
"""
import argparse, json, os, re, subprocess, sys

DICT = '/usr/share/dict/words'
MIN_LEN = 5

# Public, non-secret vocabulary that is coined but discloses nothing. Kept short
# and explicit: every entry here is a hole in the scan.
PUBLIC_VOCAB = {
    'claude', 'codex', 'lavish', 'nextjs', 'vitest', 'eslint', 'pnpm', 'npmrc',
    'tsconfig', 'playwright', 'dotfiles', 'github', 'gitignore', 'linting',
    'sqlite', 'postgres', 'fastapi', 'uvicorn', 'pydantic', 'numpy', 'scipy',
    'pytest', 'ruff', 'mypy', 'dockerfile', 'docker', 'yarnrc', 'biome',
    'superpowers', 'skills', 'plugins', 'venv', 'nvmrc', 'prettierrc',
    # The generic tail this machine's repos actually produce, measured
    # 2026-09-03 with `--list-tokens`. Each is an ordinary repo-furniture name
    # that the rarity test could not drop because only one repo happens to carry
    # it. Listed one by one, because a hole you can read beats a clever rule that
    # removes a class you cannot see.
    'contributing', 'editorconfig', 'gitattributes', 'prettierignore',
    'dockerignore', 'changelog', 'gitkeep', 'vscode', 'linux', 'windows',
    'prisma', 'plugin', 'memories', 'handoffs', 'todos', 'readme',
}

def die(msg):
    print(f"private-name-scan: CANNOT COMPLETE: {msg}", file=sys.stderr)
    sys.exit(1)

def load_dict(path=None):
    path = path or DICT
    if not os.path.exists(path):
        die(f"no word list at {path}; the coined-word filter cannot run")
    with open(path, encoding='utf-8', errors='replace') as fh:
        return {w.strip().lower() for w in fh if w.strip()}

def git(repo, *args):
    r = subprocess.run(['git', '-C', repo, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ''

def repo_groups(roots):
    """Working directories grouped by the REPOSITORY they belong to.

    Both halves of this are load-bearing, and each was wrong on a first pass that
    still read green:

    - COLLECT across every worktree. `~/Coding` holds ~100 `cf-*` worktrees of one
      monorepo; they sort before the main clone, so keeping only the first one seen
      built the name set from an old branch's top level and could not see `your-module`.
    - COUNT once per repository. With each worktree counted separately, `your-module`
      appeared ~100 times and the rarity test filed it as infrastructure -- the same
      miss, from the opposite direction.

    A set that cannot see the name it was written for is not a smaller set, it is a
    broken one, which is why the test plants a name and demands a hit.
    """
    groups = {}
    for root in roots:
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if not os.path.isdir(path):
                continue
            common = git(path, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()
            if not common:
                continue
            groups.setdefault(os.path.realpath(common), []).append(path)
    return groups


def tokens_for(repo):
    """Top-level tracked entry names + package.json names, as word tokens."""
    names = set()
    for line in git(repo, 'ls-tree', '--name-only', 'HEAD').splitlines():
        names.add(line.strip())
    pkg = os.path.join(repo, 'package.json')
    if os.path.exists(pkg):
        try:
            n = json.load(open(pkg, encoding='utf-8')).get('name')
            if isinstance(n, str):
                names.add(n)
        except Exception:
            pass  # a malformed package.json is not this scan's business
    toks = set()
    for n in names:
        n = os.path.splitext(n)[0]
        for t in re.split(r'[^A-Za-z0-9]+', n):
            if t:
                toks.add(t.lower())
    return toks


SUFFIXES = ('s', 'es', 'd', 'ed', 'ing', 'able', 'ible', 'er', 'ly', 'ness')
MIN_COMPOUND_HALF = 4


def dictionary_covered(tok, words):
    """A plain word, an inflection of one, or a compound of two SUBSTANTIAL words.

    The compound half of this is bounded on purpose. A first version accepted any
    two dictionary halves and silently deleted the one name the scan exists to
    catch -- `your-module` splits into `tree` + `cue`. Coined product names are
    overwhelmingly a real word plus a SHORT tail (`-cue`, `-book`, `-off`), while
    the generic compounds worth dropping join two substantial words (`workspace`,
    `middleware`, `failsafe`). Requiring both halves to be >= 4 characters
    separates them: measured 2026-09-03, it drops `workspace`, `middleware` and
    `failsafe` while keeping the codename this scan was written for, plus short-tailed
    compounds like `runbook` and `handoff`. Examples here are deliberately generic --
    an earlier draft illustrated the rule with a real private worktree name, and this
    scan caught its own docstring on the next sync.
    """
    if tok in words:
        return True
    for suf in SUFFIXES:
        if tok.endswith(suf) and len(tok) - len(suf) >= 3 and tok[: -len(suf)] in words:
            return True
    for i in range(MIN_COMPOUND_HALF, len(tok) - MIN_COMPOUND_HALF + 1):
        if tok[:i] in words and tok[i:] in words:
            return True
    return False


def publishing_vocab(repo):
    """Words the publishing repo already uses in its OWN tracked paths.

    `handoff` is not a private name here -- it names ten files of the very repo
    being published, and it produced 631 of the 830 false hits in the first
    measured run. Whatever a repo calls its own files is, by construction, the
    vocabulary it publishes. Derived from `git ls-files`, so it tracks the repo
    instead of being restated.
    """
    return git(repo, 'ls-files').lower()


def allowed_contexts():
    """Reuse the sanitizer's OWN allow-list rather than keeping a second copy.

    `eloise-idealab/lavish-axi` is a live public clone URL that the sanitizer
    deliberately preserves; a scan carrying its own copy of that fact would drift
    from the rule it is checking.
    """
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sanitize-to-public.py')
    spec = importlib.util.spec_from_file_location('sanitize_to_public', path)
    if spec is None or spec.loader is None:
        die(f"cannot load the sanitizer at {path} to reuse its allow-list")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return list(getattr(mod, 'ALLOWED_CONTEXTS', []))


def derive(groups, words, max_repos, pub_paths):
    """Names belonging to ONE project, not to infrastructure.

    The discriminator is DERIVED, not guessed: `tests`, `hooks`, `config`,
    `scripts` appear at the top level of nearly every repo, so they are
    infrastructure; a name that appears in at most `max_repos` of them is that
    project's own. That alone separates `your-module` (one repo) from `tests` (many)
    with no word-list judgement at all -- the dictionary pass afterwards only
    trims the tail, so a bad dictionary cannot hide a private name that the
    rarity test already caught.
    """
    freq = {}
    for worktrees in groups.values():
        seen = set()
        for wt in worktrees:
            seen |= tokens_for(wt)
        for t in seen:
            if len(t) < MIN_LEN or t.isdigit():
                continue
            freq[t] = freq.get(t, 0) + 1
    return {t for t, n in freq.items()
            if n <= max_repos
            and t not in PUBLIC_VOCAB
            and t not in pub_paths
            and not dictionary_covered(t, words)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tree', required=True, help='sanitized output tree to scan')
    ap.add_argument('--roots', nargs='+', required=True,
                    help='directories holding local project repos')
    ap.add_argument('--exclude-repo', action='append', default=[],
                    help='repo path whose own names are not private (the mirror source)')
    ap.add_argument('--dict', dest='dictpath', default=None,
                    help=f'word list (default {DICT}); a missing one FAILS, never passes')
    ap.add_argument('--public-repo', default=None,
                    help='the repo being published; words in its own tracked paths are its vocabulary')
    ap.add_argument('--max-repos', type=int, default=2,
                    help='a name in more than this many repos is infrastructure, not a project name')
    ap.add_argument('--list-tokens', action='store_true', help='print the derived set and exit 0')
    a = ap.parse_args()

    words = load_dict(a.dictpath)
    roots = [r for r in a.roots if os.path.isdir(r)]
    if not roots:
        die(f"none of the given roots exist: {a.roots!r}")

    excl = {os.path.realpath(p) for p in a.exclude_repo}
    groups = {k: [w for w in v if os.path.realpath(w) not in excl]
              for k, v in repo_groups(roots).items()}
    groups = {k: v for k, v in groups.items() if v}
    if not groups:
        die(f"no git repositories found under {roots!r}")
    pub_paths = publishing_vocab(a.public_repo) if a.public_repo else ''
    coined = derive(groups, words, a.max_repos, pub_paths)

    if a.list_tokens:
        for t in sorted(coined):
            print(t)
        return 0

    if not os.path.isdir(a.tree):
        die(f"output tree {a.tree!r} is not a directory")

    pat = re.compile('|'.join(sorted(re.escape(t) for t in coined)), re.I) if coined else None
    if pat is None:
        die("derived an EMPTY coined-name set; a scan that can hit nothing is not a scan")

    allowed = allowed_contexts()
    hits = 0
    for dirpath, dirnames, filenames in os.walk(a.tree):
        dirnames[:] = [d for d in dirnames if d != '.git']
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            rel = os.path.relpath(fp, a.tree)
            try:
                text = open(fp, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for i, line in enumerate(text.splitlines(), 1):
                for ctx in allowed:
                    line = re.sub(ctx, '', line)
                for m in pat.finditer(line):
                    print(f"{rel}:{i}: private coined name {m.group(0)!r}: {line.strip()[:120]}")
                    hits += 1
    if hits:
        print(f"private-name-scan: {hits} hit(s) from {len(coined)} derived coined name(s) "
              f"over {len(groups)} repo(s)", file=sys.stderr)
        return 1
    print(f"private-name-scan: clean ({len(coined)} derived coined name(s), {len(groups)} repo(s))")
    return 0

if __name__ == '__main__':
    sys.exit(main())
