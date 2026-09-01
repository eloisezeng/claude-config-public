# fixture helper for ci-green.test.sh cases 13-15: duplicate the FIRST check-run's name onto two rows
# with the given (status, conclusion) pairs, in the given order, keeping the remaining rows.
import sys, os
d, s1, c1, s2, c2 = sys.argv[1:6]
p = os.path.join(d, "runs.tsv")
rows = [l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
name = rows[0][0]
out = [[name, s1, c1], [name, s2, c2]] + rows[1:]
open(p, "w").write("".join("\t".join(r) + "\n" for r in out))
