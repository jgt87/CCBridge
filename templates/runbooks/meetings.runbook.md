---
title: Meetings in a period
output: Runbooks/Exports/meetings.json
itemsKey: meetings
required: generatedAt, period, meetings, truncated
requiredItemFields: subject, start, end, organizer, isOnline, myResponse, isCancelled
---
<!--
Exports my calendar events in a period. Change the period under "Period" (for example
{{weekStart}} to {{weekEnd}}, or {{today}} to {{today+14d}}).
-->
# Purpose
A complete, machine-readable list of my meetings in the period, for planning and reporting.

# Sources
- My Outlook calendar (meetings and appointments I organise or am invited to).
- Do not use other people's calendars, shared calendars or room calendars.

# Period
From {{today}} to {{today+7d}} (inclusive), in my time zone ({{timezone}}).

# What to include
- Every event that starts in the period, including all-day events, recurring occurrences, and
  meetings I have not answered yet.
- Include cancelled meetings that are still in my calendar, with "isCancelled": true.
- Leave out private appointments' details: for events marked private, keep only start, end and
  "subject": "Private".

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "meetings": [
    {
      "subject": "string",
      "start": "ISO 8601 date-time with offset",
      "end": "ISO 8601 date-time with offset",
      "isAllDay": false,
      "organizer": "display name",
      "attendees": [ { "name": "display name", "response": "accepted | tentative | declined | none", "type": "required | optional" } ],
      "location": "string or null",
      "isOnline": true,
      "myResponse": "organizer | accepted | tentative | declined | none",
      "isRecurring": false,
      "isCancelled": false,
      "categories": [ "string" ],
      "agendaSummary": "one sentence from the invitation text, or null"
    }
  ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone, for example 2026-10-05T09:30:00+02:00.
  All-day events: start at 00:00 of the first day, end at 00:00 of the day after the last day.
- Unknown or unavailable values: null. Never guess or invent values.
- People: display names as shown in Outlook; no email addresses.
- attendees: everyone on the invitation except me; at most 30 per meeting (then add
  { "name": "+N more", "response": "none", "type": "required" }).
- agendaSummary: plain text, at most 200 characters; null when the invitation has no text.

# Quality rules
- Include every matching event; do not summarise, merge or skip events.
- One entry per occurrence of a recurring meeting.
- Sort by start, earliest first.
- If you cannot include every event, include as many as you can and set "truncated" to true.
- Read-only: only read the calendar. Do not accept, decline, propose times, forward or change anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-10-05", "to": "2026-10-12" },
  "meetings": [
    {
      "subject": "Weekly planning",
      "start": "2026-10-05T09:30:00+02:00",
      "end": "2026-10-05T10:00:00+02:00",
      "isAllDay": false,
      "organizer": "Sam Jansen",
      "attendees": [ { "name": "Alex de Vries", "response": "accepted", "type": "required" } ],
      "location": null,
      "isOnline": true,
      "myResponse": "accepted",
      "isRecurring": true,
      "isCancelled": false,
      "categories": [],
      "agendaSummary": "Plan the work for the week and check open risks."
    }
  ],
  "truncated": false
}
```
