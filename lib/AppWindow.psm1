# Where the StreamHub app opens (setting appWindow):
#   copilot-tab   as a tab in the Copilot window (StreamHub's own Edge), next to the Copilot tab, so
#                 Edge's Split screen shows both in one window (one click; Edge has no API for it)
#   side-by-side  as an app window in the normal Edge, with the Copilot window: each half the screen
#   browser       in the default browser (as before)
# The opening runs in the background: Copilot's Edge starts only when StreamHub connects to it.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')

function Test-LocalPageUrl([string]$Url, [int]$Port = 0) {
    <# Whether a tab shows a local page (StreamHub itself, a page check) rather than Copilot. #>
    $m = [regex]::Match("$Url", '^(?i)https?://(localhost|127\.0\.0\.1|\[::1\])(:(\d+))?(/|$)')
    if (-not $m.Success) { return $false }
    if ($Port -and $m.Groups[3].Success -and [int]$m.Groups[3].Value -ne $Port) { return $false }
    $true
}

function Select-AppWindows {
    <# From visible top-level windows (@{ handle; pid; title }) picks the Copilot window (a window
       of StreamHub's Edge, $CopilotPids) and the StreamHub app window (title StreamHub, another
       process). Returns @{ copilot; app } (handles or $null). #>
    param($Windows, [int[]]$CopilotPids)
    $copilot = @($Windows | Where-Object { $CopilotPids -contains [int]$_.pid -and "$($_.title)".Trim() } | Select-Object -First 1)
    $app = @($Windows | Where-Object { $CopilotPids -notcontains [int]$_.pid -and "$($_.title)" -match '^StreamHub\b' } | Select-Object -First 1)
    @{ copilot = $(if ($copilot.Count) { $copilot[0].handle } else { $null }); app = $(if ($app.Count) { $app[0].handle } else { $null }) }
}

function Get-HalfRects {
    <# The left and right halves of a work area @{ x; y; width; height }. #>
    param($Area)
    $w = [int][Math]::Floor($Area.width / 2)
    @{ left = @{ x = $Area.x; y = $Area.y; width = $w; height = $Area.height }; right = @{ x = $Area.x + $w; y = $Area.y; width = $Area.width - $w; height = $Area.height } }
}

function Initialize-Win32 {
    if ('CcbWin' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CcbWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    public static List<object[]> List() {
        var list = new List<object[]>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(h, sb, sb.Capacity);
            uint pid; GetWindowThreadProcessId(h, out pid);
            list.Add(new object[] { h, (int)pid, sb.ToString() });
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
}

function Get-TopWindows {
    Initialize-Win32
    foreach ($w in [CcbWin]::List()) { @{ handle = $w[0]; pid = $w[1]; title = $w[2] } }
}

function Get-CopilotEdgePids {
    <# Processes of StreamHub's own Edge (its profile folder is on their command line). #>
    @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { "$($_.CommandLine)" -match 'CCBridge\\edge-profile' } | ForEach-Object { [int]$_.ProcessId })
}

function Set-WindowsSideBySide {
    <# StreamHub left, Copilot right, each half of the primary screen's work area. Waits up to
       $WaitSec for both windows. Returns whether it arranged them. #>
    param([int]$WaitSec = 150)
    Initialize-Win32
    Add-Type -AssemblyName System.Windows.Forms
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        $pick = Select-AppWindows @(Get-TopWindows) (Get-CopilotEdgePids)
        if ($pick.copilot -and $pick.app) {
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $r = Get-HalfRects @{ x = $wa.X; y = $wa.Y; width = $wa.Width; height = $wa.Height }
            foreach ($p in @(@($pick.app, $r.left), @($pick.copilot, $r.right))) {
                [void][CcbWin]::ShowWindow($p[0], 9)   # restore if maximised or minimised
                [void][CcbWin]::SetWindowPos($p[0], [IntPtr]::Zero, $p[1].x, $p[1].y, $p[1].width, $p[1].height, 0x0040)
            }
            return $true
        }
        Start-Sleep -Milliseconds 1000
    }
    $false
}

