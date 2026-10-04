---
title: {{title}}
stopOnError: yes
---
<!--
A chain runs its steps one after another, top to bottom. Add steps in the app (Automation >
Chains > Add step), or write one step per numbered line under Steps:

  1. runbook: NAME                       a runbook from Runbooks/ (NAME.runbook.md or NAME.prompt.md)
  2. script: Scripts/NAME.ps1 WORDS      a .ps1, .cmd, .bat or .py file in Scripts/, with plain arguments
  3. runbook: NAME with Runbooks/Exports/FILE.json
                                         the runbook also gets these files (from earlier steps) as data

stopOnError: yes stops at the first step that fails; no carries on with the next step.
A script runs in the project folder. The helper program asks before a script runs for the first time and
after it changed (Settings > Chains). Scripts that delete data or use Microsoft 365 always need
a person to approve them, and deleting or moving outside the project is never allowed.
Comments like this one are notes for you and are not used.
-->

## Steps
