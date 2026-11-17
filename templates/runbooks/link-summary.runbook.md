---
title: Summary of a Microsoft 365 or web link
output: Runbooks/Exports/link-summary.json
itemsKey: keyFacts
required: generatedAt, link, readable, problem, title, where, kind, summary, keyFacts, useFor, sensitivity
link: https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q4%20planning.xlsx
---
<!--
Summarises one item behind a link: a SharePoint page or file, a OneDrive document, a Teams or Loop
item, or a public web page. Copilot opens it with your own access and says plainly when it cannot.
Put the link in the header above ("link: ..."); it is used as {{link}} below. Run it again later
to see what changed: the earlier answer is kept in .streamhub/History/.
-->
# Purpose
A short, factual summary of what is behind one link, so I know what it is and whether to use it.

# Sources
- Only the item at this link: {{link}}
- Open it yourself, with my own Microsoft 365 access when it is a Microsoft 365 item. Do not use
  other files, mail or chats to fill gaps.

# What to include
- What the item is, where it lives, and what it says: its main points and the facts someone would
  look for (figures, dates, decisions, owners).
- When you cannot open or read it, say why in "problem" and leave the content fields null.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "link": "the link exactly as given",
  "readable": true,
  "problem": "no-access | not-found | other, or null when readable",
  "title": "the item's title, or null",
  "where": "site, team, OneDrive folder or website, or null",
  "kind": "page | document | spreadsheet | presentation | pdf | list | loop | web-page | other, or null",
  "summary": "two to four sentences, or null",
  "keyFacts": ["one fact per entry, at most 8"],
  "useFor": "what the item is useful for, one sentence, or null",
  "sensitivity": "the sensitivity label shown on the item, or null when none is shown"
}
```

# Field rules
- readable: false when you could not open or read the item; then problem says why (no-access: you
  are not allowed to open it; not-found: it does not exist or moved; other: anything else) and
  title, summary, keyFacts and useFor are null or empty.
- generatedAt: ISO 8601 with the UTC offset of my time zone ({{timezone}}), now is {{now}}.
- keyFacts: plain text, each at most 200 characters, taken from the item; never guessed.
- sensitivity: only a label Microsoft 365 shows on the item (for example Confidential); never
  judge it yourself.
- People: display names; no email addresses.

# Quality rules
- Only what the item itself says; when something is unclear, leave it out rather than guess.
- Read-only: only read. Do not share, move, rename, edit or delete anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "link": "https://contoso.sharepoint.com/sites/Finance/Shared%20Documents/Q4%20planning.xlsx",
  "readable": true,
  "problem": null,
  "title": "Q4 planning",
  "where": "Finance team site, Shared Documents",
  "kind": "spreadsheet",
  "summary": "Quarterly budget per department with the revised forecast. The forecast was lowered after the September review.",
  "keyFacts": ["Total Q4 budget 1.2 million", "Marketing reduced by 8 percent", "Review on 14 October"],
  "useFor": "Checking a department's Q4 budget before spending.",
  "sensitivity": "Confidential"
}
```
