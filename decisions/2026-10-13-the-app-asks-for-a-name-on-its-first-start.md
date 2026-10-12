---
title: The app asks for a name on its first start
status: accepted
area: app
kind: product
date: 2026-10-13
by: p4ulcristian, claude
depends-on:
supersedes:
refs: ios/Sources/Roomprint/NameView.swift, web/server.ts, web/public/admin.html, web/public/privacy.html
---

## Context

The app has no login. The list of every space (`/prints`) groups spaces by a
number each install makes up for itself, so a group reads "Phone 3fa9c1" until
someone on the team works out whose phone that is and names it by hand. With
more testers that guessing does not keep up, and spaces from different people
are hard to tell apart.

## Decision

The first time the app is opened it asks for a name, and nothing else can be
done until one is typed. Any name will do: it is not checked, it does not have
to be real or unique, and it can be changed later in the app's menu.

The name goes to the server with every space the phone makes, and the phone's
older spaces are told about it too (again when the name changes). Phones that
already have the app are asked on their first start after the update.

The made-up number stays, and stays what the list groups by: the name is only
what a group is called. Two phones that pick the same name remain two groups,
each with the short number beside the name. A name the team gives a phone on
the list goes before the one picked in the app, which then shows next to it.

Like the number, the name is never sent to people who open a space's link. The
privacy page lists it among what is uploaded.

## Rejected alternatives

- A login or an email address: more than a test app should ask for, and the
  name is only for telling spaces apart, not for knowing who someone is.
- Grouping by the name instead of the number: names are free text, so two
  people with the same one would be merged and a changed name would split one
  person's spaces in two.
- Leaving it to the team to name phones on the list: it means guessing from
  the scans whose phone it is, every time someone new installs the app.
- Making the name optional: the people who skip it are the ones the list
  cannot tell apart.
