---
title: My runbook
output: exports/my-runbook.json
itemsKey: items
required: generatedAt, period, items, truncated
requiredItemFields: id, title, date
---
<!--
HOW TO FILL IN THIS RUNBOOK
- The block between the --- lines is read by the helper program:
  title               shown in the app
  output              where the JSON is saved (a dated copy also goes to exports/history/)
  itemsKey            the name of the list in the JSON
  required            keys the JSON must have (comma separated)
  requiredItemFields  fields every list item must have (comma separated)
  Any other line (for example "topic: Project Apollo") becomes a placeholder {{topic}}.
- Placeholders filled in when the runbook runs: {{today}}, {{now}}, {{weekStart}}, {{weekEnd}},
  {{monthStart}}, {{monthEnd}}, {{today-7d}}, {{today+14d}} (any number of days), {{timezone}}.
- Be precise: say exactly which sources, which period, which fields and what to leave out.
- Keep the output schema and the example in sync. The helper program checks the JSON against
  "required" and "requiredItemFields" and asks Copilot to correct it once when it does not match.
- This comment is not sent to Copilot.
-->
# Purpose
Describe in one or two sentences what this export is for and who uses it.

# Sources
- Which Microsoft 365 data to use (for example: my Outlook calendar, my mailbox, Teams chats and meeting
  recaps, OneDrive and SharePoint files shared with me).
- Which data NOT to use.

# Period
From {{today-7d}} to {{today}} (inclusive), in my time zone ({{timezone}}).

# What to include
- The exact condition an item must meet.
- What to do with borderline cases.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "items": [
    {
      "id": "stable identifier from the source, or null",
      "title": "string",
      "date": "ISO 8601 date-time with offset",
      "source": "calendar | email | teams | file",
      "notes": "string or null"
    }
  ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone, for example 2026-10-05T09:30:00+02:00.
- Unknown or unavailable values: null. Never guess or invent values.
- People: display name as shown in Microsoft 365; no email addresses unless a field asks for them.
- Text fields: plain text, no markdown, at most 300 characters.

# Quality rules
- Include every item that matches; do not summarise, merge or skip items.
- Remove exact duplicates (same id, or same title and date).
- Sort the items by date, oldest first.
- If you cannot include every item, include as many as you can and set "truncated" to true.
- Read-only: only read Microsoft 365 data. Do not send, reply, accept, decline, change or delete anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-09-28", "to": "2026-10-05" },
  "items": [
    { "id": "AAMk...", "title": "Example item", "date": "2026-10-01T10:00:00+02:00", "source": "calendar", "notes": null }
  ],
  "truncated": false
}
```
