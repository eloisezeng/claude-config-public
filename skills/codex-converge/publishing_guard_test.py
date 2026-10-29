#!/usr/bin/env python3
"""publishing_guard_test.py — §6.9, §10.1 and §10.5: nothing here publishes the private tree.

Run:  python3 publishing_guard_test.py [-k PATTERN]
Prints a vitest-shaped `Test Files` / `Tests` summary so mutate.py's zero-match guard applies.

## Why this is a file of its own and why it does not hold an allowlist

This skill is published to a public mirror that DEFAULT-INCLUDES new files, and the case data it
grades is private. The guard itself (`review_eval.assert_no_project_literals`) already existed and
was already asserted over one module. §10.1 widens it to every module here, and the first full run
of that widened scan measured the DETECTOR rather than the subject: 77 hits across three files, in
five classes, four of which were the instrument.

The classes, and what each one got:

1. **Lens finding ids read as pull-request numbers** — `<lens>#<index>` matches the `#NNN` shape.
   29 of `loop_test.py`'s hits. Not a leak, and it grows with every review round.
2. **Fictional fixture paths** — two-segment paths that name nothing real. Not a leak, and the
   guard cannot tell them from a real one.
3. **The guard's own positive controls**, which must stay dirty to prove it can see a hit.
4. **Product directory names standing in as fixtures** — the one real class in miniature, because
   those are the private repository's own tree names. RENAMED to fictional ones.
5. **`mutate.py`'s usage examples**, which named a product directory. NEUTRALISED, which is the
   same remedy this guard's first firing got, rather than weakening the guard.

So the scan is not "every module, zero hits": that reddens on classes 1, 2 and 3 and the reflex of
adding an allowlist of exempt files is the hand-typed deny list the guard exists to avoid — a list
only holds what somebody typed. Instead there are TWO FILE CLASSES with different shape sets and
the reason beside each, the file set is DERIVED from the directory and asserted in both
directions, and the one place that must stay dirty is a marked REGION a reader can see rather than
a file name.
"""
from __future__ import annotations

import ast
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import review_eval as re_  # noqa: E402

#: A shipped module is scanned for EVERY shape: it is published, and nothing in it has a reason to
#: name a pull request, a source path or a directory of the private tree.
SHIPPED_SHAPES = None

#: A test module is scanned for the project-directory-literal shape ONLY, and the narrowing is the
#: whole design. A test legitimately carries fictional two-segment paths and lens finding ids,
#: which match the other two shapes and name nothing real. A project DIRECTORY name is different
#: in kind: it is the private repository's own tree, and standing in as a fixture publishes its
#: shape just as surely as naming it in shipped code would.
TEST_SHAPES = (re_.PROJECT_DIRECTORY_LITERAL,)

#: `review_eval.py` holds the depth selector, and §10.5 requires it to perform no network or model
#: call. Asserted as the module's WHOLE import set in both directions rather than as the absence of
#: a named few: a new import is then a conscious edit, where a deny list of forbidden module names
#: only ever holds what somebody typed.
DEPTH_SELECTOR_MODULE = 'review_eval.py'
DEPTH_SELECTOR_IMPORTS = {'__future__', 'math', 're', 'dataclasses', 'typing'}


def python_modules() -> list[str]:
    """Every Python module in this directory, DERIVED rather than listed.

    A hand-written list fixes additions and silently breaks nothing — a module added tomorrow is
    simply never scanned, with no diff line to point at. The bound is stated: direct `*.py`
    children of this one directory, which is what the published skill is.
    """
    return sorted(f for f in os.listdir(HERE) if f.endswith('.py'))


def published_files() -> list[str]:
    """Every file of this directory the public mirror default-includes, Python or not.

    `python_modules()` is a subset, and taking it for the whole set is what left nine published
    files unscanned: `SKILL.md`, `CONTEXT.md`, `run-codex.sh`, the output schema and the five
    mutant manifests. The mirror includes a file because it is HERE, not because it ends in
    `.py`, so the set the guard derives has to be the set the mirror publishes.

    Derived from the directory and not from `git ls-files`, for the same reason the module list
    is: a file written but not yet staged is already a file the next sync would carry, and a set
    taken from the index would not see it.
    """
    out = []
    for f in sorted(os.listdir(HERE)):
        if f.startswith('.') or f == '__pycache__':
            continue
        if os.path.isfile(os.path.join(HERE, f)):
            out.append(f)
    return out


