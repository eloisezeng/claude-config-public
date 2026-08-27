---
name: email-drafter
description: Draft, rewrite, or polish emails and messages in the user's own voice. Use this whenever the user asks to write an email, clean up a draft, reply to someone, turn notes or bullet points into an email, or make a message "sound like me." Apply it even when the user does not name the skill — any time the task is composing or editing a message they will send, default to this voice profile rather than generic professional-email style.
---

# Email drafter (the user's voice)

The job: produce emails that read like the user wrote them on a good day — their natural, honest voice, but organized and tight. Not a generic "professional email," and not maximally casual either.

**This file is a TEMPLATE.** The structure below is the reusable part; the specifics are not. Every rule in "Hard rules" and "Voice profile" should be replaced with one learned from watching the user edit their own drafts, and the examples should be replaced with real before/after pairs from their sent mail. A voice profile copied from someone else produces someone else's voice.

The skill is meant to compound: when an edit reveals a preference, write it into "Hard rules" or "Voice profile" so the next draft starts from it instead of relearning it.

## How to use it

Two modes, both common:

- **Polish a draft.** The user supplies something rough, often one long block with typos. Keep their words, ideas, and order. Fix typos and grammar, break walls of text into short paragraphs, pull any list of asks into bullets, and cut padding. Do not inflate it into something stiffer than they wrote.
  On a *re-polish* — the user hands the same file back after editing it — treat the wording they kept or restored as **locked**: fix new typos and genuine errors, but do not re-tighten or rephrase a clause they have already settled. A phrasing put back the way they originally wrote it is a decision, not an oversight.
- **Brief to email.** The user supplies a few points ("tell the vendor X, Y, Z"). Write the whole thing in the voice below, with the ask stated clearly.

When unsure which mode applies, default to polish: a user who has written something usually wants it cleaned, not replaced.

## Hard rules

Non-negotiable, because the user has corrected each of them explicitly. *Replace these with the user's own; the ones here are placeholders that show the right level of specificity.*

- **A named punctuation ban.** e.g. "no em dashes, ever — use a comma, a colon, a period, or restructure." A rule of this shape is easy to check and easy to violate silently, so state it absolutely.
- **Few adverbs.** Cut filler and hedge words: *honestly, actually, really, pretty, kind of, basically*, and *just* when it is padding. Keep an adverb only when it carries meaning.
- **Concise.** Prefer the shorter sentence. If a clause is not doing work, drop it.
- **Do not "correct" a settled word choice.** When the user restores a phrasing, leave it, even if it reads like a slip. Lock that wording and stop re-flagging it.
- **Write the changes into the file.** When the user passes a file (`/email-drafter draft.md`), write the polished version back into that same file, overwriting the rough one. Show the result in chat as well, plus a short note on what changed and anything to confirm — but the file is the source of truth and should end up holding the cleaned version.

## Voice profile

*Replace each bullet with an observed pattern, and quote a real fragment as evidence. A voice profile without quotes degrades into generic advice within a few edits.*

- **Honest hedging.** The user owns rough edges instead of overselling. Do not sand this into corporate confidence.
- **Context before the ask.** They set up the why, then ask. Keep that order.
- **Soft, direct asks.** The request is clear but not a hard pitch.
- **Concrete over vague.** Real numbers and named specifics rather than "some" and "a few." When a figure is known, use it; when it is not, go find it rather than fudge it.
- **Plain language, not jargon.** Write for a smart non-specialist. If a term needs insider knowledge, explain it in plain words or cut it.
- **Pronoun discipline.** Note which pronoun the user uses for shared work versus their own actions, and keep the split consistent.

Structure the user prefers:

- **Bullets are the default for any list of three or more parallel items.** Introduce each list with a short lead-in line ending in a colon.
- Keep bullets grammatically parallel — lead each with the same verb form — and punctuate them consistently: all end with a period, or none do.
- Short paragraphs are the connective tissue between lists, never one stream-of-consciousness block.
- A numbered list when the message poses distinct questions, so replies can cite numbers.
- Greeting and sign-off stay simple.

What to avoid:

- Stiff, over-formal phrasing ("I am writing to inform you," "Please be advised").
- Maximally casual or slangy register.
- Padding, throat-clearing, and adverb pile-ups.

## Examples

*Replace with a real pair from the user's own mail. The illustration below is invented, and its only job is to show the format.*

**Polish — input (rough draft):**
> got the build working today, it was pretty quick so if we want to throw it away thats fine. i cant run it on the shared box yet without a licence and i cant point it at the real data either so for now its just reading the sample file

**Polish — output (cleaned):**
> The build works. It came together quickly, so scrapping it is not expensive if we decide to.
>
> Two things block a real run:
>
> - **Licence.** The shared box needs a seat before it can run this. One seat is enough for now.
> - **Data.** It reads the sample file today. Pointing it at the real dataset needs read access to the export bucket.

What stayed: the honest framing and the plain owning of the constraints. What changed: the blockers pulled into colon-led bullets, vague blockers named concretely, typos gone, tighter.

## Reference email (the target shape)

*Replace this with a full email the user wrote and signed off on — it is the single most useful artifact in this file, because it fixes shape, length, and register at once. The one below is invented.*

> Hi,
>
> Short version: the prototype works, and it needs two things before it can run for real.
>
> What it does now:
>
> - Takes a plain-sentence description of the problem and routes it to the right handler.
> - Summarizes the matching records rather than dumping them.
> - Falls back to the sample dataset when the live one is unavailable.
>
> To get it running on the shared box, we would need:
>
> - **A licence seat.** One seat covers the whole team for this workload.
> - **Read access to the export bucket.** Read-only is enough; nothing writes back.
>
> There is more we could build after that, including scheduled runs and a digest, but neither is worth doing before the two items above are settled.
>
> Would you like me to move forward with this? If not, is there something else you would rather I pick up?
>
> Thanks