function Open-AppInCopilotWindow {
    <# Opens the app as a tab in StreamHub's Edge (next to Copilot) once it runs; an app tab that is
       already there is brought to the front instead (so an Edge split stays). Falls back to the
       default browser when that Edge does not come up within $WaitSec. #>
    param([string]$Url, [int]$AppPort, [int]$CdpPort, [int]$WaitSec = 150)
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        try { $null = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 2; $up = $true; break } catch { Start-Sleep -Milliseconds 1000 }
    }
    if (-not $up) { Start-Process $Url; return 'browser' }
    $pages = @((Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/list") | Where-Object { $_.type -eq 'page' })
    $existing = @($pages | Where-Object { (Test-LocalPageUrl $_.url $AppPort) -and $_.url -notmatch '/preview/' } | Select-Object -First 1)
    if ($existing.Count) {
        $null = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/activate/$($existing[0].id)"
        return 'existing-tab'
    }
    $t = Invoke-RestMethod -Method Put "http://127.0.0.1:$CdpPort/json/new?$Url"
    $null = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/activate/$($t.id)"
    'new-tab'
}

function Test-AppTabInEdge {
    <# Whether the app runs as a tab in StreamHub's Edge (next to Copilot, for Split screen). #>
    param([int]$AppPort, [int]$CdpPort)
    try {
        $pages = @((Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/list" -TimeoutSec 2) | Where-Object { $_.type -eq 'page' })
        [bool]@($pages | Where-Object { (Test-LocalPageUrl $_.url $AppPort) -and $_.url -notmatch '/preview/' }).Count
    } catch { $false }
}

function Test-ExternalLink([string]$Url) {
    <# A web address the app may open in a new tab: http or https, not a local page. #>
    ($Url -match '^(?i)https?://[^\s]+$') -and -not (Test-LocalPageUrl $Url)
}

function Open-LinkInEdgeTab {
    <# Opens a link as a new tab in StreamHub's Edge. Needed because in Edge's Split screen a link
       clicked in one pane opens in the other pane (replacing Copilot), even with target=_blank;
       a tab created through Edge's own command (Target.createTarget) is a real new tab.
       Returns 'new-tab', or 'not-here' when the app is not a tab in that Edge (the browser
       opens the link itself then). #>
    param([Parameter(Mandatory)][string]$Url, [int]$AppPort, [int]$CdpPort, [string]$PreviewPrefix = '')
    # Besides web links: the project's own pages on the read-only preview address (Open app).
    $preview = $PreviewPrefix -and $Url.StartsWith($PreviewPrefix, [StringComparison]::OrdinalIgnoreCase) -and $Url -notmatch '\s'
    if (-not $preview -and -not (Test-ExternalLink $Url)) { throw 'only http and https links to other sites are opened' }
    if (-not (Test-AppTabInEdge $AppPort $CdpPort)) { return 'not-here' }
    $browser = (Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 2).webSocketDebuggerUrl
    $s = Connect-Cdp $browser
    try { $null = Invoke-Cdp $s 'Target.createTarget' @{ url = $Url } } finally { Disconnect-Cdp $s }
    'new-tab'
}

function Start-AppWindow {
    <# Opens the StreamHub app the way the appWindow setting says, in the background. #>
    param([Parameter(Mandatory)][string]$Url, [string]$Mode = 'copilot-tab', [int]$AppPort, [int]$CdpPort, [string]$EdgePath)
    if ($Mode -eq 'browser') { Start-Process $Url; return }
    $me = Join-Path $PSScriptRoot 'AppWindow.psm1'
    $log = Join-Path $PSScriptRoot 'Log.psm1'
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($me, $log, $Url, $Mode, $AppPort, $CdpPort, $EdgePath)
        Import-Module $log; Import-Module $me
        try {
            if ($Mode -eq 'side-by-side') {
                $have = @(Get-TopWindows | Where-Object { "$($_.title)" -match '^StreamHub\b' }).Count
                if (-not $have) {
                    if ($EdgePath -and (Test-Path -LiteralPath $EdgePath)) { Start-Process $EdgePath "--app=$Url" } else { Start-Process $Url }
                }
                $ok = Set-WindowsSideBySide
                Write-CCBLog info app "Side by side: $(if ($ok) { 'arranged' } else { 'windows not found in time' })"
            } else {
                $how = Open-AppInCopilotWindow $Url $AppPort $CdpPort
                Write-CCBLog info app "App opened in the Copilot window: $how"
            }
        } catch { Write-CCBLogError app 'Opening the app window failed' $_; try { Start-Process $Url } catch { } }
    }).AddArgument($me).AddArgument($log).AddArgument($Url).AddArgument($Mode).AddArgument($AppPort).AddArgument($CdpPort).AddArgument($EdgePath)
    $script:Opener = @{ ps = $ps; handle = $ps.BeginInvoke() }
}

Export-ModuleMember -Function Test-AppTabInEdge, Test-ExternalLink, Open-LinkInEdgeTab, Test-LocalPageUrl, Select-AppWindows, Get-HalfRects, Get-TopWindows, Get-CopilotEdgePids, Set-WindowsSideBySide, Open-AppInCopilotWindow, Start-AppWindow
