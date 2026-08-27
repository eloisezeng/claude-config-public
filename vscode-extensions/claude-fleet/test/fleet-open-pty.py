#!/usr/bin/env python3
"""Drives the REAL `fleet open` under a pty, against a DETERMINISTIC fleet.

`fleet open` is the whole writable feature: it is what a pane runs when you click
the button, and getting it wrong means typing into the wrong session. Two properties
make this test worth having:

  * It runs the fleet script UNDER TEST, named by $FLEET_BIN, with no fallback to
    whatever happens to be installed. Pointing it at the installed copy meant a
    `fleet.sh` mutated to `exec /usr/bin/false` still passed every test.
  * It builds its own $HOME containing four fabricated session state files, so the
    roster is the same on a busy machine and an idle one. The earlier version read the
    live fleet and SKIPPED when nothing was running — a green run that had tested
    nothing, on exactly the machine state where a regression ships unnoticed.

`claude` is faked (see ./fake-claude), so no session is opened and nothing is spent.
"""
import json, os, pty, re, select, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
FLEET = os.environ.get('FLEET_BIN', '')
if not FLEET or not os.path.isfile(FLEET):
    sys.exit('fleet-open-pty: $FLEET_BIN must name the fleet script under test '
             '(got %r). go.sh sets it; there is deliberately no fallback.' % FLEET)

fails = []
ran = [0]
def t(name, cond, detail=''):
    ran[0] += 1
    print(('  ok   ' if cond else '  FAIL ') + name)
    if not cond:
        fails.append(name)
        if detail: print('       ' + str(detail).replace('\n', '\n       '))

# ---------------------------------------------------------------- the fixture
# `fleet ids` enumerates $HOME/.claude/jobs/*/state.json, so a temp HOME is a complete,
# deterministic roster. $HOME/.claude/bin must still hold the real helpers (need_node
# checks for them), so it is linked rather than copied.
HOME = tempfile.mkdtemp(prefix='fleet-pty-')
os.makedirs(os.path.join(HOME, '.claude'))
# `bin/fleet` resolves its helpers as "$HOME/.claude/bin/<name>", so this symlink decides
# WHICH fleet-watch.mjs / fleet-tail.mjs the panes below run. Taking it as a parameter is
# what makes those two viewers mutable: mutate.sh's watch/tail targets copy the whole bin
# directory, arm one file inside the copy, and point the fixture here. Unset, it is the
# tracked directory, exactly as before.
BINDIR = os.environ.get('FLEET_BIN_DIR') or os.path.realpath(os.path.join(HERE, '../../../bin'))
os.symlink(BINDIR, os.path.join(HOME, '.claude/bin'))
TRUSTED = os.path.join(HOME, 'trusted')
WT1, WT2 = os.path.join(HOME, 'wt1'), os.path.join(HOME, 'wt2')
WT3, WT4 = os.path.join(HOME, 'wt3'), os.path.join(HOME, 'wt4')
WT5 = os.path.join(HOME, 'wt5')
WT6 = os.path.join(HOME, 'wt6')
WT7 = os.path.join(HOME, 'wt7')
GONE = os.path.join(HOME, 'wt-removed')          # deliberately never created
CHILD = os.path.join(WT4, 'gone-child')          # ditto, but its PARENT survives
DEEP = os.path.join(WT4, 'gone', 'deeper')       # TWO missing levels; only WT4 survives
for d in (TRUSTED, WT1, WT2, WT3, WT4, WT5, WT6, WT7): os.makedirs(d)

SESSIONS = [
    ('aaaaaaa1', 'working', WT1,  'same name'),   # two live rows in one worktree,
    ('aaaaaaa2', 'blocked', WT1,  'same name'),   # sharing a name -> "match on <short>"
    ('aaaaaaa3', 'working', WT2,  'solo session'),# the only row in its worktree
    ('aaaaaaa4', 'working', GONE, 'orphan'),      # worktree removed under a live session
    ('aaaaaaa5', 'working', CHILD,'orphan, live parent'),  # widens to WT4, not $TRUSTED
    ('aaaaaaa6', 'working', WT3,  'sixth session'),# two rows, DISTINCT names: the
    ('aaaaaaa7', 'blocked', WT3,  'seventh session'),# ordinary "pick this name" branch
    ('aaaaaaa8', 'working', WT5,  'an old one'),   # 2h stale: the age cutoff's only case
    ('aaaaaaa9', 'working', DEEP, 'orphan, deep'), # >=2 missing levels: the walk must LOOP
    # Round 6: the ONLY row inside `fleet who`'s own 6-hour window. Every other row is
    # under 2h or over 24h, so `who`'s cutoff sat between two fixture gaps and could be
    # moved anywhere from 121 to 1999 minutes without a failing test -- it was pinned
    # by nothing at all. At 200m it is inside 360 and outside 60, so tightening the
    # window drops it and widening it past 2000 picks up ANCIENT, which the assertions
    # below check for by name. It is rostered AND socketed, so it lands in the list of
    # sessions you can reply to -- the half of `who` that matters -- and gives that
    # list a second row to sort.
    ('aaaaaad1', 'working', WT7,  'a mid-window one'),
]
# Ages, in minutes, stamped onto each state.json. Without them every row is 0m old,
# every cutoff admits everything, and `fleet open`'s --max-age is unobservable: it
# could be 1440 or 1 and no assertion would move. They also make the ROSTER ORDER
# discriminating -- aaaaaaa1 is the OLDEST reachable row, so a sort that ignores
# reachability and one that ignores age give different answers.
AGES = {'aaaaaaa1': 30, 'aaaaaaa2': 5, 'aaaaaaa3': 1, 'aaaaaaa4': 20,
        'aaaaaaa5': 10, 'aaaaaaa6': 3, 'aaaaaaa7': 2, 'aaaaaaa8': 120, 'aaaaaaa9': 15,
        'aaaaaad1': 200}
