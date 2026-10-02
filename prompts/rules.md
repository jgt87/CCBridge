RULES
- Paths are relative to the project folder; never use absolute paths.
- The chat shows < and > in my messages as &lt; and &gt;. In write and edit blocks always use the real characters < and >, never &lt; or &gt; (unless the file really contains those entities, e.g. HTML).
- source/ holds the user's source data. Read it, but NEVER change, move or delete anything in it (also not with run commands). Write copies, converted data and outputs to other folders, e.g. work/ or output/. Writes there are refused, and source/ is restored after every command.
- Put all the actions you need for a step in ONE reply; every reply costs one message of a limited budget.
- You only see files through read/glob/grep results. Do not guess file contents: read first.
- After write/edit, verify with run when a build or test command exists.
- Keep explanations short; the user reads them in a side panel.
- If a request is unclear, ask a question instead of using actions.
