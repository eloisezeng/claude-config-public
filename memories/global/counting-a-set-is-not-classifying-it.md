---
name: counting-a-set-is-not-classifying-it
description: Measuring a set's SIZE licenses no claim about its KIND — the sentence "these are all just X" about members you enumerated but never opened is the defect; open a sample, and name the shape only for members you read
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A measurement of **how many** and **how big** tells you nothing about **what kind**.
The tell is a sentence of the form *"these are all just X — it's careful work, not hard work"* written about a set you produced by counting rather than by reading.
Before naming a set's shape, open its members — every one where the set is small, a stratified sample (largest, smallest, most central) where it is not — and state the shape only over what you actually read, with the unread remainder named as unread.

**Why:** Scoping the reintegration of a long-lived branch, I ran a real trial merge and measured it honestly — 7 conflicting files, 10 hunks, **420 conflicted lines** — and then wrote that they were *"all of one shape: two features adding rows to the same registry, so it is careful work rather than hard work"*. I had not opened a single conflict hunk. When a second opinion disputed it and I dumped the conflicted blobs out of `git merge-tree --write-tree`, only **63 of the 420 lines** matched that description. The other 357 were architectural: the largest conflict — **62% of all conflicted lines** — was not a merge at all but a **port**, because the main line had *replaced* the file the branch was still editing; another was a signature change the branch predated; another was the **same bug fixed twice, two different ways, on the same lines**. The estimate built on that judgement was wrong by a factor of two, and it was the one number the reader was going to plan around.

Note what did *not* fail: the counting was correct, the trial merge was real, the file/hunk/line table was reproducible. Rigour in the measurement is exactly what made the unmeasured judgement sitting next to it read as measured too — the paragraph inherits the table's authority. So the danger is highest in the write-ups that are otherwise most careful.

**How to apply:**
- **Never let a count carry a kind.** `git diff --numstat`, a hunk tally, a file list, a row count: each answers *how much*. Answering *what sort* requires reading the bytes. Two separate acts, and only one of them was performed.
- **Read the biggest member first.** Distribution is skewed almost always; here one file was 62% of the total and was also the one that broke the claim. Reading the single largest member would have caught it in one command.
- **Cheap reproduction beats a worktree.** `git merge-tree --write-tree A B` prints a tree id; `git cat-file -p <tree>:<path>` then dumps the conflict-marked blob — no worktree, no index, no touching a shared checkout. There is no excuse of cost for not looking.
- **Classify in the artifact, with a column.** Put the shape in the table next to the count (`port` / `signature change` / `duplicate fix` / `clerical`) so an unread member cannot hide inside a prose generalisation; a blank cell is then visibly unread.
- **Estimates inherit the classification, so re-derive the estimate when the classification changes.** The sizing sentence and the shape sentence are one fact, not two.
- **A narrative report is the same defect surface as a scope estimate.** Prose written for a reader carries counts too ("22 commits", "9 review rounds", "three things"), and an adjective attached to one of them IS this bug — *"rounds five to nine produced 22 commits, mostly tightening pure calculations that could not have hurt anyone"*, written from memory about commits I had not reopened. Measured on challenge: **15 of the 22 changed production code**, and two of those decided whether a person who replied STOP still gets emailed — a suppression stored with a trailing dot that matched no provider, and a `STOP,` that was not read as an opt-out. Every clause the reader would act on was false. So: any adjective about a counted set is built by opening the members at write time, or the sentence ships as the bare count with no kind-word at all — and a published claim found wrong is corrected in place, visibly, never quietly deleted.

- **An INHERITED classification is somebody else's unmeasured kind, and the first failing locator over-attributes.** A handoff handed me "17 acceptance failures: 14 are one button-label mismatch, 3 are this lane's regression", diagnosed to the line and entirely believable. Re-running the suite gave **16 failures, of which the label accounted for 7** — and fixing the label did not make those 7 pass, it made them fail FURTHER ALONG, because the label was merely the first locator each stale spec reached. Every one of the 16 was the same family underneath: specs written against surfaces a merge had replaced. A taxonomy built by reading rather than by running attributes a failure to its first visible cause, which is the cause that happens to be nearest the top of the test. So re-measure an inherited classification before acting on it, and read "fixing X moved the failure later" as evidence that X was never the class.

Related: [[verify-claims-against-artifacts]] · [[surprising-result-check-metric-identity]] · [[absence-needs-a-probe-that-could-see-presence]] · [[merge-clean-is-not-merge-correct]]