# Round 6: exactly ONE fixture session carries a real transcript. Both read-only
# branches the panel opens refuse a session without one -- `fleet-tail` exits 1 with
# "transcript missing", `fleet-watch` skips the row and reports an empty fleet -- so
# with no transcript anywhere in the fixture the READ pane and the WATCH pane would
# both have painted an error that an assertion on "does it start at all" happily
# passes. One and only one: it makes the discovery FILTER observable (`fleet 1`, not
# `fleet 11`), which is the half of watch that decides what you see.
TRANSCRIPT_OF = 'aaaaaaa3'
# ...and a SECOND row carrying the same transcript, 120 minutes old. `fleet-watch`
# discovers a session when it is active AND young AND has a transcript; with only one
# transcript in the fixture, the "exactly one pane joins" assertion was pinned by the
# transcript alone and the 60-minute window could be widened to anything. This row is
# excluded by AGE only, so widening it makes a second pane join and the count fail.
STALE_TRANSCRIPT_OF = 'aaaaaaa8'
TRANSCRIPT = os.path.join(HOME, 'transcript-%s.jsonl' % TRANSCRIPT_OF)
# FOURTEEN renderable entries, not four. Both viewers take a back-scroll count and both
# have a DEFAULT for it -- tail 12, watch 4 -- and with only four entries in the file
# neither default could be pinned from above: 4 and 8 paint the same screen when there
# are four things to paint, and so do 12 and 100. Ten older entries put a row on the far
# side of every window, so widening one is as visible as narrowing it.
ENTRIES = ['ZULU-%02d' % (_n + 1) for _n in range(10)] + \
          ['ALPHA-ONE', 'BRAVO-TWO', 'CHARLIE-THREE', 'DELTA-FOUR']
with open(TRANSCRIPT, 'w') as fh:
    for _i, _text in enumerate(ENTRIES):
        fh.write(json.dumps({'type': 'assistant',
                             'timestamp': '2026-08-21T10:%02d:00.000Z' % _i,
                             'message': {'content': [{'type': 'text', 'text': _text}]}}) + '\n')
    # Not renderable: the renderer takes assistant/user entries only. If it ever
    # stopped filtering, this line would print and the READ assertions below would
    # see a fifth entry where they counted four.
    fh.write(json.dumps({'type': 'system', 'subtype': 'NEVER-RENDER'}) + '\n')

for short, st, cwd, name in SESSIONS:
    d = os.path.join(HOME, '.claude/jobs', short)
    os.makedirs(d)
    f = os.path.join(d, 'state.json')
    rec = {'state': st, 'cwd': cwd, 'name': name}
    if short in (TRANSCRIPT_OF, STALE_TRANSCRIPT_OF):
        rec['linkScanPath'] = TRANSCRIPT
    with open(f, 'w') as fh:
        json.dump(rec, fh)
    old = time.time() - AGES[short] * 60
    os.utime(f, (old, old))

# Round 4: a real machine ALWAYS carries recently-finished jobs -- measured live,
# eight done/failed jobs under an hour old, still rostered, some with sockets. A
# fixture of only-active rows made the state filter unobservable: adding 'done' and
# 'failed' to it changed nothing any test could see. These two are young, in the
# daemon roster AND have sockets, so ONLY the state filter can exclude them.
INACTIVE = [('aaaaaab1', 'done',   WT2, 'finished job', 2),
            ('aaaaaab2', 'failed', WT3, 'crashed job',  4)]
for short, st, cwd, name, age in INACTIVE:
    d = os.path.join(HOME, '.claude/jobs', short)
    os.makedirs(d)
    f = os.path.join(d, 'state.json')
    with open(f, 'w') as fh:
        json.dump({'state': st, 'cwd': cwd, 'name': name}, fh)
    old = time.time() - age * 60
    os.utime(f, (old, old))

# Round 5: one row OLDER than `fleet open`'s own 1440-minute default. Every other
# fixture row is younger than that, so a cap that clamped the caller's --max-age back
# to the default was invisible -- the widest case in the suite asked for 4320 minutes
# on a 120-minute row, which the default admits anyway. It is deliberately NOT in
# SESSIONS: every roster assertion above asks for --max-age 1440, which excludes it,
# so the counts and orderings they pin are untouched.
ANCIENT = ('aaaaaac1', 'working', WT6, 'an ancient one', 2000)
_d = os.path.join(HOME, '.claude/jobs', ANCIENT[0])
os.makedirs(_d)
with open(os.path.join(_d, 'state.json'), 'w') as fh:
    json.dump({'state': ANCIENT[1], 'cwd': ANCIENT[2], 'name': ANCIENT[3]}, fh)
_old = time.time() - ANCIENT[4] * 60
os.utime(os.path.join(_d, 'state.json'), (_old, _old))

# REACHABILITY is (listed in the daemon roster) AND (its socket exists). Both inputs
# are fabricated here: the roster lives under $HOME, and the socket directory is named
# by $CLAUDE_DAEMON_RV_DIR. Before that override existed the real daemon owned the
# second half, every fabricated row came back ok=0, and INVERTING the rule changed
# nothing any test could see.
os.makedirs(os.path.join(HOME, '.claude/daemon'))
with open(os.path.join(HOME, '.claude/daemon/roster.json'), 'w') as fh:
    # aaaaaaa1 and aaaaaaa3 are both in the roster; only aaaaaaa1 still has a socket,
    # so the AND is observable -- an `||` would make aaaaaaa3 reachable too.
    json.dump({'workers': {'aaaaaaa1': {'id': 'aaaaaaa1'}, 'aaaaaaa3': {'id': 'aaaaaaa3'},
                           'aaaaaab1': {'id': 'aaaaaab1'}, 'aaaaaab2': {'id': 'aaaaaab2'},
                           'aaaaaad1': {'id': 'aaaaaad1'}}}, fh)
