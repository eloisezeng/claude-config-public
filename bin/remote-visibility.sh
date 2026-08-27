#!/usr/bin/env bash
#
# Classify a git remote URL as exactly one of:
#
#   local    a path on this machine (no URL makes it world-readable)
#   private  a hosted repo that will NOT serve an unauthenticated reader
#   public   a hosted repo that WILL serve an unauthenticated reader
#   unknown  could not be determined
#
# Prints one of those words on stdout and a one-line reason on stderr. ALWAYS exits 0: the
# verdict is the output, not the status, so a caller cannot mistake "could not tell" for "fine".
# `unknown` is a refusal signal for the caller, never a pass -- the reason this exists is that a
# config repo full of memories, transcripts and hook wiring must never be pushed to a
# world-readable remote by a watcher nobody is looking at.
#
# The test is EMPIRICAL, not a guess from the URL: can an unauthenticated reader fetch the ref
# list? That is the same question a stranger holding the URL asks, and answering it needs no host
# API, no token, and no per-host special case beyond rewriting an ssh URL as the https one.
#
# Deliberately does NOT reset PATH. Its caller (sync.sh) already exports a PATH that covers
# launchd's and systemd's minimal environments, and resetting it here would also override a PATH
# a test set on purpose. If `git` cannot be found the answer is `unknown`, which fails closed.
set -u

url="${1:-}"
if [ -z "$url" ]; then
  echo unknown
  echo "remote-visibility: no remote url given" >&2
  exit 0
fi

# ----------------------------------------------------------------------------------------------
# A filesystem remote is not published BY URL. It may sit on a shared volume, but that is a
# different question from world-readable-over-the-internet and not one this script can answer.
case "$url" in
  /*|./*|../*|file://*)
    echo local
    echo "remote-visibility: $url is a path on this machine" >&2
    exit 0 ;;
esac

# ----------------------------------------------------------------------------------------------
# Normalise to an https URL that can be probed anonymously. An ssh remote always authenticates
# with a key, so it can never answer the "what does a stranger see?" question on its own.
probe=""
case "$url" in
  https://*|http://*)
    # Drop any userinfo: the probe must ask what a STRANGER sees, and a stranger has no
    # username. Leaving `someone@` in place makes git prompt for a password on a PUBLIC repo,
    # which -- with prompts disabled -- would be read as `private` and let the push through.
    # The `@` is only userinfo when it precedes the first `/`; a path may legitimately hold one.
    scheme="${url%%://*}"; rest="${url#*://}"
    case "${rest%%/*}" in *@*) rest="${rest#*@}" ;; esac
    probe="$scheme://$rest" ;;
  ssh://*)
    rest="${url#ssh://}"                           # [user@]host[:port]/owner/repo
    case "${rest%%/*}" in *@*) rest="${rest#*@}" ;; esac
    host="${rest%%/*}"; path="${rest#*/}"
    host="${host%%:*}"                             # drop any :port
    probe="https://$host/$path" ;;
  *@*:*)
    hostpath="${url#*@}"                           # scp-style: git@host:owner/repo.git
    probe="https://${hostpath%%:*}/${hostpath#*:}" ;;
  *)
    echo unknown
    echo "remote-visibility: unrecognised remote form: $url" >&2
    exit 0 ;;
esac

if ! command -v git >/dev/null 2>&1; then
  echo unknown
  echo "remote-visibility: git is not on PATH" >&2
  exit 0
fi

# ----------------------------------------------------------------------------------------------
# Probe with NO credentials of any kind. This is the whole test: a credential helper that
# silently authenticates would make a PRIVATE repo answer, and this script would then call it
# public. So global and system config (where the macOS keychain helper and any per-host token
# live) are replaced with /dev/null, the helper list is also reset on the command line for gits
# older than 2.32, and every interactive prompt is disabled so a missing credential fails
# immediately instead of hanging a launchd job forever.
#
# GIT_ASKPASS/SSH_ASKPASS are pointed at a path that cannot exist rather than at a real no-op
# binary: an inherited GUI askpass (the keychain one, on a desktop session) would otherwise
# supply the very credential this probe must not have, and /usr/bin/true is not portable to the
# Windows sibling of this script. An unrunnable askpass falls back to the terminal prompt, which
# GIT_TERMINAL_PROMPT=0 has already disabled.
out="$(GIT_TERMINAL_PROMPT=0 \
       GIT_ASKPASS=/nonexistent/askpass \
       SSH_ASKPASS=/nonexistent/askpass \
       GIT_CONFIG_GLOBAL=/dev/null \
       GIT_CONFIG_SYSTEM=/dev/null \
       git -c credential.helper= ls-remote "$probe" HEAD 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo public
  echo "remote-visibility: $probe served its refs to an unauthenticated reader" >&2
  exit 0
fi

# A refusal to serve an anonymous reader is the answer we want. Every host phrases it
# differently, and GitHub deliberately answers "not found" for a private repo so that the
# repo's existence is not itself leaked -- which is also what a genuine typo returns, so a
# mistyped remote reads as private here and then fails at push time on its own.
case "$out" in
  *"Authentication failed"*|*"could not read Username"*|*"terminal prompts disabled"*|\
  *"not found"*|*"Not Found"*|*"not exist"*|\
  *"Permission denied"*|*"access denied"*|*"403"*|*"401"*)
    echo private
    echo "remote-visibility: $probe refused an unauthenticated reader" >&2
    exit 0 ;;
esac

echo unknown
echo "remote-visibility: could not classify $probe: $(printf '%s' "$out" | head -1)" >&2
exit 0
