---
title: Documents shared with me or changed recently
output: exports/documents-recent.json
itemsKey: documents
required: generatedAt, period, documents, truncated
requiredItemFields: name, type, lastModified, reason
---
<!--
Exports documents (OneDrive, SharePoint, Teams files) that were shared with me or changed in the
period, so they can be reviewed or attached.
-->
# Purpose
A list of documents that need my attention because they were shared with me or changed recently.

# Sources
- Files shared with me in OneDrive, SharePoint and Teams.
- Files I worked on, or that were changed by others, in sites and teams I am a member of.
- Leave out email attachments that are not stored in OneDrive or SharePoint.

# Period
Shared or changed from {{today-7d}} to {{today}} (inclusive), in my time zone ({{timezone}}).

# What to include
- Every document shared with me in the period, and every document I edited or that someone else
  edited in the period.
- Leave out system files, images without context, and items in the recycle bin.

# Output
Answer with only one ```json code block containing a single JSON object in exactly this shape:

```json
{
  "generatedAt": "ISO 8601 date-time with offset",
  "period": { "from": "YYYY-MM-DD", "to": "YYYY-MM-DD" },
  "documents": [
    {
      "name": "file name with extension",
      "type": "word | excel | powerpoint | pdf | onenote | other",
      "location": "site, team or OneDrive folder name, or null",
      "url": "link to the file, or null",
      "owner": "display name, or null",
      "lastModified": "ISO 8601 date-time with offset",
      "lastModifiedBy": "display name, or null",
      "sharedBy": "display name when shared with me, otherwise null",
      "reason": "shared | edited-by-me | edited-by-others",
      "summary": "one sentence about the content, or null"
    }
  ],
  "truncated": false
}
```

# Field rules
- Dates and times: ISO 8601 with the UTC offset of my time zone.
- url: only a link Microsoft 365 provides; never construct one. Otherwise null.
- People: display names; no email addresses.
- summary: plain text, at most 200 characters; null when the content is not available.

# Quality rules
- Include every matching document; one entry per file (most important reason when several apply:
  shared, then edited-by-others, then edited-by-me).
- Sort by lastModified, newest first.
- If you cannot include every document, include as many as you can and set "truncated" to true.
- Read-only: only read. Do not share, move, rename, edit or delete files.

# Example
```json
{
  "generatedAt": "2026-10-05T08:00:00+02:00",
  "period": { "from": "2026-09-28", "to": "2026-10-05" },
  "documents": [
    {
      "name": "Q4 planning.xlsx",
      "type": "excel",
      "location": "Finance team",
      "url": null,
      "owner": "Sam Jansen",
      "lastModified": "2026-10-03T16:40:00+02:00",
      "lastModifiedBy": "Sam Jansen",
      "sharedBy": "Sam Jansen",
      "reason": "shared",
      "summary": "Quarterly budget per department with the revised forecast."
    }
  ],
  "truncated": false
}
```
