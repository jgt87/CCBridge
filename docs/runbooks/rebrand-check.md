# Runbook: check the rename on an installed PC

StreamHub was called CCBridge before 2026-11-24. The first release after the rename moves the data
folder (`%LOCALAPPDATA%\CCBridge` to `%LOCALAPPDATA%\StreamHub`) and the projects folder
(`OneDrive\CCBridge` to `OneDrive\StreamHub`) by itself at a start, as soon as nothing uses them.
The install folder keeps its name. The MCP server gets the id `streamhub`.

Do the steps in order, on the PC where StreamHub is installed. Each step says what you should see,
and what to send when you see something else. Nothing here deletes anything.

Where `INSTALL` appears below: `%LOCALAPPDATA%\Programs\CCBridge` for an install from before the
rename, `%LOCALAPPDATA%\Programs\StreamHub` for a new one.

## 1. Update

Start StreamHub from its shortcut (desktop or Start menu), as always.

- **You should see:** in the console window `[StreamHub update] updated v0.1.x -> v0.1.y`, then the
  system check and the app.
- **If not** (no update line, or an error): wait until the app is open, then double-click
  `INSTALL\update.cmd` and send the text it shows (copied, not a photo), or the zip that
  `INSTALL\diagnostics.cmd` puts on the Desktop.

## 2. Let the folders move

The start right after the update still runs the old start script, so the folders keep their old
name this time. Close StreamHub (its console window) and close the Edge window StreamHub opened
(the one with Copilot). Then start StreamHub again from the shortcut.

- **You should see:** the app opens as before, with your projects, and Copilot is still signed in.
  No yellow line "StreamHub keeps using its folders under their old name" in the console.
- **If you see that yellow line:** something still uses a folder (another StreamHub window, an MCP
  client with StreamHub running, a file open in a project). Close it and start StreamHub once more.
  If the line stays, go on with step 3: its log names what uses the folder.
- **If Copilot asks you to sign in:** sign in once (choose "Stay signed in"), then go on with step 3
  and say so when you send the log.

## 3. Run the check

Open Windows PowerShell and run (one line):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "INSTALL\tools\rebrand-check.ps1"
```

- **You should see:** a report ending in `Log (masked, safe to send): ...StreamHub-rebrand-check-<time>.txt`,
  and Explorer opens on that file on the Desktop. In the report:
  - `[Data folder] state: new name only`
  - `[Projects folder] state: new name only`
  - under `[Move, from the log]` lines like `Data folder: moved ... to ...StreamHub`
  - under `[Shortcuts]` `StreamHub.lnk -> ...start.cmd` without `(TARGET MISSING)`
- **If not** (`old name only`, `both`, `TARGET MISSING`, or an error): send the log file from the
  Desktop as it is.

## 4. Register the MCP server again (only if you use StreamHub from an MCP client)

The report's `[MCP server]` part, and the last lines in the console, give two commands: one removes
the old entry `ccbridge`, one adds `streamhub` with the new script `mcp\streamhub-mcp.ps1`. Put the
command of your MCP client's command-line tool in front of each (the tool you used to add ccbridge),
run them, and restart the MCP client. A client that uses a JSON config instead: rename the entry
`ccbridge` to `streamhub` and set its last argument to the path the report shows.

- **You should see:** the client lists the server `streamhub` as connected, with the same
  `copilot_*` tools as before, and no longer lists `ccbridge`.
- **If not:** send the log from step 3 and the client's error text for the server (no screenshots
  needed).
- Until you do this step the old entry keeps working: `mcp\ccbridge-mcp.ps1` starts the new server.

## 5. Send the result

Send the file `StreamHub-rebrand-check-<time>.txt` from the Desktop. It holds no user name, email
address, profile or OneDrive path, and no project or Copilot content: only folder states, file
names of StreamHub itself and the move lines of its log.
