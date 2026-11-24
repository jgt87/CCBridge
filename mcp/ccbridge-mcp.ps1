<#
.SYNOPSIS
  The MCP server's script under its name from before the rename (pre-rename name, kept on purpose).
  An MCP client registered before the rename starts this file; it runs mcp\streamhub-mcp.ps1 in
  the same process, so the client keeps working until it is registered again as streamhub with
  mcp\streamhub-mcp.ps1 (tools\rebrand-check.ps1 prints the command). Writes nothing itself:
  stdout is the protocol channel.
#>
& (Join-Path $PSScriptRoot 'streamhub-mcp.ps1')
