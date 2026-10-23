@AGENTS.md

## Lessons from earlier sessions (mistakes not to repeat)

Read and follow this list in every session. When a mistake happens (a failed gate, a wrong assumption, a tool pitfall), add it here as one short, general bullet before the session ends.

- **Run Pester with the machine module path.** Windows PowerShell 5.1 started from pwsh 7 inherits 7's `PSModulePath`, and then `Get-FileHash`, `Import-PowerShellDataFile` and other Utility script-module commands are missing. Set `$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath','Machine')` first. Never use those commands in `lib/` (`tests/Repository.Tests.ps1` guards it).
- **Changing wording in `prompts/` or `templates/`?** Grep `tests/` for the old wording before the release gate. Tests pin rule lines (for example the UI kit rule lines in `UiKit.Tests.ps1`) and the prompt budget (`Prompts.Tests.ps1`). A gate run that fails on this costs a full suite run.
- **Prompt budget.** Don't move a rule to a weaker place (`reminder.md` only) just to fit under the budget. Say what it costs, and ask whether to widen the budget.
- **Text sent to Copilot already carries the request.** `Format-TaskMessage` adds the request and removes copies of it from the rest of the message. A message that quotes the request again ends up with an empty quote: refer to "the request above" instead.
- **Follow-ups that report a failure are change requests.** When adding a new kind of follow-up, check what `Get-TaskIntent` makes of it. An 'answer' intent tells Copilot not to change files, which was the real cause of "nothing happened" reports.
- **Kit file changes** (`templates/ui-kit/*.js|css`) need `tools/update-kit-history.ps1` afterwards, or `UiKit.Tests` fails at the gate.
- **Subagents and forks.**
  - Give each one its own files, and tell it not to build `ui/`, commit or run `update-kit-history`.
  - Run the combined checks only after all of them are done: `tsc -b`, lint, all vitest, `npm run build`, the kit Pester tests and the 0x08 check. Errors a fork reports in another fork's files are usually work still in progress.
  - Read their patches for duplicated blocks; once a reviewer's patch duplicated whole functions in `SqlServer.psm1`.
  - Usage limits stop them; resume with SendMessage, one at a time.
  - Tell each one never to run `git stash`, `git checkout -- .`, `git reset` or anything else that touches the whole tree: they share one working tree, and a stash hides every other fork's work in progress. To compare with the committed version, use `git show HEAD:PATH` or `git diff`.
- **Line endings.** After scripted edits, check that a file has not ended up with mixed LF/CRLF endings, and normalise it to the file's majority.
- **A gate failure in code the release did not touch:** run that test file on its own (twice) before changing anything. If it passes, run the gate again and tell the user it looked flaky (as `Issues.Tests.ps1` "The fix cycle cannot loop" did in v0.1.147). If it fails again, find the cause.
- **Repowise health findings.**
  - The "long function" in `lib/page-content-check.js`, `templates/ui-kit/kit.js` and `kit-charts.js` is each file's single outer wrapper. It must stay one expression or IIFE: the page check is evaluated as one expression, and the kit files use `if (window.KitUI) return` / `if (window.KitCharts) return`. That finding is a false positive.
  - The swallowed errors there are intended: one failing part or check must not stop the rest.
  - Say so instead of restructuring, and act only on the named inner functions.
- **Writing new PowerShell: re-read the 5.1 rules in AGENTS.md first.** Two of them bit again in `tools/run-tests.ps1`: `ConvertFrom-Json` in a pipeline passes a JSON array on as one object, and a variable that differs from a parameter only in case (`$files` vs `[string[]]$Files`) overwrites and converts it.
- **Look at real data before suggesting improvements.** The log in `%LOCALAPPDATA%\CCBridge\logs` mixes test runs and real use (tests wrote there until v0.1.150): tell them apart by the process header line (build and role) before drawing conclusions.
- **Shell text with backslashes:** use the Write/Edit tools, never Bash heredocs or `python -c` (AGENTS.md has the details). It went wrong several times even so: after any scripted edit, check regexes and paths such as `Replace('\','/')`, `[\\/]` and `\n` byte for byte.
