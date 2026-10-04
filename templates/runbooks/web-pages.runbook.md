---
title: Data from web pages
output: Runbooks/Exports/web-pages.json
itemsKey: items
required: generatedAt, items, truncated
requiredItemFields: name, value, url
sources: web
sites: example.com
pages: https://example.com/
---
<!--
Takes exact facts (versions, prices, dates, figures) from public web pages into JSON.
- sources: web     Copilot uses the web only, not your work data.
- sites: ...       the only websites Copilot may use (comma separated). Sources it cites outside
                   them are noted when the runbook has run.
- pages: ...       addresses the helper program reads itself before sending (space or comma
                   separated); their text goes to Copilot as data. Use this for exact figures.
Replace example.com with your own sites and pages, and describe below what to take from them.
-->
# Purpose
Collect the facts named below from the pages and sites in the header, exactly as they are published.

# Sources
- Only the websites in the header; the page texts that come with this message come first.
- Not my work data (mail, meetings, chats, files).

# What to include
- One item per fact: for example a product's current version, a plan's monthly price, a release date.
- Only facts the pages state themselves; when a fact is not on the pages, leave it out and say so in "missing".

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "items": [
    {
      "name": "what the fact is, for example 'Pro plan monthly price'",
      "value": "the value exactly as published, as a string",
      "url": "the address of the page it comes from",
      "pageDate": "the page's date when it shows one (YYYY-MM-DD), or null"
    }
  ],
  "missing": ["facts that were asked for but not found"],
  "truncated": false
}
```

# Field rules
- value: copied exactly, with its unit or currency; never rounded, converted or guessed.
- url: the page the value was read on; never a search results page.
- Unknown values: null. Never invent values.

# Quality rules
- Include every fact asked for that the pages state.
- If you cannot include every item, include as many as you can and set "truncated" to true.
- Read-only: only read web pages.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "items": [
    { "name": "Example product latest version", "value": "4.2.1", "url": "https://example.com/releases", "pageDate": "2026-09-30" }
  ],
  "missing": [],
  "truncated": false
}
```
