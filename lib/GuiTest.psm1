# The start test of a PowerShell window app (WPF or Windows Forms) after a task that changed it: the
# script runs with STREAMHUB_GUI_TEST set (the app then shows its window without doing work), StreamHub
# waits for the window, takes a picture of it (PrintWindow, also when it is behind other windows) and
# closes it. Errors at start and a window that never opens go back to Copilot. A script that works with
# Microsoft 365 or deletes files is not started (Executor Get-CommandRisk on its text).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:WinApi = $null
function Initialize-WinApi {
    if ($script:WinApi) { return }
    if (-not ('CcbWindowShot' -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class CcbWindowShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    public static string Title(IntPtr h) { var s = new System.Text.StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
    public static bool Save(IntPtr h, string path) {
        RECT r; if (!GetWindowRect(h, out r)) return false;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w < 10 || ht < 10) return false;
        // The visible frame, without the invisible border Windows draws the shadow in.
        RECT f; if (DwmGetWindowAttribute(h, 9, out f, Marshal.SizeOf(typeof(RECT))) != 0) f = r;
        var crop = new Rectangle(Math.Max(0, f.Left - r.Left), Math.Max(0, f.Top - r.Top), Math.Min(w, f.Right - f.Left), Math.Min(ht, f.Bottom - f.Top));
        using (var bmp = new Bitmap(w, ht)) {
            using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); try { PrintWindow(h, dc, 2); } finally { g.ReleaseHdc(dc); } }
            if (crop.Width < 10 || crop.Height < 10 || crop.Right > w || crop.Bottom > ht) crop = new Rectangle(0, 0, w, ht);
            using (var part = bmp.Clone(crop, bmp.PixelFormat)) part.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return true;
    }
}
'@
    }
    $script:WinApi = $true
}

function Find-GuiScripts {
    <# The window app scripts a task changed (or whose .xaml it changed): PowerShell scripts that open a
       window (ShowDialog, Application Run, XamlReader). At most two. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Changed)
    $root = $ProjectRoot.TrimEnd('\')
    $paths = @($Changed | ForEach-Object { "$_".Replace('\', '/') })
    $out = New-Object System.Collections.Generic.List[string]
    $isGui = { param($t) $t -match '(?i)\.ShowDialog\(|\]::Run\(|XamlReader' -and $t -match '(?i)PresentationFramework|System\.Windows\.Forms' }
    foreach ($p in $paths) {
        if ($p -notmatch '(?i)\.ps1$' -or $p -match '(?i)\.Tests\.ps1$|^Scripts/(Build-App|Refresh-Data)\.ps1$') { continue }
        $full = Join-Path $root $p.Replace('/', '\')
        if ((Test-Path -LiteralPath $full) -and (& $isGui ([IO.File]::ReadAllText($full))) -and -not $out.Contains($p)) { $out.Add($p) }
    }
    $xaml = @($paths | Where-Object { $_ -match '(?i)\.xaml$' -and $_ -notmatch '(?i)^styles/kit/' } | ForEach-Object { Split-Path $_ -Leaf })
    if ($xaml.Count) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub|Source)\\' } | Select-Object -First 200)) {
            $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
            $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
            if ((& $isGui $t) -and @($xaml | Where-Object { $t.Contains($_) }).Count -and -not $out.Contains($rel)) { $out.Add($rel) }
        }
    }
    @($out | Select-Object -First 2)
}

function Get-ProcessTreeIds([int]$RootId) {
    # The process and its children (an app that starts itself again, for example with -STA).
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $ids = New-Object System.Collections.Generic.List[int]; $ids.Add($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) { foreach ($c in $all) { if ([int]$c.ParentProcessId -eq $ids[$i] -and -not $ids.Contains([int]$c.ProcessId)) { $ids.Add([int]$c.ProcessId) } } }
    $ids.ToArray()
}

function Test-PsGuiApp {
    <# Starts the window app, waits for its window, saves a picture of it ($ShotPath) and closes it.
       Returns @{ opened; title; shot; errors; exitCode; skipped }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Script, [string]$ShotPath = '', [int]$WaitSec = 20)
    $full = Join-Path $ProjectRoot $Script.Replace('/', '\')
    $text = [IO.File]::ReadAllText($full)
    $risk = Get-CommandRisk $text
    if ($risk.m365 -or $risk.destructive) { return [pscustomobject]@{ opened = $false; title = ''; shot = ''; errors = @(); exitCode = $null; skipped = 'the script works with Microsoft 365 or deletes files, so StreamHub does not start it by itself' } }
    Initialize-WinApi
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$full`""
    $psi.WorkingDirectory = Split-Path $full
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $true
    $psi.EnvironmentVariables['STREAMHUB_GUI_TEST'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync(); $outTask = $p.StandardOutput.ReadToEndAsync()
    $hwnd = [IntPtr]::Zero; $title = ''; $shot = ''
    $until = (Get-Date).AddSeconds($WaitSec)
    try {
        while ((Get-Date) -lt $until -and $hwnd -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 300
            foreach ($id in @(Get-ProcessTreeIds $p.Id)) {
                $q = Get-Process -Id $id -ErrorAction SilentlyContinue
                if ($q -and $q.MainWindowHandle -ne [IntPtr]::Zero) { $hwnd = $q.MainWindowHandle; break }
            }
            if ($p.HasExited -and $hwnd -eq [IntPtr]::Zero) { break }
        }
        if ($hwnd -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 1200   # let the window draw itself
            $title = [CcbWindowShot]::Title($hwnd)
            if ($ShotPath) { $null = New-Item -ItemType Directory -Force -Path (Split-Path $ShotPath); if ([CcbWindowShot]::Save($hwnd, $ShotPath)) { $shot = $ShotPath } }
        }
    } finally {
        foreach ($id in @(Get-ProcessTreeIds $p.Id | Sort-Object -Descending)) {
            $q = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($q) { try { $null = $q.CloseMainWindow() } catch { } }
        }
        if (-not $p.WaitForExit(3000)) { foreach ($id in @(Get-ProcessTreeIds $p.Id)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    }
    $null = $errTask.Wait(3000); $null = $outTask.Wait(3000)
    $err = "$($errTask.Result)".Trim()
    $errors = @(if ($err) { ($err -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 12) })
    $code = if ($p.HasExited) { $p.ExitCode } else { $null }
    if ($hwnd -eq [IntPtr]::Zero -and -not $errors.Count) {
        $errors = @($(if ($p.HasExited) { "the script ended (exit code $code) without opening a window" } else { "no window opened within $WaitSec seconds" }))
        $out = "$($outTask.Result)".Trim()
        if ($out) { $errors += @($out -split "`r?`n" | Select-Object -Last 6) }
    }
    Write-CCBLog info guitest 'Window app start test' @{ script = $Script; opened = ($hwnd -ne [IntPtr]::Zero); errors = $errors.Count }
    [pscustomobject]@{ opened = ($hwnd -ne [IntPtr]::Zero); title = $title; shot = $shot; errors = $errors; exitCode = $code; skipped = '' }
}

Export-ModuleMember -Function Find-GuiScripts, Test-PsGuiApp