RV = os.path.join(HOME, 'rv')
os.makedirs(RV)
# Round 5: these are REAL AF_UNIX sockets, not empty regular files. A daemon socket
# is a socket, and the fixture's job is to make the WRONG implementation give a
# different answer: with regular files, `existsSync(s)` and `existsSync(s) &&
# statSync(s).isFile()` agree on every row in the fixture, so the socket half of the
# reachability rule was pinned only against a MISSING file. `bind` also fails loudly
# if the temp path is too long for sun_path, which a silently-empty roster would not.
_socks = []
def mksock(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(path)
    except OSError as e:
        sys.exit('fleet-open-pty: could not bind %s (%s). The fixture needs a real '
                 'socket here; a regular file would make the socket rule unobservable.'
                 % (path, e))
    s.listen(1)
    _socks.append(s)

mksock(os.path.join(RV, 'aaaaaaa1.sock'))
# Round 4: a socket whose id is NOT in the roster -- the fourth quadrant. Without
# it, `ok = sock ? 1 : 0` (reachability minus the roster half) was byte-identical
# to the real AND across the whole fixture. aaaaaaa6 must stay unreachable.
mksock(os.path.join(RV, 'aaaaaaa6.sock'))
# The INACTIVE pair get sockets too: reachability must never resurrect them.
mksock(os.path.join(RV, 'aaaaaab1.sock'))
mksock(os.path.join(RV, 'aaaaaab2.sock'))
# Round 6: the mid-window row is REACHABLE, which is what makes it a `fleet who`
# case at all -- a row you can actually reply to, aged inside a window nothing
# pinned. It is also the fixture's SECOND reachable row: with only one, `who`'s
# `live.sort((a,b)=>a.mins-b.mins)` had a single element to order and could be
# deleted or inverted with nothing to show for it.
mksock(os.path.join(RV, 'aaaaaad1.sock'))
REACHABLE = ['aaaaaaa1', 'aaaaaad1']

ENV = dict(os.environ)
ENV.update(HOME=HOME, CLAUDE_FLEET_DIR=TRUSTED, TERM='dumb', CLAUDE_DAEMON_RV_DIR=RV,
           PATH=HERE + os.pathsep + os.environ.get('PATH', ''))
# `claude` on PATH must be OUR fake, unconditionally. `os.path.exists` follows the
# link, so a stale one left by a killed run reads as absent and the symlink() below
# would raise -- and a stale link pointing at the REAL claude would open a real
# session. Replace it outright.
LINK = os.path.join(HERE, 'claude')
if os.path.lexists(LINK): os.unlink(LINK)
os.symlink(os.path.join(HERE, 'fake-claude'), LINK)

# Round 5: the same two binaries, installed where `resolve` LOOKS rather than on
# PATH. A VS Code terminal profile runs with launchd's bare PATH and no shell, which
# is the entire reason `resolve` walks explicit locations at all -- and with HERE on
# PATH the fixture never exercised that walk: `command -v claude` found the fake on
# the first line of the ladder every time. BARE_ENV below removes that crutch.
LOCALBIN = os.path.join(HOME, '.local/bin')
os.makedirs(LOCALBIN)
os.symlink(os.path.join(HERE, 'fake-claude'), os.path.join(LOCALBIN, 'claude'))
_node = shutil.which('node')
if not _node:
    sys.exit('fleet-open-pty: no node on PATH to link into the fixture $HOME.')
os.symlink(os.path.realpath(_node), os.path.join(LOCALBIN, 'node'))
# Exactly what launchd hands a GUI-launched process: four directories, no ~/.local/bin,
# no /opt/homebrew/bin. Anything the script needs beyond these it must resolve itself.
BARE_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
BARE_ENV = dict(ENV, PATH=BARE_PATH)

# ------------------------------------------------- the fixture is not a shell script
# Round 6. Every assertion below runs `claude` through this fake, so what the fake CAN
# be started by decides what the suite can catch. While it was Bash, `exec /bin/bash
# "$CLAUDE" agents --cwd "$cwd"` preserved the argv, the cwd, both TTYs and the
# sentinel and passed all 74 -- and the real ~/.local/bin/claude is a Mach-O arm64
# binary that Bash cannot start at all, so every live pane would have died with the
# suite green. Pin the property, not the incident: the fake must be startable ONLY the
# way the real binary is, so that a shell in front of it is visible as a failure.
FAKE = os.path.join(HERE, 'fake-claude')
with open(FAKE, 'rb') as fh:
    SHEBANG = fh.readline().decode('utf8', 'replace').strip()
t('the fake claude is not a shell script (a shell fixture hides a shell wrapper)',
  SHEBANG.startswith('#!') and os.path.basename(SHEBANG.split()[0].lstrip('#!')) not in
  ('sh', 'bash', 'zsh', 'dash', 'ksh', 'env'), SHEBANG)
_probe = subprocess.run(['/bin/bash', FAKE, 'agents'], capture_output=True, timeout=30,
                        env=dict(ENV, FAKE_ARGV=os.path.join(HOME, 'wrap.argv'),
                                 FAKE_PROBE=os.path.join(HOME, 'wrap.probe')))
t('...so putting a shell in front of it FAILS instead of passing quietly',
  not os.path.exists(os.path.join(HOME, 'wrap.argv')),
  'a shell ran the fixture to completion: rc=%s' % _probe.returncode)

roster = subprocess.run([FLEET, 'ids', '--max-age', '1440'], capture_output=True,
                        text=True, env=ENV).stdout.strip().split('\n')
t('the fixture roster holds exactly the fabricated sessions',
  len([r for r in roster if r]) == len(SESSIONS), roster)

# ------------------------------------------------------------------ the driver
def run_open(short, sentinel, extra=(), base_env=None):
    """Launch `fleet open <short> [extra...]` on a pty; return (screen, argv, probe)."""
    return run_fleet(['open', short] + list(extra), sentinel, base_env)

def run_fleet(args, sentinel, base_env=None):
    """Launch `fleet <args...>` on a pty; return (screen, argv, probe).

    `base_env` defaults to the fixture ENV; pass BARE_ENV to drive the launchd PATH.

    Round 6: this takes the whole argv because `fleet write` -- the OTHER exec of
    `claude`, and the one the VS Code button runs first -- had no pty case at all. It
    was reachable only through the extension's stub, which cannot observe a TTY.
    """
    tmp = tempfile.mkdtemp()
    argv_f, probe_f = os.path.join(tmp, 'argv'), os.path.join(tmp, 'probe')
    env = dict(base_env or ENV, FAKE_ARGV=argv_f, FAKE_PROBE=probe_f)
    pid, fd = pty.fork()
    if pid == 0:
        # chdir to / so a `cd` the script does NOT do shows up as cwd=/ rather than as
        # a coincidence. On any exec failure _exit immediately: a returning child would
        # go on to run the rest of THIS FILE, forking a pty per case, per child.
        try:
            os.chdir('/')
            os.execve(FLEET, [FLEET] + list(args), env)
        finally:
            os._exit(127)
    screen, sent, acked, gone, t0 = b'', False, False, False, time.time()
    while time.time() - t0 < 30:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: chunk = os.read(fd, 65536)
            except OSError: break
            if not chunk: break
            screen += chunk
        if not sent and b'FAKE-READY' in screen:
            # You type. If `fleet open` handed the child anything other than this pty,
            # these bytes go nowhere and the child records echo=<none>.
            os.write(fd, sentinel.encode() + b'\n'); sent = True
        if os.path.exists(probe_f) and b'echo=' in open(probe_f, 'rb').read(): break
        # A failure inside a VS Code pane must not FLASH and vanish, so `die` waits for
        # a keypress whenever it holds a terminal. Nobody is watching here, so press it
        # -- and note that this is the only reason the loop ever saw a dying child: an
        # unanswered prompt cost the full 30s timeout per case.
        if not acked and b'press enter to close' in screen:
            os.write(fd, b'\n'); acked = True
        # A pty master on macOS does NOT report EOF when its slave closes: it simply
        # goes quiet. So a case where `fleet open` DIES -- an id the cutoff excludes,
        # a bad argument -- has no output-side end condition at all, and each one cost
        # the full 30s timeout (the suite went 6s -> 38s the moment such a case was
        # added). Ask the child instead, and drain once more before leaving.
        if not gone:
            try: gone = os.waitpid(pid, os.WNOHANG)[0] == pid
            except ChildProcessError: gone = True
        if gone and not r: break
    # Close the master BEFORE reaping. The child is the session leader of this pty, and
    # macOS holds such a process in state `E` -- killed, not yet reaped -- for as long as
    # the master is open with output still queued. `waitpid` then blocks forever. Killing,
    # closing, then reaping takes the same path in milliseconds.
    if not gone:
        os.kill(pid, signal.SIGKILL); os.close(fd); os.waitpid(pid, 0)
    else:
        os.close(fd)
    argv = open(argv_f).read().split('\n')[:-1] if os.path.exists(argv_f) else None
    probe = dict(l.split('=', 1) for l in open(probe_f).read().strip().split('\n')
                 if '=' in l) if os.path.exists(probe_f) else {}
    return re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', screen.decode('utf8', 'replace')), argv, probe

def run_live(args, needle, base_env=None, seconds=25):
    """Launch `fleet <args...>` on a pty, read until `needle` is on screen, then kill.

    Round 6. The two read-only branches are LIVE VIEWS: they paint and then follow
    forever, and neither execs `claude` at all, so the fake's FAKE-READY handshake --
    the end condition every other case here uses -- never arrives. The screen is the
    end condition instead. A branch that dies immediately (the `exec /usr/bin/false`
    mutant) is detected by waitpid rather than by waiting out the timeout.

    Returns (screen, argv, exited). `argv` is the fake claude's recorded argv and MUST
    be None for a read-only pane: these panes are read-only by construction, and a
    regression that opened a session behind one costs ~1 GB and real tokens.
    """
    tmp = tempfile.mkdtemp()
    argv_f, probe_f = os.path.join(tmp, 'argv'), os.path.join(tmp, 'probe')
    env = dict(base_env or ENV, FAKE_ARGV=argv_f, FAKE_PROBE=probe_f)
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.chdir('/')
            os.execve(FLEET, [FLEET] + list(args), env)
        finally:
            os._exit(127)
    screen, gone, t0 = b'', False, time.time()
    while time.time() - t0 < seconds:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try: chunk = os.read(fd, 65536)
            except OSError: break
            if not chunk: break
            screen += chunk
        if needle.encode() in re.sub(rb'\x1b\[[0-9;]*[A-Za-z]', b'', screen): break
        if not gone:
            try: gone = os.waitpid(pid, os.WNOHANG)[0] == pid
            except ChildProcessError: gone = True
        if gone and not r: break
    # Ask ONE more time before concluding it is alive. A child that dies at once makes
    # the master raise EIO, and that arm `break`s straight past the waitpid probe above
    # -- so `gone` stays False for the very case this flag exists to catch.
    if not gone:
        try: gone = os.waitpid(pid, os.WNOHANG)[0] == pid
        except ChildProcessError: gone = True
    if not gone:
        # It is still following, which is what a live view is supposed to do. SIGKILL,
        # not SIGINT: the handler prints a detach line and we would then race it.
        os.kill(pid, signal.SIGKILL); os.close(fd); os.waitpid(pid, 0)
    else:
        os.close(fd)
    argv = open(argv_f).read().split('\n')[:-1] if os.path.exists(argv_f) else None
    return (re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', screen.decode('utf8', 'replace')),
            argv, gone)

def check(short, cwd, sentinel):
    screen, argv, probe = run_open(short, sentinel)
    if '-v' in sys.argv:
        print('---- pane for %s ----\n%s\n----' % (short, screen.rstrip()))
    t('%s: execs EXACTLY `agents --cwd <cwd>`' % short,
      argv == ['agents', '--cwd', cwd], 'got %r, wanted %r' % (argv, ['agents', '--cwd', cwd]))
    # realpath BOTH sides: the fixture reports its PHYSICAL cwd, and on macOS the
    # temp root is /var -> /private/var, so a literal compare fails on a pane that
    # chdir'd exactly where it was told. The fixture used to echo Bash's logical $PWD,
    # which agreed with the fixture path but only because the shell carried it -- a
    # process exec'd without a shell has no $PWD to inherit, so that comparison was
    # measuring the harness. Symlink aliasing is not the property under test; landing
    # in the right directory is, and a pane that chdirs somewhere else still differs.
    t('%s: chdirs into that same directory' % short,
      probe.get('cwd') and os.path.realpath(probe['cwd']) == os.path.realpath(cwd),
      'got %r, wanted %r' % (probe.get('cwd'), cwd))
    t('%s: the pane keeps a real TTY on stdin, so you can type' % short,
      probe.get('stdin_tty') == '1', probe)
    t('%s: ...and on stdout, so the picker can paint' % short,
      probe.get('stdout_tty') == '1', probe)
    t('%s: fleet types NOTHING at the picker (no resume, nothing spent)' % short,
      probe.get('early') == '', 'fleet sent %r before the picker was ready' % probe.get('early'))
    t('%s: a keystroke reaches the session process' % short,
      probe.get('echo') == sentinel, 'got %r, wanted %r' % (probe.get('echo'), sentinel))
    return screen

# ------------------------------------------------------------------- the cases
scr = check('aaaaaaa3', WT2, 'SENTINEL-solo')
t('a lone row says so, and says which key opens it',
  'the only live row' in scr and 'enter opens' in scr, scr)
t('...and names the session, so the pane is identifiable',
  'solo session' in scr, scr)
t('an unreachable session warns that a reply may not land',
  'not reachable' in scr, scr)

scr = check('aaaaaaa1', WT1, 'SENTINEL-dup')
t('a REACHABLE session carries no not-reachable warning',
  'not reachable' not in scr, scr)
t('two rows sharing a name are counted, and disambiguated by SHORT ID',
  '2 live rows, 2 share this name' in scr and 'match on aaaaaaa1' in scr, scr)
t('...and it does NOT claim to be the only live row',
  'the only live row' not in scr, scr)

scr = check('aaaaaaa4', TRUSTED, 'SENTINEL-gone')
t('a removed worktree admits the picker was NOT narrowed',
  'picker NOT narrowed' in scr and 'find aaaaaaa4 in the list' in scr, scr)
t('...and never claims to be the only live row',
  'the only live row' not in scr, scr)

# A worktree whose PARENT survives widens to the parent, not all the way out to
# $TRUSTED: `--cwd <parent>` still admits this session and lists a fraction of the
# rows. $HOME is refused as an ancestor (aaaaaaa4's parent IS $HOME) because
# `claude agents` gates on folder trust and would show every session on the machine.
scr = check('aaaaaaa5', WT4, 'SENTINEL-child')
t('a removed worktree widens to its nearest surviving PARENT, not to $TRUSTED',
  'wt4' in scr, scr)
t('...and still says the picker is not narrowed, because it is not this folder',
  'picker NOT narrowed' in scr and 'find aaaaaaa5 in the list' in scr, scr)

# Two MISSING levels (wt4/gone/deeper): the ancestor walk must LOOP, not step once.
# A single-step walk lands on wt4/gone -- which does not exist either -- and dies.
scr = check('aaaaaaa9', WT4, 'SENTINEL-deep')
t('a cwd MULTIPLE removed levels deep widens to the nearest SURVIVING ancestor',
  'wt4' in scr, scr)
t('...and that pane too admits the picker is not narrowed',
  'picker NOT narrowed' in scr and 'find aaaaaaa9 in the list' in scr, scr)

# The ordinary case, previously unexercised: several rows here, this name unique.
scr = check('aaaaaaa6', WT3, 'SENTINEL-sixth')
t('several rows with distinct names says how many, and to pick by NAME',
  '2 live rows - pick this name' in scr.replace('\u2014', '-'), scr)
t('...and does not fall through to the match-on-id wording',
  'share this name' not in scr and 'the only live row' not in scr, scr)

# ---------------------------------------------------- the roster CONTRACT itself
# `fleet ids` is the one enumeration every surface builds on, and until now only its
# COLUMNS were pinned. These three rules -- which rows, in what order, how many --
# were all invertible without a failing test.
def ids(*args):
    r = subprocess.run([FLEET, 'ids'] + list(args), capture_output=True, text=True, env=ENV)
    return [l.split('\t') for l in r.stdout.strip().split('\n') if l]

full = ids('--max-age', '1440')
t('--reachable returns EXACTLY the sessions with a roster entry AND a socket',
  [r[0] for r in ids('--max-age', '1440', '--reachable')] == REACHABLE,
  [r[0] for r in ids('--max-age', '1440', '--reachable')])
t('...and the unfiltered roster marks the same ones, and only those, with a 1',
  [r[0] for r in full if r[2] == '1'] == REACHABLE, [(r[0], r[2]) for r in full])
t('the roster is reachable-first, then youngest-first',
  [r[0] for r in full] == ['aaaaaaa1', 'aaaaaad1', 'aaaaaaa3', 'aaaaaaa7',
                           'aaaaaaa6', 'aaaaaaa2', 'aaaaaaa5', 'aaaaaaa9',
                           'aaaaaaa4', 'aaaaaaa8'],
  [(r[0], r[2], r[3]) for r in full])
t('--max keeps the FRESHEST n of that order, not the first n it happened to read',
  [r[0] for r in ids('--max-age', '1440', '--max', '3')] == ['aaaaaaa1', 'aaaaaad1', 'aaaaaaa3'],
  [r[0] for r in ids('--max-age', '1440', '--max', '3')])
t('--max-age drops the stale rows, and only those',
  [r[0] for r in ids('--max-age', '60')]
  == [r[0] for r in full if r[0] not in ('aaaaaaa8', 'aaaaaad1')],
  [r[0] for r in ids('--max-age', '60')])
queried = [full,
           ids('--max-age', '1440', '--reachable'),
           ids('--max-age', '1440', '--max', '3'),
           ids('--max-age', '60')]
t('recently-finished done/failed jobs never appear, however the roster is asked',
  all(not r[0].startswith('aaaaaab') for q in queried for r in q),
  [r[0] for q in queried for r in q if r[0].startswith('aaaaaab')])
t('a socket alone does not make a session reachable: the roster half is REQUIRED',
  next(r[2] for r in full if r[0] == 'aaaaaaa6') == '0'
  and 'aaaaaaa6' not in [r[0] for r in ids('--max-age', '1440', '--reachable')],
  [(r[0], r[2]) for r in full])

# ------------------------------------------------ argument hygiene (round 4)
# The VS Code setting is user-typed JSON. Before the digit guard, `--max-age 1.5`
# turned the age compare into NaN-arithmetic that is false for EVERY row -- a
# malformed cutoff silently admitted the whole machine.
r = subprocess.run([FLEET, 'ids', '--max-age', '1.5'], capture_output=True, text=True, env=ENV)
t('ids rejects a fractional --max-age loudly',
  r.returncode == 2 and 'whole number' in r.stderr, (r.returncode, r.stderr))
r = subprocess.run([FLEET, 'ids', '--max-age', 'abc'], capture_output=True, text=True, env=ENV)
t('ids rejects a non-numeric --max-age (NaN used to admit EVERY row)',
  r.returncode == 2 and 'whole number' in r.stderr, (r.returncode, r.stderr))
r = subprocess.run([FLEET, 'ids', '--max', '2.5'], capture_output=True, text=True, env=ENV)
t('ids applies the same rule to --max',
  r.returncode == 2 and 'whole number' in r.stderr, (r.returncode, r.stderr))
scr, argv, _ = run_open('aaaaaaa1', 'SENTINEL-frac', ('--max-age', '1.5'))
# Pinned to the `fleet open:` prefix: the ids guard downstream would also say
# "whole number", so the prefix is what proves OPEN refused before any roster read.
t('open rejects a fractional --max-age itself, before any roster read',
  argv is None and 'fleet open: --max-age needs a whole number' in scr, (argv, scr))
t('...and that error also waits instead of flashing',
  'press enter to close' in scr, scr)

# ------------------------------------------------- the cutoff `fleet open` uses
# The VS Code pane passes its own --max-age so the two cannot disagree. Both halves
# need a row that is old enough to be excluded by one cutoff and not the other --
# with every fixture row 0m old, `open_maxage=1` passed the entire suite.
scr, argv, _ = run_open('aaaaaaa8', 'SENTINEL-old')
t('a 2h-old session opens under the default cutoff',
  argv == ['agents', '--cwd', WT5], argv)
scr, argv, _ = run_open('aaaaaaa8', 'SENTINEL-old', ('--max-age', '60'))
t('...and a caller passing a tighter cutoff is told the row is not there',
  argv is None and "no live session 'aaaaaaa8'" in scr, (argv, scr))
t('...rather than opening the picker anyway',
  'enter opens' not in scr, scr)
t('...and the pane WAITS on that error instead of flashing it and closing',
  'press enter to close' in scr, scr)
scr, argv, _ = run_open('aaaaaaa8', 'SENTINEL-old', ('--max-age', '4320'))
t('a cutoff WIDER than the old default still opens it',
  argv == ['agents', '--cwd', WT5], argv)

# ------------------------------------------ round 5: the launchd PATH (no shell)
# A VS Code terminal profile execs this script with NO shell, so ~/.zshrc never runs
# and PATH is launchd's bare four directories -- neither node nor claude is on it.
# That is why `resolve` walks explicit locations, and with HERE on PATH the whole
# ladder was dead weight: `command -v claude` answered first, every time. Here the
# fake claude and a node live at ~/.local/bin (the first explicit candidate) and PATH
# carries neither, so the walk is the ONLY way either binary is found.
scr, argv, _ = run_open('aaaaaaa1', 'SENTINEL-bare', base_env=BARE_ENV)
t('with launchd\'s bare PATH, open still finds claude and node',
  argv == ['agents', '--cwd', WT1], (argv, scr[-400:]))
r = subprocess.run([FLEET, 'ids', '--max-age', '1440'], capture_output=True,
                   text=True, env=BARE_ENV)
t('...and so does the roster read the pane makes first',
  len([l for l in r.stdout.strip().split('\n') if l]) == len(SESSIONS),
  (r.returncode, r.stdout, r.stderr))

# ------------------------------------------ round 5: reachability in `fleet who`
# `who` carries its OWN copy of the socket predicate -- the same expression as the
# one in `ids`, at a second site. `ids` is pinned by --reachable above; nothing read
# what `who` decided, so the two could disagree and only `who` would be wrong.
r = subprocess.run([FLEET, 'who'], capture_output=True, text=True, env=ENV)
t('`fleet who` counts exactly the reachable sessions as replyable',
  'CAN receive a reply (%d):' % len(REACHABLE) in r.stdout, r.stdout)
t('...and they are the SAME sessions `ids --reachable` names, youngest first',
  re.search(r'CAN receive a reply \(2\):\n  [●○] same name .*\n  [●○] a mid-window one ',
            r.stdout) is not None, r.stdout)
# Round 6: `who` carries its OWN age cutoff, 360 minutes, written nowhere else and
# pinned by nothing -- every fixture row was under 2h or over 33h, so the number could
# have been anything from 121 to 1999 and this suite stayed green. Both sides, one run:
t('`fleet who` shows a session inside its 6-hour window that a 60m cutoff would drop',
  'a mid-window one' in r.stdout, r.stdout)
t('...and still hides one past that window, so it is a window and not just a floor',
  ANCIENT[3] not in r.stdout, r.stdout)

# --------------------------------- round 5: a cutoff WIDER than open's own default
# `fleet open` defaults to 1440 minutes. Every other fixture row is younger than
# that, so the "wider cutoff" case above asked for 4320 on a 120-minute row -- a cap
# clamping the caller back to 1440 admitted it just the same. This row can only be
# reached by a cutoff that is passed THROUGH.
scr, argv, _ = run_open(ANCIENT[0], 'SENTINEL-ancient', ('--max-age', '4320'))
t('a 33h-old session opens under a cutoff wide enough to include it',
  argv == ['agents', '--cwd', WT6], (argv, scr[-400:]))
scr, argv, _ = run_open(ANCIENT[0], 'SENTINEL-ancient')
t('...and the DEFAULT cutoff still excludes it, so the flag is what did it',
  argv is None and "no live session '%s'" % ANCIENT[0] in scr, (argv, scr[-400:]))

# ------------------------------ round 6: one name sanitizer, not one per surface
# `ids` stripped tabs and newlines out of a session name; `who` stripped nothing. Both
# turn the same state.json field into a LABEL, and `who` prints one row per line, so a
# name carrying a newline broke a single session into two rows -- one of them a bullet
# with no session behind it. This is the shape round 5 found in the socket predicate
# (written twice, tested once), caught at a second site. Both now read one CLEAN.
#
# Driven against its OWN $HOME rather than the fixture roster above: a hostile name in
# SESSIONS would ride through every count, order and pane assertion in this file, and
# an assertion that has to be re-derived every time the fixture grows is one nobody
# updates. Here the expected output is exactly one row, whatever `who` does to it.
# MUTANT: dropping CLEAN from either program, or the /\s+/ collapse inside it.
HOME2 = tempfile.mkdtemp(prefix='fleet-pty-names-')
os.makedirs(os.path.join(HOME2, '.claude'))
os.symlink(BINDIR, os.path.join(HOME2, '.claude/bin'))
_d2 = os.path.join(HOME2, '.claude/jobs', 'aaaaaae1')
os.makedirs(_d2)
with open(os.path.join(_d2, 'state.json'), 'w') as fh:
    json.dump({'state': 'working', 'cwd': TRUSTED,
               'name': 'first line\nsecond line\tand a tab',
               'detail': 'detail line\nkeeps going'}, fh)
r = subprocess.run([FLEET, 'who'], capture_output=True, text=True,
                   env=dict(ENV, HOME=HOME2))
# Everything before the legend, which uses the same bullets to explain them.
_rows_part = r.stdout.split('● waiting on you')[0]
_bullets = [l for l in _rows_part.split('\n') if re.match(r'^  [●○✗] ', l)]
# Counting bullets alone is not enough: a raw newline puts the tail of the name on a
# line of its OWN, which carries no bullet, so the count stays 1 while the display has
# grown a row with no session behind it. Every printed line must be a bullet or a
# known header -- an orphan line IS the defect.
_orphans = [l for l in _rows_part.split('\n') if l.strip()
            and not re.match(r'^  [●○✗] ', l)
            and not re.match(r'^(CAN receive|listed as needing|\(roster unreadable)', l)]
t('a name carrying a newline stays ONE row in `fleet who`',
  len(_bullets) == 1 and not _orphans, (_orphans, r.stdout))
t('...with the line breaks and tabs collapsed, not printed raw',
  'first line second line and a tab' in r.stdout, r.stdout)
t('...and the detail column too, which is on the same line',
  'detail line keeps going' in r.stdout, r.stdout)
t('...and `fleet ids` agrees, field-for-field, from the same state file',
  subprocess.run([FLEET, 'ids'], capture_output=True, text=True,
                 env=dict(ENV, HOME=HOME2)).stdout.strip().split('\t')[-1]
  == 'first line second line and a tab',
  subprocess.run([FLEET, 'ids'], capture_output=True, text=True,
                 env=dict(ENV, HOME=HOME2)).stdout)
shutil.rmtree(HOME2, ignore_errors=True)

# ---------------------------------------------------------------------------
# ...and the INSTANCE the correctness lens actually reported, which the three tests
# above do not reach: a name made only of non-rendering characters. Newlines and tabs
# are visible damage -- they break the row apart, so any assertion about row shape
# catches them. U+200B/U+FEFF are not: they leave a name that is still TRUTHY, so it
# sails past the `raw && raw !== "?"` fallback and yields a pane label that is a status
# bullet followed by nothing. Fixing the class (one shared CLEAN) is what makes this
# work; pinning it is what stops the invisible half of CLEAN from being deleted while
# the newline half keeps every test above green.
# MUTANT: drop `[\u00ad\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]` from CLEAN.
# The two surfaces fall back DIFFERENTLY on purpose and both are asserted: `who` has no
# room for a path so it prints "?", while `ids` feeds terminal tab labels, where "?" on
# four tabs would be useless -- it names the worktree instead.
HOME3 = tempfile.mkdtemp(prefix='fleet-pty-invis-')
os.makedirs(os.path.join(HOME3, '.claude'))
os.symlink(BINDIR, os.path.join(HOME3, '.claude/bin'))
_d3 = os.path.join(HOME3, '.claude/jobs', 'aaaaaaf1')
os.makedirs(_d3)
_cwd3 = os.path.join(HOME3, 'work', 'shelf-widget')
os.makedirs(_cwd3)
with open(os.path.join(_d3, 'state.json'), 'w') as fh:
    json.dump({'state': 'working', 'cwd': _cwd3,
               'name': '\u200b\u200b\ufeff', 'detail': 'x'}, fh)
r = subprocess.run([FLEET, 'who'], capture_output=True, text=True,
                   env=dict(ENV, HOME=HOME3))
# Split at the legend first: it explains the bullets USING them, so it matches the
# row pattern -- the same trap the block above documents.
_invis_rows = [l for l in r.stdout.split('● waiting on you')[0].split('\n')
               if re.match(r'^  [●○✗] ', l)]
# U+200B is not whitespace to str.split(), so an unsanitised name would land here as
# itself -- the comparison discriminates instead of passing on a blank.
_invis_label = _invis_rows[0][4:].split()[0] if _invis_rows else '<no row>'
t('a name made only of invisible characters still prints a LABEL in `fleet who`',
  len(_invis_rows) == 1 and _invis_label == '?', (_invis_label, r.stdout))
t('...and `fleet ids` falls back to the worktree, as it does for a name that is absent',
  subprocess.run([FLEET, 'ids'], capture_output=True, text=True,
                 env=dict(ENV, HOME=HOME3)).stdout.strip().split('\t')[-1]
  == 'shelf-widget (unnamed)',
  subprocess.run([FLEET, 'ids'], capture_output=True, text=True,
                 env=dict(ENV, HOME=HOME3)).stdout)
shutil.rmtree(HOME3, ignore_errors=True)

# ------------------------------- round 6: an argument nobody understands is refused
# `fleet ids --reachble` printed the UNFILTERED roster and exited 0: the flags were
# picked out with indexOf and everything else silently dropped. `fleet open` refuses
# the same token, so two entry points disagreed about the same argv -- and the failure
# is silent in the direction that matters, since a typo'd filter answers with MORE
# sessions than asked for. `who`, `doctor` and `write` take no options at all and
# ignored whatever followed them.
# MUTANT: any of these branches accepting an extra argument again.
for _argv, _what in ((['ids', '--reachble'], 'a misspelt flag'),
                     (['ids', '--max-age', '60', '--reachabl'], 'a misspelt flag after a good one'),
                     (['ids', 'aaaaaaa1'], 'a session id where none is taken'),
                     (['who', '--reachable'], 'a flag `who` does not have'),
                     (['doctor', '--verbose'], 'a flag `doctor` does not have')):
    _r = subprocess.run([FLEET] + _argv, capture_output=True, text=True, env=ENV)
    t('`fleet %s` is refused: %s' % (' '.join(_argv), _what),
      _r.returncode == 2 and not _r.stdout.strip(),
      'rc=%s stdout=%r stderr=%r' % (_r.returncode, _r.stdout[:200], _r.stderr[:200]))
t('...and the canonical argv is still accepted, in any order',
  [x[0] for x in [l.split('\t') for l in subprocess.run(
      [FLEET, 'ids', '--reachable', '--max', '1', '--max-age', '1440'],
      capture_output=True, text=True, env=ENV).stdout.strip().split('\n') if l]] == REACHABLE[:1],
  REACHABLE)

# -------------------------------------- round 6: `fleet write`, the OTHER exec
# The button opens ONE pane per group running `fleet write`, and only then does the
# extension split off `fleet open` panes. Yet `write` had no pty case: `exec "$CLAUDE"
# agents` could be replaced with `/usr/bin/false` and all 76 assertions still passed,
# because every one of them drove `open`. The extension suite reaches `write` through a
# stub that records a command STRING -- it cannot see a TTY, a cwd, or whether the
# process it names even starts. Same six probes as `check()`, one argv shorter: `write`
# takes no --cwd, it cds into $TRUSTED and lets the picker show the whole fleet.
scr, argv, probe = run_fleet(['write'], 'SENTINEL-write')
t('`fleet write` execs EXACTLY `agents`, with no session id and no --cwd',
  argv == ['agents'], 'got %r' % (argv,))
t('...from inside $CLAUDE_FLEET_DIR, the trusted folder the picker needs',
  probe.get('cwd') and os.path.realpath(probe['cwd']) == os.path.realpath(TRUSTED),
  'got %r, wanted %r' % (probe.get('cwd'), TRUSTED))
t('...keeping a real TTY on stdin, so you can type into the picker',
  probe.get('stdin_tty') == '1', probe)
t('...and on stdout, so the picker can paint',
  probe.get('stdout_tty') == '1', probe)
t('...typing NOTHING at the picker itself (no resume, nothing spent)',
  probe.get('early') == '', 'fleet write sent %r' % probe.get('early'))
t('...and a keystroke reaches the session process',
  probe.get('echo') == 'SENTINEL-write', 'got %r' % probe.get('echo'))
# The `w` alias is a second entry point to the same exec, and aliases drift.
_, argv_w, probe_w = run_fleet(['w'], 'SENTINEL-w')
t('the `w` alias runs the SAME thing, not a stale copy of it',
  argv_w == ['agents'] and probe_w.get('echo') == 'SENTINEL-w', (argv_w, probe_w))
# Round 6 correctness fix: `fleet write <id>` looked like "write to THAT session" and
# was accepted as decoration, opening the unfiltered picker instead.
r = subprocess.run([FLEET, 'write', 'aaaaaaa1'], capture_output=True, text=True, env=ENV)
t('`fleet write <id>` is refused, not silently ignored',
  r.returncode == 2 and 'takes no arguments' in r.stderr, (r.returncode, r.stderr))

# ------------------ round 6, self-found (CLASS I): `fleet ids`' own default window
# Every roster assertion above passes `--max-age` explicitly -- the extension always
# does -- so `let MAXAGE=60` inside `ids` was pinned by nothing: it could read 6 or 6000
# and no test would move. It is not dead code. It is what a human at a shell gets, and
# `fleet doctor` and the panes' own first read go through the same entry point.
# MUTANT: `158s#let MAXAGE=60#let MAXAGE=600#` (admits the 120m and 200m rows), or `=6`
# (drops the 30m, 20m, 15m and 10m ones).
_bare = [l.split('\t')[0] for l in subprocess.run(
    [FLEET, 'ids'], capture_output=True, text=True, env=ENV).stdout.strip().split('\n') if l]
_young = sorted(sh for sh, _st, _cwd, _n in SESSIONS if AGES[sh] < 60)
t('bare `fleet ids` applies its own 60-minute default, in both directions',
  sorted(_bare) == _young, 'got %r, wanted %r' % (sorted(_bare), _young))

# ------------------ round 6: the two READ-ONLY branches the panel opens
# CLASS H, of which R6-T03 (`fleet write` never executed) was the reported instance.
# The extension registers seven commands; each execs a branch of `bin/fleet`, and a
# branch no pty case drives can be replaced with `/usr/bin/false` while the whole
# suite stays green. `splitRead` runs `fleet <id> --back 14` and `watch` runs bare
# `fleet` -- the two branches at the very bottom of the case statement, reached
# through `need_node` rather than through `$CLAUDE`, and until now driven by nothing.
# Both are run under BARE_ENV on purpose: these are the panes a VS Code terminal
# PROFILE opens, which is the launchd-PATH case, and `node` is not on that PATH.
# MUTANT: `exec /usr/bin/false` on either branch; or dropping `--back`'s argument.
scr, argv, exited = run_live([TRANSCRIPT_OF, '--back', '2'], 'DELTA-FOUR', BARE_ENV)
# Assert the TAIL viewer's own header, not merely "the name is somewhere on screen".
# Crossing the two arms (mutant R6-T03e) starts fleet-watch instead, which prints the
# same name and the same short id inside its `┌─ joined` banner and, handed the same
# --back, back-paints the same two entries -- so every text these two viewers SHARE is
# unable to tell them apart. `<name>  <short>` on a line of its own belongs to one of
# them, and the fleet-wide header belongs to the other.
_lines = [l.rstrip() for l in scr.split('\n')]
t('`fleet <id> --back N` opens the TAIL viewer, with launchd\'s bare PATH',
  ('solo session  %s' % TRANSCRIPT_OF) in _lines
  and 'one terminal, every live session' not in scr and '┌─ joined' not in scr,
  scr[:400])
t('...headed by the worktree that session is running in',
  ('~/%s' % os.path.basename(WT2)) in _lines, scr[:400])
t('...renders the last N transcript entries, and only those',
  'DELTA-FOUR' in scr and 'CHARLIE-THREE' in scr
  and not any(x in scr for x in ENTRIES[:-2]), scr[:800])
t('...skipping entries that are not assistant/user turns',
  'DELTA-FOUR' in scr and 'NEVER-RENDER' not in scr, scr[:800])
t('...and stays a READ-ONLY pane: it opens no session and spends nothing',
  argv is None and 'DELTA-FOUR' in scr, 'the read pane exec\'d claude with %r' % (argv,))
t('...and it is still following when killed, not exited under us',
  not exited, 'the tail branch exited on its own')
# CLASS I again: with --back always passed, fleet-tail's own default was unobservable.
# The pane the panel opens passes 14, but `fleet <id>` from a shell does not. The
# transcript is deliberately LONGER than that default, so the assertion is "exactly the
# last twelve" rather than "at least the last four" -- narrowing the default drops a
# named entry, widening it admits one.
# MUTANTS: `./mutate.sh tail '17s#|| 12#|| 2#'` and the same line to `|| 100`.
scr_d, _, _ = run_live([TRANSCRIPT_OF], 'DELTA-FOUR', BARE_ENV)
t('...and with no --back at all it falls back to its own default of twelve, exactly',
  all(x in scr_d for x in ENTRIES[-12:]) and not any(x in scr_d for x in ENTRIES[:-12]),
  scr_d[:1200])

scr, argv, exited = run_live([], 'fleet 1', BARE_ENV)
t('bare `fleet` paints the watch header, with launchd\'s bare PATH',
  'one terminal, every live session' in scr, scr[:400])
t('...joins the session that has a transcript, by name',
  '┌─ joined %s' % TRANSCRIPT_OF in scr and 'solo session' in scr, scr[:800])
t('...and ONLY that one: the other rows are out of its window or have nothing to show',
  scr.count('┌─ joined') == 1 and 'fleet 1' in scr
  and STALE_TRANSCRIPT_OF not in scr, scr[:800])
# MUTANTS: `./mutate.sh watch '22s#--back., 4#--back", 2#'` (narrow) and `, 8` (widen).
t('...back-painting its default four entries, exactly -- not the tail branch\'s twelve',
  all(x in scr for x in ENTRIES[-4:]) and not any(x in scr for x in ENTRIES[:-4]),
  scr[:1200])
t('...opening no session either: the watch pane execs no claude',
  argv is None and 'DELTA-FOUR' in scr, 'the watch pane exec\'d claude with %r' % (argv,))
t('...and it keeps running, as a live view must',
  not exited, 'the watch branch exited on its own')

# ------------------------------------------------------------------- teardown
for _s in _socks:
    try: _s.close()
    except OSError: pass
shutil.rmtree(HOME, ignore_errors=True)
try: os.unlink(os.path.join(HERE, 'claude'))
except OSError: pass
# Counted, not computed: `n = 8 + 6 * 3` was a second place to remember, and a
# forgotten update there reports a total that does not match the lines above it.
print('\n  %d passed, %d failed  (writable path, deterministic fleet, fake claude)'
      % (ran[0] - len(fails), len(fails)))
sys.exit(1 if fails else 0)
