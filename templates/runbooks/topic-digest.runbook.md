---
title: Topic digest across mail, meetings and chats
output: exports/topic-digest.json
itemsKey: entries
required: generatedAt, period, topic, entries, openQuestions, truncated
requiredItemFields: date, source, title, summary
topic: Project Apollo
---
<!--
Collects everything about one topic from mail, meetings, chats and files. Set the topic in the
header above ("topic: ..."); it is used as {{topic}} below.
-->
# Purpose
A chronological digest of everything about "{{topic}}", to get up to speed or write a status update.

# Sources
- My mailbox, my calendar and Teams meetings (recaps, notes, transcripts), Teams chats and channels,
  and documents in OneDrive and SharePoint that I have access to.

# Period
From {{today-30d}} to {{today}} (inclusive), in my time zone ({{timezone}}).

# What to include
- Every email, meeting, chat thread and document that is clearly about "{{topic}}" (by name, project
  code, or unmistakable context).
- Leave out items that only mention the topic in passing.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "topic": "{{topic}}",
  "entries": [
    {
      "date": "ISO 8601 date-time with offset",
      "source": "email | meeting | chat | channel | document",
      "title": "subject, meeting name, chat name or file name",
      "people": [ "display name" ],
      "summary": "what this item says about the topic, one or two sentences",
      "decisions": [ "string" ],
      "actions": [ { "text": "string", "owner": "display name or null", "dueDate": "YYYY-MM-DD or null" } ]
    }
  ],
  "openQuestions": [ "question that is still unanswered in the sources" ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone.
- People: display names; no email addresses. At most 10 per entry.
- summary: plain text, at most 300 characters, only what the source says. decisions, actions and
  openQuestions: only when stated in the sources; otherwise empty lists. Never invent them.

# Quality rules
- Include every matching item; one entry per email conversation, meeting, chat thread or document.
- Sort entries by date, oldest first.
- If you cannot include every item, include as many as you can and set "truncated" to true.
- Read-only: only read. Do not send, post, reply, share or change anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-09-05", "to": "2026-10-05" },
  "topic": "Project Apollo",
  "entries": [
    {
      "date": "2026-09-30T11:00:00+02:00",
      "source": "meeting",
      "title": "Apollo steering",
      "people": [ "Sam Jansen", "Alex de Vries" ],
      "summary": "Go-live moved to November because the data migration needs another test round.",
      "decisions": [ "Go-live moves to 15 November." ],
      "actions": [ { "text": "Plan an extra migration test.", "owner": "Alex de Vries", "dueDate": "2026-10-10" } ]
    }
  ],
  "openQuestions": [ "Who signs off the migration test?" ],
  "truncated": false
}
```
