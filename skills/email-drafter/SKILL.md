---
name: email-drafter
description: Draft, rewrite, or polish emails and messages in the user's own voice. Use this whenever the user asks to write an email, clean up an email draft, reply to someone, turn notes or bullet points into an email, or make a message "sound like me." Apply it even when she doesn't explicitly name the skill — any time the task is composing or editing an email/message she'll send, default to this voice profile rather than generic professional-email style.
---

# Email drafter (the user's voice)

The job: produce emails that read like the user wrote them on a good day — her natural, honest, slightly informal voice, but organized and tight. Not a generic "professional email," and not maximally casual either. The target is the middle: a smart person writing to a collaborator, being real with them, without padding.

This profile is learned from watching the user edit her own emails. It will keep growing as we edit more together. When she makes a new edit that reveals a preference, update the "Voice profile" or "Hard rules" below so the skill compounds over time instead of relearning each session.

## How to use it

Two modes, both common:

- **Polish a draft.** She gives you something rough (often one long block with typos). Keep her words, ideas, and order. Fix typos and grammar, break walls of text into short paragraphs, pull any list of asks/items into bullets, and cut padding. Don't inflate it into something stiffer than she wrote. On a re-polish (she passes the file again after editing), treat the wording she kept or restored as locked: fix new typos and genuine errors, but don't re-tighten or rephrase clauses she's already settled on. If she put a phrasing back the way she wrote it ("and we were supervised by" over your "supervised by"), that's a decision, not an oversight.
- **Brief to email.** She gives you a few points ("tell Alex X, Y, Z"). Write the whole thing in the voice below, with the ask stated clearly.

When unsure which mode, default to polish — she usually has a draft and wants it cleaned, not replaced.

## Hard rules

These are non-negotiable; she's corrected each of them explicitly.

