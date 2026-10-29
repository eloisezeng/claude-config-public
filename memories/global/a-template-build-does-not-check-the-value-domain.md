---
name: a-template-build-does-not-check-the-value-domain
description: A declarative template's build/lint checks SHAPE, not the provider's value domain — `az bicep build` accepts a nonexistent enum member silently, so settle any "is this value allowed at this API version?" question against the published schema and control the validator with a deliberately invalid value
metadata:
  node_type: memory
  type: reference
  scope: global
---

A template compiler tells you the file parses and the property NAMES exist. It does not tell you a property's VALUE is one the provider accepts. The two questions feel like one question because a single command answers both or neither, and the answer it gives is an exit code that cannot distinguish them.

Measured 2026-10-18 on Bicep CLI 0.48.1 / Azure CLI 2.90.0. A WAF custom rule carrying `action: 'CAPTCHA'` at `Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01` built with exit 0 and no warning. So did a control carrying `action: 'NotAnAction'`. The published REST specification settles it: that API version's action enum is `Allow`, `Block`, `Log`, `Redirect`, `AnomalyScoring`, `JSChallenge`, and `CAPTCHA` arrives only at `2025-03-01`, together with `captchaExpirationInMinutes`. The invalid value would have failed at deploy or what-if time, which is the one place nobody wants to discover it.

So:

- **Never report a clean template build as evidence about a value.** Say which of the two questions the build answered. A green build beside an unverifiable claim lends the claim the build's authority, which is how this one nearly shipped.
- **Control the validator with a value that cannot be right.** One deliberately invalid member on a COPY, in the same command, is the whole measurement. If the bogus value also passes, the validator does not check that field and its silence means nothing — which is `absence-needs-a-probe-that-could-see-presence` applied to a tool rather than to a probe you wrote.
- **Settle the value against the provider's own schema, by API version.** For Azure that is `azure-rest-api-specs`, under `specification/<rp>/resource-manager/<namespace>/<service>/stable/<version>/`; read the enum and the numeric `minimum`/`maximum`, and read them for BOTH the version in the file and the version you would move to, because a bump has to carry every property the file already uses.
- **A value that needs a newer API version makes the version bump part of the change**, and that is a reviewer's decision, not a detail: the declared version is what `what-if` compares against, so bumping it changes the drift report for everything else in the file.

The same shape appears wherever a build and a runtime disagree about who owns the value domain: a JSON Schema that types a field `string` while the service accepts four strings, a migration that compiles against a column that does not exist yet, an enum widened in one generated client and not another.

Pairs with [[absence-needs-a-probe-that-could-see-presence]], [[a-guard-must-be-satisfiable-not-just-failable]], [[verify-claims-against-artifacts]], [[a-mention-is-not-a-property]].
