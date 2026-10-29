---
name: gh-axi-field-eats-a-leading-at-sign
description: `gh-axi api --field body=<text>` reads a leading `@` as a FILE PATH, so any GitHub comment that opens with an @-mention fails to post — send it as JSON with `gh api --input`
metadata:
  type: reference
  scope: global
---

`gh-axi api PATCH <endpoint> --field body="@someone …"` fails with
`error parsing "body" value: open someone … : no such file or directory`, because `--field` treats a leading `@` as a file reference.
Almost every reply to a person on a pull request opens with an @-mention, so this is the common case rather than an edge one.
`gh-axi` also has no `--input`, no `--raw-field` and no `--jq` that reaches the body, and its REST renderer truncates long fields (`[[gh-axi-rest-truncates-long-fields]]`), so it cannot round-trip a long comment either way.

Write the payload as JSON and post it with the plain CLI, under the same account:

```bash
python3 -c "import io,json; io.open('p.json','w').write(json.dumps({'body': io.open('c.md').read()}))"
gh api --method PATCH repos/<owner>/<repo>/issues/comments/<id> --input p.json --jq '.id, .updated_at, (.body|length)'
```

Read the returned length back against the file's own length; that is the cheap proof the whole body landed rather than a truncated prefix.
The preference for `gh-axi` is a default about which tool to reach for first, not a reason to post a mangled comment — when it cannot do the job, say which tool did it instead.