- **No em dashes.** Ever. Use a comma, a colon, a period, or restructure the sentence. This includes "—" anywhere.
- **Few adverbs.** Cut filler adverbs and hedge-words: honestly, actually, really, pretty, kind of, just (when it's padding), basically. Keep an adverb only when it carries real meaning.
- **Concise.** Prefer the shorter sentence. If a clause isn't doing work, drop it. She consistently edits toward fewer words.
- **Drop redundant "I".** Avoid starting clauses with "I" when it adds nothing. Trim "I think I'd need to..." to "I'd need to...", and prefer "we" or an impersonal phrasing when the sentence works without the self-reference ("To get the MVP working, we would need some money" beats "I think I would need to spend some money"). The point isn't to erase her, it's to stop sentences from piling up "I ... I ... I" and sounding self-focused.
- **Don't "correct" her settled word choices.** When she restores or writes a phrasing, leave it, even if it reads like a grammar slip to you. She has chosen "attending the ICML" (with the article) over "attending ICML"; that is her call, not an error to fix. When she reverts one of your fixes, lock that wording and don't re-flag it.
- **Always write the changes into the file.** When she passes a file (e.g. `/email-drafter draft.md`), write the polished email back into that same file with the Write tool, overwriting the rough version. Don't just show it in chat and wait. Show the result in chat too, plus a short note on what changed and anything to confirm, but the file is the source of truth and should always end up holding the cleaned version.

## Voice profile

What makes it sound like her (keep these):

- **Honest hedging.** She owns the rough edges instead of overselling: "it was quick so if we decide to scrap it, that's okay." Don't sand this off into corporate confidence.
- **Context before the ask.** She sets up the why, then asks. Keep that order.
- **Soft, direct asks.** The request is clear but not a hard pitch. "Could we put a little money behind this?" not "I require funding to proceed."
- **Parenthetical asides with concrete examples.** She clarifies with quick "(like repair vs. maintenance vs. installation)" parentheticals. These are part of her voice; keep them, just don't let them run on.
- **Owns constraints plainly.** Money, limits, what's broken — she states them matter-of-factly rather than hiding them. Keep that candor.
- **Concrete over vague.** She pushes for real numbers and named specifics, not hand-wavy ranges: "$5 to $20 a month (Railway or Fly.io on the cheaper end)", "about 5,000 free searches a month", "I've used $1.22 of credit testing it, with $3.57 left." When a figure or name is known, use it instead of "some money" or "a few." If you're unsure of a number, get it rather than fudge it.
- **Plain language, not jargon.** Write for a smart non-engineer (her collaborator Alex). Translate technical terms — she had "per SKU" rewritten as "each type of call gets its own free monthly quota." If a term needs insider knowledge, explain it in plain words or cut it.
- **"We/our" for the venture, "I" for her own actions.** The project is "we" and "our website"; reserve "I" for things she personally did ("I built a prototype," "I've used $1.22 of credit," "I was wondering if you'd want to move forward").

Structure she prefers (this is strong — she restructures almost every draft this way):

- **Bullets are the default for any list of three or more parallel items** — examples, feature ideas, costs, reasons. She converts prose lists into bullets aggressively. Introduce each list with a short lead-in line ending in a colon ("For example on Google:", "It could:", "To get the MVP working, we would need some money:").
- Keep bullets grammatically parallel — lead each with the same verb form ("Let… / Tell… / Give…") — and punctuate them consistently (all end with a period, or none do).
- Short paragraphs are the connective tissue between lists, never one stream-of-consciousness block.
- Numbered list when she's posing distinct questions.
- Greeting and sign-off stay simple: "Hi [name]," / "Thanks, the user".

What to avoid:

- Stiff, over-formal phrasing ("I am writing to inform you," "Please be advised").
- Maximally casual / slangy ("college student" register). She tried that and reverted. Informal-but-clean is the target, not chatty.
- Padding, throat-clearing, and adverb pile-ups.

## Examples

**Polish — input (her rough draft):**
> I created a prototype today (it was quick so if we decide to scrap it, that's okay). I have screenshots... but I can't host this website without money, and I can't use the google maps api to extract data without money, so right now the serviceman results are just extracted from google and stored in a file

**Polish — output (her voice, cleaned):**
> I built a prototype today: a chat interface where a user can explain their problem and get help finding a serviceman. Here are some screenshots:
>
> To get the MVP working, we would need some money:
> - **Hosting:** Right now it only runs locally. A small always-on host runs about $5 to $20 a month (Railway or Fly.io on the cheaper end).
> - **APIs:** The Google Maps/Places API gives us about 5,000 free searches a month, but we need to enter a credit card. For now, the results are scraped from Google into a file.

Note what stayed: the honest framing, the plain owning of the money constraint, the context-then-ask flow. What changed: lists pulled into colon-led bullets, vague costs replaced with concrete numbers and named hosts, "I" → "we" for the shared venture, typos gone, no em dashes, tighter.

## Reference email (the target shape)

This is a full email the user wrote and signed off on. It's the single best reference for the target voice and structure: short acknowledgement → bulleted "here's the problem" → "our website could do better:" with parallel bullets → a money section with concrete figures → a soft ask. When in doubt, match this shape.

> Hi Alex,
>
> The competition strategy document makes sense. I hadn't realized Yelp reviews were gamed. It's also hard to determine the best servicemen online in general, so a lead generation website could help. For example on Google:
>
> - If you search "plumber", you get company websites, sponsored results, business listings, and Reddit threads.
> - Only the business listings give a brief summary of their ratings, work, and one sample review.
> - It has an "AI gets prices for you" feature, where the AI asks you to answer several multiple choice questions about your plumbing problem, then calls each company on your behalf.
>
> Our website could do better. It could:
>
> - Let a user describe their problem in one sentence and get matched to the right business (or the top few), with a summary of all its reviews and more detail on its specialties
> - Let users see which services their friends have used.
> - Let companies respond automatically with price estimates.
> - Tell businesses how to rank higher on merit, like faster response times and better ratings over the last six months.
> - Let companies pay to be promoted, though we'd mark paid placements and ask them to say why they're advertising.
> - Give newer companies a small boost.
>
> I built a prototype today: a chat interface where a user can explain their problem and get help finding a serviceman. Here are some screenshots:
>
> To get the MVP working, we would need some money:
>
> - **Hosting:** Right now it only runs locally. A small always-on host runs about $5 to $20 a month (Railway or Fly.io on the cheaper end).
> - **APIs:** The Google Maps/Places API gives us about 5,000 free searches a month, but we need to enter a credit card. For now, the results are scraped from Google into a file. The Claude API for the chat is a few cents per conversation. I've used $1.22 of credit testing it so far, with $3.57 left.
>
> There's also a lot more we could build for the servicemen themselves, including automated quote generation, invoicing, and the other items I listed in a previous document.
>
> I was wondering if you'd want to move forward with this. If so, I'd need a credit card. Otherwise, is there something else you'd like me to work on?
>
> Thanks,
>
> The user
