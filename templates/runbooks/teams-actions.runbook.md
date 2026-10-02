---
title: Decisions and action items from Teams
output: exports/teams-actions.json
itemsKey: items
required: generatedAt, period, items, truncated
requiredItemFields: kind, text, source, date, owner, status
---
<!--
Exports decisions and action items from Teams meetings (recaps and transcripts) and Teams chats.
-->
# Purpose
One list of what was decided and who does what, so follow-ups can be tracked.

# Sources
- Teams meetings I attended: meeting recaps, notes and transcripts where available.
- Teams chats and channel conversations I am part of.
- Leave out email and documents.

# Period
From {{today-7d}} to {{today}} (inclusive), in my time zone ({{timezone}}).

# What to include
- Decisions: a choice that was made or agreed ("we go with option B").
- Action items: a task someone agreed or was asked to do ("Alex will send the figures by Friday").
- Leave out ideas, questions and discussions without a decision or task.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "items": [
    {
      "kind": "decision | action",
      "text": "the decision or task, one sentence",
      "source": { "type": "meeting | chat | channel", "name": "meeting subject or chat/channel name" },
      "date": "ISO 8601 date-time with offset of the meeting or message",
      "owner": "display name, or null for decisions",
      "dueDate": "YYYY-MM-DD or null",
      "status": "open | done | unknown",
      "isMine": false
    }
  ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone.
- owner: the person who will do the action; null for decisions. isMine: true when the owner is me.
- dueDate: only when a date or deadline was stated; otherwise null. Never invent dates.
- status: done only when it was later confirmed as done in the same meeting or chat; otherwise open,
  or unknown when it cannot be told.
- text: plain text in the language of the source, at most 250 characters.

# Quality rules
- Include every decision and action item; do not summarise several into one.
- Remove duplicates (the same item in a recap and a chat): keep one, with the earliest date.
- Sort by date, oldest first.
- If you cannot include every item, include as many as you can and set "truncated" to true.
- Read-only: only read. Do not post, reply, react, create tasks or change anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-09-28", "to": "2026-10-05" },
  "items": [
    {
      "kind": "action",
      "text": "Send the updated planning to the steering group.",
      "source": { "type": "meeting", "name": "Project steering" },
      "date": "2026-10-01T15:00:00+02:00",
      "owner": "Alex de Vries",
      "dueDate": "2026-10-04",
      "status": "open",
      "isMine": false
    }
  ],
  "truncated": false
}
```
