---
name: user-profile-template
description: "Template — what a `type: user` memory should contain, and what makes one earn its place in every session's context"
metadata:
  node_type: memory
  type: reference
  scope: global
---

A `type: user` memory answers "who is the person I am working for", and its pointer line is loaded into
every session.
That is the most expensive real estate in the config, so a user memory earns its place only by changing
what an agent would otherwise do by default.

Fill one in per facet of your working life — one for the research side, one for the product side — rather
than one that tries to describe the whole person.
Each should be a few sentences, not a biography.

Cover, in roughly this order:

- **Role and domain.** Enough for an agent to pitch explanations at the right level and to know which
  vocabulary is already shared.
- **Prior work it may assume.** Name the projects whose concepts do not need re-explaining. This is the
  line that stops an agent from re-deriving something you built.
- **How you delegate.** Which calls you hand over ("ultimately you decide") and which you always want
  back. An agent that guesses this wrong either stalls on decided questions or decides ones that were
  yours.
- **How you correct.** Whether errors come back as precise factual corrections or as a change of
  direction — this tells an agent how much of a pushback is a fact claim to verify versus a preference
  to adopt.
- **Environment facts that change the plan.** Where long work runs, what the shell is, which tools are
  the house ones. Link the memory that carries each rule rather than restating it.

Split a facet out when the two halves would give an agent different defaults; link them to each other so
whichever one loads first names the other.
Keep employer names, addresses, collaborators' names, and anything that identifies a third party out of a
config you intend to share — they are exactly the content that makes a profile unpublishable, and none of
it changes what the agent does.
