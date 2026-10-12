# Decisions

One file per decision that shapes Roomprint: what we chose, why, and what we
said no to. Anyone records them: people and agents alike.

Read the ones for your area before proposing a change. A `rejected` decision
means it was already discussed and turned down: don't propose it again
without new information.

## When to write one

When a change or a conversation settles something a later contributor could
reasonably undo or re-propose: what the app asks of people, what is uploaded
and who sees it, how a scan becomes a plan, a library picked or refused. Not
for bug fixes or anything the code already says plainly.

Add the file in the same commit that makes the change.

## File

`decisions/<date>-<slug>.md`, for example
`decisions/2026-10-13-the-app-asks-for-a-name-on-its-first-start.md`. The file
name without `.md` is the decision's id, and it never changes.

```markdown
---
title: The app asks for a name on its first start
status: accepted
area: app
kind: product
date: 2026-10-13
by: p4ulcristian
depends-on:
supersedes:
refs: ios/Sources/Roomprint/NameView.swift
---

## Context

What forced the choice.

## Decision

What we chose, in a few sentences.

## Rejected alternatives

- What else was on the table, and why not.
```

The header is plain `key: value` lines (not YAML). Lists are comma separated.
Every key is required; leave a list empty when there is nothing.

| Key | Value |
|---|---|
| `title` | One line, the decision itself ("The app asks for a name on its first start"), not the topic ("Names"). |
| `status` | `accepted`, `rejected` (we decided not to), `superseded` (a later decision replaced it), `open` (discussed, not settled). |
| `area` | One of the areas below. |
| `kind` | `product`, `architecture`, `infra` or `process`. |
| `date` | `YYYY-MM-DD`, the day it was decided. Same as the file name's date. |
| `by` | GitHub logins of who decided, comma separated. An agent writes `claude` and adds the person it worked for. |
| `depends-on` | Ids of decisions this one builds on. |
| `supersedes` | Ids of decisions this one replaces. Set each of those to `status: superseded`. |
| `refs` | Commits, issues or files. |

`## Context` and `## Decision` are required. `## Rejected alternatives` is
optional but usually the most useful part.

## Areas

`app` (the iOS app), `viewer` (a space's page), `prints` (the list of every
space), `site` (the public pages), `worker` (scan to plan and model),
`privacy`, `release` (TestFlight, signing), `infra`.

Pick the one a reader would look in first. New areas go in this list.

## Changing a decision

Don't rewrite history. Write a new decision that `supersedes` the old one
and set the old one's `status` to `superseded`. Fixing a typo or adding a ref
in place is fine.
