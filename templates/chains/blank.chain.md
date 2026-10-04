---
title: {{title}}
stopOnError: yes
---
<!--
A chain runs its steps one after another, top to bottom. One step per numbered line:

  1. runbook: NAME                       a runbook from Runbooks/ (NAME.runbook.md)
  2. fetch: NAME                         a fetch prompt from Runbooks/ (NAME.prompt.md)
  3. script: Scripts/NAME.ps1 WORDS      a .ps1, .cmd, .bat or .py file in Scripts/, with plain arguments
  4. runbook: NAME with Runbooks/Exports/FILE.json
                                         the runbook also gets these files (from earlier steps) as data

stopOnError: yes stops at the first step that fails; no carries on with the next step.
A script runs in the project folder. StreamHub asks before a script runs for the first time and
after it changed (Settings > Chains). Scripts that delete data or use Microsoft 365 always need
a person to approve them, and deleting or moving outside the project is never allowed.
Comments like this one are notes for you and are not used.
-->

## Steps

1. runbook: FIRST-RUNBOOK
2. script: Scripts/CONVERT.ps1
