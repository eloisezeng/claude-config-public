---
name: widening-a-value-type-gets-no-compiler-census
description: Renaming a symbol enumerates its callers in the compiler; WIDENING the type of a value does not, wherever a boundary supplies that value dynamically — a JSON route mock, a cast in a test loader, a fixture default — so the new state reaches the suite instead of the typecheck, and an ABSENT mock means the new state rather than the old default
metadata:
  type: feedback
scope: global
---

Adding a third value to a two-valued state is two different jobs, and only the first one is free.
Where the value crosses a TYPED edge, renaming the producer makes the compiler enumerate every consumer at once, which is the census you want and the reason to rename rather than retype in place — every member of a string union is truthy, so `if (state)` keeps compiling and silently reads one branch for all three.
Where the value crosses an UNTYPED edge, the compiler sees nothing: a route answering JSON, a fixture with a default argument, a test loader that *asserts* a component's props instead of importing them.
Those sites are a second census, taken by hand, and the thing to look for is not a wrong value but an ABSENT one — because absence now means the new state.

**Why:** 2026-10-11, a private frontend repo, making "has this viewer opened this brief?" three-valued so no surface prices a brief it cannot read.
The rename gave a clean compiler census and found a caller the brief had not named — a second list building its own opened set with no loading check.
The typecheck then read CLEAN while two untyped edges carried the old shape.
`tests/rendering/reset-note.test.tsx` builds the component through `load<React.FunctionComponent<{ opened: boolean }>>(...)`: the cast IS the type, so `opened={false}` typechecked and the component, reading `opened === "not-opened"`, fell through to its priced branch and printed "This will be brief 10 of your 10" where the test asserts the limit sentence.
Then the browser suite came back 262 passed, **5 failed**, and every one of the five was a spec with no route for `GET /api/opened-briefs` at all: the request reached a test server with no database, got a 503, and the page correctly refused to quote a price — so the red set was a FIXTURE CENSUS, not a defect list, and the subject of each red spec (a card error, a layout, a focus refresh, the logging) had nothing to do with it.

Three rules came out of it, each paid for:

- Fix such a class where the VIEWER or the OWNER is decided, never spec by spec. The repo's `mockIdeaPreview` already answered the session and that member's meter and documented itself as the fixture that decides who the viewer is; the list belonged beside them, and one edit fixed four specs.
- A fixture's owner is REQUIRED, never defaulted. My first version defaulted it to `null` and all four specs STAYED red: the consumer reads a list belonging to somebody else as a changed session, which is the same unknown state. A throwaway probe printed the session answering one account while the list answered no owner — I had reasoned about it twice and been wrong both times before measuring.
- Prove the new state with a mutant restoring the OLD reader, and quote what it read. Forcing the hook's `unreadable` to `false` failed both new tests with the unknown lock resolving to 0 of 10 elements, and the saved error context showed each row reading "Not opened · uses 1 of your 10" — the exact wrong price, in both the pending and the failed case.

Siblings: [[a-fixture-helpers-default-pins-the-swept-axis]] is the same blindness one level down (a default pinning a swept axis); [[encode-the-invariant-in-the-shape-not-another-guard]] is why the rename is worth it in the first place; [[a-mention-is-not-a-property]] is the same lesson about guards that a cast is about types.
