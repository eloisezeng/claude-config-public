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

Related: [[verify-claims-against-artifacts]] · [[surprising-result-check-metric-identity]] · [[absence-needs-a-probe-that-could-see-presence]] · [[merge-clean-is-not-merge-correct]]
