---
name: instagram-oauth-professional-only-no-email
description: "Instagram OAuth serves professional accounts only and never returns an email — 'sign in with Instagram' is not a general-purpose auth method"
metadata:
  node_type: memory
  type: reference
  scope: global
---

"Sign in with Instagram" is not a viable general-purpose authentication method, and has not been since December 2024.
Verify against Meta's live docs before designing anything that depends on it, but expect these three constraints to hold.

- **Personal accounts have no API access at all.** Meta shut down the Instagram Basic Display API on 4 Dec 2024. Every surviving path (Business Login for Instagram, Facebook Login for Business) serves **professional accounts only** — the free Creator or Business mode in Instagram's settings. No scope or paid tier changes this, so users on ordinary personal accounts simply cannot be signed in.
- **It never returns an email.** Any account type, any scope. Auth.js documents this flatly. That breaks account linking (providers are matched by verified email), account recovery, and any adapter or gate that assumes an address exists — the same human signing in with Google and then Instagram gets two unlinked accounts.
- **Public use needs App Review *and* Business Verification.** Standard Access only serves people holding a role on the app. Advanced Access requires legal-entity paperwork and weeks of lead time.

Also: the built-in Auth.js/NextAuth `Instagram` provider is dead code — it still requests `scope=user_profile` against the retired Basic Display endpoints, so any real implementation needs a hand-written provider config using `instagram_business_basic`. Instagram also demands an HTTPS redirect URI even on localhost, and its token response returns `user_id` rather than a standards-clean `id_token`.

**How to apply:** when asked for Instagram sign-in, surface these constraints before building, and offer the alternative that usually matches the real intent — Instagram as an optional *connection* on an existing email-backed account (verified handle, avatar, profile badge), with a self-reported handle field as the universal fallback that also serves personal accounts. Reserve a true sign-in provider for when the user reaffirms it knowing the cost, and pair it with a post-signup email-collection and merge flow. Related: [[verify-claims-against-artifacts]].
