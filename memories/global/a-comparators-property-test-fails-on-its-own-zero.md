---
name: a-comparators-property-test-fails-on-its-own-zero
description: "A comparator's antisymmetry property written as `toBe(-Math.sign(cmp(b,a)))` fails on every EQUAL pair, because Object.is(+0,-0) is false — sum the two signs instead, and read which side the counterexample accuses"
metadata:
  type: feedback
scope: global
---

Write a comparator's antisymmetry property as `expect(sign(cmp(a,b)) + sign(cmp(b,a))).toBe(0)`, never as `expect(sign(cmp(a,b))).toBe(-sign(cmp(b,a)))`.

`Math.sign(0)` is `+0`, `-Math.sign(0)` is `-0`, and `toBe` uses `Object.is`, for which `Object.is(+0, -0)` is **false**. So the negated form fails on every pair the comparator calls EQUAL — which is the one case a correct comparator is guaranteed to produce, and the case a generated corpus hits immediately. Measured: fast-check shrank to two identical rows and reported `expected +0 to be -0` after 10 tests, against a comparator that was correct. The sum is `+0 + -0 === +0`, so it passes on equality and still catches a genuine asymmetry.

The general rule the slip teaches, which is the reusable half: **when a property test reddens, the counterexample names which SIDE is wrong, so read what it actually compared before touching the code.** A shrunk counterexample of two *identical* inputs is almost never a defect in an order — an order has nothing to get wrong about two equal things — and that shape points at the assertion. The same session's other red was the mirror case: a test asserted a refusal reason of `dated_in_the_future` where the rule had honestly answered `not_a_calendar_day`, because a millisecond field read as seconds is year 58077 and `toISOString` renders that as `+058077-02-06T…`, which is not a calendar day at all. Both reds were the test; neither was the rule. Assert the answer the rule ACTUALLY gave — a run can only report that one — and fix the expectation rather than widening the rule to meet it.

