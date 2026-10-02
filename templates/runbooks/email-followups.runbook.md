---
title: Emails waiting for my reply
output: exports/email-followups.json
itemsKey: emails
required: generatedAt, period, emails, truncated
requiredItemFields: subject, from, received, ask, priority
---
<!--
Exports emails that still need an answer or action from me. Adjust the period or the priority
rules to your way of working.
-->
# Purpose
A list of emails where someone is waiting for me, so nothing falls through the cracks.

# Sources
- My Outlook mailbox: Inbox and its subfolders.
- Leave out newsletters, automated notifications, calendar invitations, and mail I sent myself.

# Period
Emails received from {{today-14d}} to {{today}} (inclusive), in my time zone ({{timezone}}).

# What to include
- Emails that ask me a question, ask me to do or decide something, or wait for my approval,
  and that I have not replied to (no reply from me later in the same conversation).
- One entry per conversation: use the latest message that still waits for me.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "emails": [
    {
      "subject": "string",
      "from": "display name",
      "received": "ISO 8601 date-time with offset",
      "ask": "what is asked of me, one sentence",
      "dueDate": "YYYY-MM-DD or null",
      "priority": "high | normal | low",
      "waitingDays": 0,
      "hasAttachments": false
    }
  ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone.
- dueDate: only when the email names a date or deadline; otherwise null. Never invent a deadline.
- priority: high = marked important, a deadline within 3 days, or from my manager; low = FYI-like
  requests without a deadline; otherwise normal.
- waitingDays: whole days between received and {{today}}.
- People: display names; no email addresses. ask: plain text, at most 200 characters.

# Quality rules
- Include every email that matches; do not summarise or merge conversations into one entry.
- Sort by priority (high first), then by received (oldest first).
- If you cannot include every email, include as many as you can and set "truncated" to true.
- Read-only: only read email. Do not reply, forward, flag, move, mark as read or delete anything.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-09-21", "to": "2026-10-05" },
  "emails": [
    {
      "subject": "Budget review Q4",
      "from": "Sam Jansen",
      "received": "2026-10-02T14:12:00+02:00",
      "ask": "Approve the revised Q4 budget before Friday.",
      "dueDate": "2026-10-09",
      "priority": "high",
      "waitingDays": 3,
      "hasAttachments": true
    }
  ],
  "truncated": false
}
```
