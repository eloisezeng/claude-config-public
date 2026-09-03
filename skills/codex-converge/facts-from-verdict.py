#!/usr/bin/env python3
"""facts-from-verdict.py — turn round N's verdict into round N+1's scoping blocks.

Why this exists (measured 2026-09-02, MFFP round-4 fact-check track): four serial
rounds of one lens each re-reproduced every number the first round had already
confirmed, because the do-not-re-report list and the verified-facts block were
hand-edited per round and never carried the reviewer's own quoted reproductions.
The next round then paid the full reproduction cost to say "still reproduces".

Usage:
  facts-from-verdict.py <verdict.json> [--fixed 0,1,2] [--declined 3="reason"] \
      [--adjudicated 4="evidence"] [--min-conf 0.9]

Emits two XML blocks to stdout, ready to paste into the next prompt:
  <verified_environment_facts>  — the verdict's summary (the reviewer's own
      reproduction transcript) plus every finding you dispositioned, each with
      its disposition, so the next round neither re-derives nor re-reports it.
  <do_not_re_report>            — the same findings as a numbered list, one
      line each, in the "finding + why it is settled" form the skill demands.

A finding you did NOT disposition is printed to stderr and exits 2: an
undispositioned finding is not settled and must not be carried as a fact.
"""
from __future__ import annotations

import argparse
import json
import sys


def _parse_kv(items):
    out = {}
    for it in items or []:
        if "=" not in it:
            raise SystemExit(f"expected N=\"reason\", got {it!r}")
        k, v = it.split("=", 1)
        for idx in k.split(","):
            out[int(idx)] = v.strip().strip('"')
    return out


def build(verdict: dict, fixed: set[int], declined: dict, adjudicated: dict) -> tuple[str, str, list[int]]:
    findings = verdict.get("findings", [])
    facts = []
    dnr = []
    missing = []
    for i, f in enumerate(findings):
        loc = f"{f.get('file')}:{f.get('line_start')}-{f.get('line_end')}"
        head = f"r[{i}] ({f.get('severity')}, conf {f.get('confidence')}) {f.get('title')} @ {loc}"
        if i in fixed:
            disp = "FIXED in the current tree — re-report only by quoting a line that still carries the defect"
        elif i in declined:
            disp = f"DECLINED — {declined[i]}"
        elif i in adjudicated:
            disp = f"ADJUDICATED not a defect — {adjudicated[i]}"
        else:
            missing.append(i)
            continue
        facts.append(f"- {head}: {disp}")
        dnr.append(f"{i + 1}. {f.get('title')} — {disp.split(' — ')[0]}")
    summary = (verdict.get("summary") or "").strip()
    facts_block = "<verified_environment_facts>\n"
    if summary:
        facts_block += ("- Previous round's own reproduction transcript (do not re-derive; "
                        "check only what the fixes changed):\n  " + summary.replace("\n", "\n  ") + "\n")
    facts_block += "\n".join(facts) + "\n</verified_environment_facts>\n"
    dnr_block = "<do_not_re_report>\n" + "\n".join(dnr) + "\n</do_not_re_report>\n"
    return facts_block, dnr_block, missing


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("verdict")
    ap.add_argument("--fixed", default="")
    ap.add_argument("--declined", nargs="*")
    ap.add_argument("--adjudicated", nargs="*")
    a = ap.parse_args(argv)
    v = json.load(open(a.verdict))
    fixed = {int(x) for x in a.fixed.split(",") if x.strip()}
    facts, dnr, missing = build(v, fixed, _parse_kv(a.declined), _parse_kv(a.adjudicated))
    if missing:
        print(f"facts-from-verdict: findings {missing} have no disposition — "
              "an undispositioned finding is not a settled fact", file=sys.stderr)
        return 2
    sys.stdout.write(facts + "\n" + dnr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
