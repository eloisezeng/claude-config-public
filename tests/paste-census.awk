# paste-census.awk — every site that hands the operator a shell command, with a
# denominator. Round-5 correctness #11 was found at ONE site (`claude attach
# $SHORT`); the class is "a printed command carrying a value this script does not
# control", and it had three members, one of which LOOKED quoted because it wrapped
# its value in escaped double quotes. Per the enumeration rule, a class that
# recurs at different sites is closed by counting the population, not by fixing
# the reported instance.
#
# Output: one tab-separated row per site — INTERP|CONST, the command token, SHQ
# or RAW (INTERP only), and the line number of the logical line's last physical
# line. Case DA in tests/handoff.test.sh asserts the counts.
#
# The token list is the set of commands this script tells a human to RUN. Prose
# that merely names a program (`claude --bg exited 3`) is not in it: nothing there
# is meant to be pasted. The floor assertion in DA is what catches a token that
# stops matching.
#
# TWO KINDS OF TOKEN, because they sit differently inside the printed command.
# A COMMAND token (`claude attach`) begins the command, so everything that
# matters is BEHIND it and the segment to inspect is the suffix, cut at the end
# of the message. A FLAG token (`--append-system-prompt`) sits in the middle of
# a command whose operands come FIRST, so the suffix says nothing and the
# segment to inspect is the printed line the flag sits on — bounded by the \n
# separators of the format string. Round 6 (C5) found the whole dispatch region
# invisible to this census for exactly that reason: the `--dry-run` launch
# command, the one line the operator is invited to trust and paste, interpolated
# four unquoted operands and the census reported zero rows anywhere near it.
# Keep the two lists separate; widening the COMMAND rule to look at the whole
# line instead would collapse the 19 CONST sites into INTERP, since those
# interpolate state into the PROSE beside a constant command.
# Every site that prints a shell command for a human to paste, classified by
# whether a value is interpolated into that command.
function seg_cmd(line, t,   idx, cut) {
  idx = index(line, t)
  cut = substr(line, idx + length(t))
  # An ESCAPED double quote is INSIDE the message, not the end of it: the site
  # this class was found at wrapped its value in \" and read as constant text
  # while interpolating a path. Neutralise those first, then cut at the first
  # backtick, comma, em-dash, or real closing quote.
  gsub(/\\"/, "Q", cut)
  if (match(cut, /`|,|—|"/)) cut = substr(cut, 1, RSTART - 1)
  return cut
}
function seg_flag(line, t,   idx, pre, post) {
  idx = index(line, t)
  pre = substr(line, 1, idx - 1); post = substr(line, idx + length(t))
  if (match(pre, /.*\\n/)) pre = substr(pre, RSTART + RLENGTH)
  if (match(post, /\\n/))   post = substr(post, 1, RSTART - 1)
  return pre post
}
function emit(line, t, cut) {
  if (cut ~ /\$/ || cut ~ /%s/) print "INTERP\t" t "\t" (line ~ /SHQ/ ? "SHQ" : "RAW") "\t" NR
  else print "CONST\t" t "\t-\t" NR
}
function classify(line,   i, t) {
  if (line ~ /^[ \t]*#/) return
  # argv ASSEMBLY, not a printed command: `set -- ... --append-system-prompt ...`
  # builds the arguments actually handed to execve. Nobody pastes it.
  if (line ~ /^[ \t]*set -- /) return
  for (i = 1; i <= NT; i++) {
    t = TOK[i]
    if (index(line, t)) emit(line, t, seg_cmd(line, t))
  }
  for (i = 1; i <= NF_TOK; i++) {
    t = FTOK[i]
    if (index(line, t)) emit(line, t, seg_flag(line, t))
  }
}
BEGIN {
  NT = split("claude attach|rm -rf|rmdir |handoff.sh --status|claude agents", TOK, "|")
  NF_TOK = split("--append-system-prompt", FTOK, "|")
}
{
  buf = buf $0
  if (buf ~ /\\$/) { sub(/\\$/, "", buf); next }
  classify(buf); buf = ""
}
END { if (buf != "") classify(buf) }
