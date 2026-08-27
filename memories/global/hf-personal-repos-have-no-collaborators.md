---
name: hf-personal-repos-have-no-collaborators
description: "HF personal-namespace repos can't grant write access to others; and how to probe write permission with a validated negative control"
metadata: 
  node_type: memory
  scope: global
  type: reference
  originSessionId: 2f4838d5-9ba9-48a9-8acd-a7a92c83dca4
  modified: 2026-08-06T01:24:05.754Z
---

A Hugging Face repo in a **personal namespace** cannot grant another account write access — there is no collaborator management outside orgs. To hand a dataset over, either move it to an org or republish under the other person's namespace.

**Probing write access without mutating anything:** `GET /api/{type}/{repo}/user-access-request/pending` returns 200 with write permission and 403 `"You have read access but not the required permissions"` without it.

**Why this specific endpoint:** the obvious probe, `POST /api/{type}/{repo}/preupload/{rev}`, returns **200 on repos you cannot write** — it only reports LFS upload modes. It produces a confident false positive.

**How to apply:** never trust a permission probe without a negative control (a repo you certainly cannot write, e.g. `openai/gsm8k`) *and* a positive control (a repo you own). If both return the same status, the probe is measuring nothing — discard it and find another endpoint. Generalizes past HF: any capability check needs both controls before its answer means anything.