def non_python_published_files() -> list[str]:
    """The published files that are not Python modules — prose, shell, JSON.

    Scanned for the project-DIRECTORY shape only, which is the same narrowing a test module gets
    and for the same stated reason: prose and fixture data legitimately carry two-segment path
    shapes and pull-request-shaped numbers that name nothing private, and the scan cannot tell
    those from real ones. A private repository's own tree names are different in kind.

    Measured over this directory before the narrowing was chosen: the wide scan gives two hits,
    both in `SKILL.md` (`src/pay.ts` and `hooks/compaction-recovery.mjs`), and neither names a
    private product path. The narrow scan gives none, so this guard can PASS today — which is
    the property a new assertion owes before it is believed.
    """
    mods = set(python_modules())
    return [f for f in published_files() if f not in mods]


def is_test_module(name: str) -> bool:
    return name.endswith('_test.py')


def imports_of(path: str) -> set[str]:
    """Every top-level module name `path` imports, by AST and never by reading its text."""
    with open(path, encoding='utf-8') as fh:
        tree = ast.parse(fh.read())
    found: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.update(alias.name.split('.')[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            found.add(node.module.split('.')[0])
    return found


class FileSet(unittest.TestCase):
    def test_the_scanned_set_is_derived_and_non_empty(self):
        modules = python_modules()
        self.assertTrue(
            modules,
            'Constraint: the publishing scan must read a non-empty module set; it read none.\n'
            'Recorded: §10.1 requires the guard over every skill-side module to fail closed.')
        # The lower bound is the modules that exist today, named so a DELETION is visible too: a
        # derived set fixes additions and is blind to subtractions, and nothing else here would
        # notice a module disappearing.
        self.assertEqual(
            set(modules) >= {
                'facts-from-verdict.py', 'loop.py', 'loop_test.py', 'mutate.py', 'mutate_test.py',
                'near_miss_judge.py', 'near_miss_judge_test.py', 'publishing_guard_test.py',
                'review_eval.py', 'review_eval_test.py', 'run_case.py', 'run_case_test.py',
                'tracks_meet_test.py',
            }, True,
            'Constraint: every module that existed when this guard was written must still be '
            f'scanned; the set is now {modules}.\n'
            'Recorded: §10.1 — a derived set fixes additions and is blind to subtractions.')

    def test_every_module_is_in_exactly_one_class(self):
        # Both directions, which is what makes "every module is scanned" a measurement rather
        # than a hope: the two classes partition the derived set, with no module in both and none
        # in neither.
        modules = python_modules()
        shipped = [m for m in modules if not is_test_module(m)]
        tests = [m for m in modules if is_test_module(m)]
        self.assertEqual(sorted(shipped + tests), modules)
        self.assertEqual(set(shipped) & set(tests), set())
        self.assertTrue(shipped and tests, f'both classes must be non-empty: {modules}')


class NoProjectLiterals(unittest.TestCase):
    def test_GUARD_no_shipped_module_names_the_private_tree(self):
        offenders = {}
        for name in (m for m in python_modules() if not is_test_module(m)):
            with open(os.path.join(HERE, name), encoding='utf-8') as fh:
                hits = re_.assert_no_project_literals(fh.read(), SHIPPED_SHAPES)
            if hits:
                offenders[name] = hits
        self.assertEqual(
            offenders, {},
            'Constraint: a published module may name no pull request, no project source path and '
            'no project directory of the private pilot repository.\n'
            'Recorded: §6.9 and §10.1 — this skill is published to a mirror that '
            'default-includes new files.')

    def test_GUARD_no_test_module_names_a_project_directory(self):
        offenders = {}
        for name in (m for m in python_modules() if is_test_module(m)):
            with open(os.path.join(HERE, name), encoding='utf-8') as fh:
                hits = re_.assert_no_project_literals(fh.read(), TEST_SHAPES)
            if hits:
                offenders[name] = hits
        self.assertEqual(
            offenders, {},
            'Constraint: a test module may use fictional paths and lens finding ids, but never a '
            "directory name from the private pilot repository's own tree.\n"
            'Recorded: §10.1 — a product directory standing in as a fixture publishes the '
            'tree shape, which is the one real class the first full scan found.')

    def test_CONTROL_a_planted_product_path_reddens_the_shipped_scan(self):
        # A mutant on a COPY, never in the tracked tree.
        # `[[never-arm-a-fault-in-an-auto-syncing-tree]]`.
        source_path = os.path.join(HERE, 'run_case.py')
        with open(source_path, encoding='utf-8') as fh:
            source = fh.read()
        before = re_.assert_no_project_literals(source, SHIPPED_SHAPES)
        self.assertEqual(before, [], 'the unmutated module must be clean for this to mean anything')
        # GUARD-CONTROL-BEGIN  The planted literal below must stay DIRTY: it is the only thing
        # proving this scan can see a hit. The guard's own scan of this file removes this region.
        planted = source.replace(
            "WORKSPACE_PREFIX = 'review-eval-case-'",
            "WORKSPACE_PREFIX = 'review-eval-case-'\nLEAK = 'src/core/agentActions.ts'")
        # GUARD-CONTROL-END
        self.assertNotEqual(planted, source)
        with tempfile.TemporaryDirectory() as root:
            copy = os.path.join(root, 'run_case.py')
            with open(copy, 'w', encoding='utf-8') as fh:
                fh.write(planted)
            with open(copy, encoding='utf-8') as fh:
                hits = re_.assert_no_project_literals(fh.read(), SHIPPED_SHAPES)
        self.assertTrue(hits, 'the planted product path must be reported')
        self.assertTrue(any(re_.PROJECT_DIRECTORY_LITERAL in h for h in hits), hits)
        # The tracked file is unchanged, asserted in the same test that armed the mutant.
        with open(source_path, encoding='utf-8') as fh:
            self.assertEqual(fh.read(), source)

    def test_CONTROL_a_planted_product_path_reddens_the_narrower_test_scan_too(self):
        # The narrowing is the risk: a shape set that excluded the directory literal would read
        # green on every test module forever.
        # GUARD-CONTROL-BEGIN  dirty on purpose, for the same reason as the region above.
        dirty = "fixture = 'app/companies/x'"
        # GUARD-CONTROL-END
        hits = re_.assert_no_project_literals(dirty, TEST_SHAPES)
        self.assertTrue(hits, 'the narrowed shape set must still catch a project directory')

    def test_CONTROL_the_narrowed_set_does_not_scan_for_nothing(self):
        # An empty or mistyped shape set is refused rather than scanning for nothing, which is how
        # a narrowing becomes a silent exemption.
        with self.assertRaises(ValueError):
            re_.assert_no_project_literals('x', [])
        with self.assertRaises(ValueError):
            re_.assert_no_project_literals('x', ['a shape nobody declared'])

    def test_the_narrowed_set_still_leaves_the_other_two_shapes_unscanned_deliberately(self):
        # Stated as a measurement rather than as a promise, so the cost of the narrowing is
        # visible: these two shapes are NOT checked in a test module, on purpose.
        allowed = re_.assert_no_project_literals("ident = 'lens#7'\npath = 'one/two.ts'",
                                                 TEST_SHAPES)
        self.assertEqual(allowed, [])
        self.assertEqual(len(re_.assert_no_project_literals("ident = 'lens#7'\n"
                                                            "path = 'one/two.ts'")), 2)


class SelectorPurity(unittest.TestCase):
    def test_GUARD_the_depth_selectors_module_imports_nothing_that_calls_out(self):
        actual = imports_of(os.path.join(HERE, DEPTH_SELECTOR_MODULE))
        self.assertEqual(
            actual, DEPTH_SELECTOR_IMPORTS,
            'Constraint: the depth selector\'s module imports exactly '
            f'{sorted(DEPTH_SELECTOR_IMPORTS)} — all pure standard library — so it can perform no '
            f'network or model call; it now imports {sorted(actual)}.\n'
            'Recorded: §10.5 and decision 6 — review depth is a PATH LIST and never a model '
            'classifier.')

    def test_CONTROL_an_import_that_calls_out_is_reported(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'selector.py')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write('import re\nimport urllib.request\nfrom openai import OpenAI\n')
            found = imports_of(path)
        self.assertEqual(found, {'re', 'urllib', 'openai'})
        self.assertNotEqual(found, DEPTH_SELECTOR_IMPORTS)
        self.assertTrue(found - DEPTH_SELECTOR_IMPORTS)

    def test_the_import_reader_sees_a_deferred_import_too(self):
        # A function-local import is still an import. A reader that only walked module-level
        # statements would pass for a selector that imported a client inside the function.
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, 'selector.py')
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write('def pick():\n    import urllib.request\n    return urllib\n')
            self.assertEqual(imports_of(path), {'urllib'})



class EveryPublishedFileIsScanned(unittest.TestCase):
    """The mirror publishes a file because it is in this directory, not because it is Python.

    `python_modules()` named nine published files out of twenty-three and the claim above the
    guard was about all of them.
    """

    def test_the_published_set_is_the_module_set_plus_the_rest_and_nothing_is_lost(self):
        published = set(published_files())
        mods = set(python_modules())
        rest = set(non_python_published_files())
        self.assertTrue(mods <= published)
        self.assertEqual(mods | rest, published)
        self.assertEqual(mods & rest, set())
        # Asserted in BOTH directions and against named members, so a derivation that silently
        # dropped a class would fail here rather than read as a smaller clean set.
        for name in ('SKILL.md', 'run-codex.sh', 'review-output.schema.json'):
            self.assertIn(name, rest, f'{name} is published and must be scanned')
        self.assertIn('loop.py', mods)

    def test_no_published_non_python_file_names_a_private_project_directory(self):
        dirty = {}
        for name in non_python_published_files():
            path = os.path.join(HERE, name)
            with open(path, encoding='utf-8', errors='replace') as fh:
                hits = re_.assert_no_project_literals(fh.read(), TEST_SHAPES)
            if hits:
                dirty[name] = hits
        self.assertEqual(dirty, {}, f'published non-Python files naming a private tree: {dirty}')

    def test_the_scan_can_see_a_private_directory_literal_in_a_non_python_file(self):
        # The positive control. Without it, the green above is equally consistent with a scan that
        # reports nothing at all, which is the failure mode this whole file was written after.
        with tempfile.TemporaryDirectory() as root:
            planted = os.path.join(root, 'NOTES.md')
            # GUARD-CONTROL-BEGIN  dirty on purpose, for the same reason as the regions above:
            # a control that could not be SEEN by this scan would prove nothing about it.
            fixture = 'see plugins/widget-shop for the shape\n'
            # GUARD-CONTROL-END
            with open(planted, 'w', encoding='utf-8') as fh:
                fh.write(fixture)
            with open(planted, encoding='utf-8') as fh:
                hits = re_.assert_no_project_literals(fh.read(), TEST_SHAPES)
        self.assertEqual(len(hits), 1, hits)
        self.assertIn(re_.PROJECT_DIRECTORY_LITERAL, hits[0])

if __name__ == '__main__':
    runner = unittest.TextTestRunner(verbosity=1)
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules['__main__'])
    if len(sys.argv) > 2 and sys.argv[1] == '-k':
        pattern = sys.argv[2]
        filtered = unittest.TestSuite(
            t for t in unittest.defaultTestLoader.loadTestsFromModule(sys.modules['__main__'])._tests
            for t in (t if isinstance(t, unittest.TestSuite) else [t])
            if pattern in t.id())
        suite = filtered
    result = runner.run(suite)
    total = result.testsRun
    failed = len(result.failures) + len(result.errors)
    print(f'\n Test Files  {"1 failed (1)" if failed else "1 passed (1)"}')
    print(f'      Tests  {f"{failed} failed | {total - failed} passed" if failed else f"{total} passed"} ({total})')
    sys.exit(1 if failed else 0)
