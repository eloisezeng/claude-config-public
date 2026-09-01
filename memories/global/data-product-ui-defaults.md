---
name: data-product-ui-defaults
description: "Design defaults for any data-driven product UI (dashboard, inbox, pipeline, reporting) — apply before calling UI work done"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 7a88ef9c-6357-4092-8e66-2ba2050a19aa
---

When building or reviewing a data-driven product UI, apply these defaults. They generalize the corrections the user re-filed repeatedly on the Domain Arbitrage dashboard; they are how she expects ANY data product to behave.

1. **Plain language, real entities, no machine artifacts.** Never surface internal identifiers, status enum values, or raw JSON in the UI. Render real names, plain-English statuses, human-readable counts; long lists get an expand/"show all" control, not IDs.
2. **Nothing clipped or overflowing.** Size containers to content and verify at the real viewport — cards show all items, controls fit their containers, numbers align under headers. Layout bugs don't appear in the code; look at the running page.
3. **Treat data as time-sensitive.** Show when an item was generated and whether it's still actionable; move stale/expired items to their own section — never present expired data as actionable.
4. **Sort actionable lists by the decision signal.** The field the user decides on goes first (confidence, score, priority).
5. **Reporting/financial views are complete, aggregated, and reconciled.** Include every cost/source, group repetitive line items ("Reviewed 3,000 URLs", not one row each), and make counts agree across views.
6. **Safe by default, and reversible.** Money-spending or irreversible actions default to "ask" with a sane budget cap; every action round-trips, and the reverse (undo/restore/unreject) must actually work — test it.
7. **Self-explanatory and forward-looking.** Each surface explains in plain language what it does and surfaces the "what's next" manual steps the user still owes.
8. **No blocking pop-ups for outcomes the page can show.** Never `alert()`/`confirm()`/modal a result the page state can communicate inline (a card updating, a banner clearing, an item disappearing). Reflect the outcome IN the surface she's already looking at; if a no-op would look identical to "nothing happened", add an inline note ("checked just now — still no credits"). Reserve pop-ups for true failures with no page surface and confirm-before-irreversible.
9. **Pending-work notifications reconcile with live state before sending.** Announce an item only after it has sat unhandled past a grace window AND is still live at send time; at most once per item (durable per-item stamp, stamped only on a real send); the message names each item with the destination surface's own labels plus size and deadline, so read hours late it still makes sense. Fire-on-arrival + cooldown is an anti-pattern: it announces items being handled in real time while the cooldown swallows the ones that genuinely wait.

**How to apply:** walk this list against the live page as an end user before claiming any UI work done. The Domain Arbitrage instance (concrete copy/threshold/cost specifics) lives in that project's `dashboard-product-rules` memory. Pairs with [[explain-plainly-non-expert-domain]] and the global pixel-perfection guideline.
