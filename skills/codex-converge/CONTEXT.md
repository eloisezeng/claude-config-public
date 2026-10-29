# Code review

The vocabulary of how changes are reviewed and how the reviewer itself is graded.

## Language

**Escape**:
A defect that reached the default branch after review and was later repaired. The repair need not be a merged change, and the defect need not have one introducing change — both were widened by the product owner on 2026-10-26, and both widenings are definitional rather than additions to any runnable set.
_Avoid_: incident, regression (unless it is one), post-merge repair (broader: includes follow-ups that fixed no defect)

**Introducing change**:
A merged change whose code contained an **Escape**'s defect. An **Escape** has **one or more**: a defect can be created by two changes that each passed review on their own, which the earlier "exactly one" wording could not express.

**Repair**:
What fixed an **Escape**. Usually a merged change; it may instead be an operator action that produces **no diff at all**, such as patching a live configuration row directly on the running host. A no-diff repair carries no changed lines, so no defect line range is derivable from it and the line-overlap **Catch** rule cannot score it even in principle — such an **Escape** is recorded with its reason rather than scored.

**Escape test set**:
The collection of **Escape**s, each stored with its **Introducing change**'s diff and the defect's location, used to grade the reviewer.
_Avoid_: benchmark, golden set

**Catch**:
A reviewer run on an **Introducing change**'s diff that reports the **Escape**'s defect.

**Clean case**:
A merged change that no **Repair** names, stored in the **Escape test set** so that reviewer noise is measured alongside **Catch**es.

**False alarm**:
A **Finding** on a **Clean case** that would lead an author to make a harmful change.

**Finding**:
One defect a reviewer reports in one review run.

**Finding outcome**:
What happened to a **Finding**, exactly one of: fixed, reviewer was wrong, intentional, didn't matter, deferred, not reachable.
_Avoid_: disposition (used elsewhere for efficiency levers), verdict (the whole run's result)

**Not reachable**:
A **Finding outcome** meaning the reported bad state cannot occur, because nothing that writes the value can produce it.

**Reviewer was wrong**:
A **Finding outcome** meaning the reviewer misread the code itself.

**Review depth**:
How thorough a review is, chosen per change from the files it touches.

**Deep-review list**:
The paths whose changes always get the deepest **Review depth**: money, security, migrations, plus every directory where an **Escape** has occurred.

## Relationships

- An **Escape** has **one or more Introducing changes** and exactly one **Repair**.
- A **Repair** that produces no diff yields no defect location, so its **Escape** is recorded and never scored against the diff reviewer.
- The **Escape test set** grows by one case per new **Escape**; each new case also carries the **Introducing change**'s spec when one exists.
- Every **Finding** has exactly one **Finding outcome** once its round closes.
- The **Deep-review list** grows from the **Escape test set**.

## Example dialogue

> **Dev:** "This fix touches the inbox card again — is it an **Escape**?"
> **Domain expert:** "Only if it repairs a defect some earlier merged change introduced, and names that change. A follow-up that finishes an incomplete feature is a **Repair** of nothing."

## Flagged ambiguities

- "Disposition" was used for both finding outcomes and efficiency-lever states — resolved: findings get a **Finding outcome**; "disposition" stays with levers.
- "Code review caught 0 of 40 repairs" counted how each defect was *found*, not where it could earliest have been caught — the two tallies must not be mixed.
