# Move-TempFile (Workspace): a written temporary file put in place of the real one, with a few tries
# while another program (OneDrive, the search indexer, a virus scanner) holds the file for a moment.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force
$base = Join-Path $env:TEMP ('ccb-atomic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $base

Describe 'Putting a temporary file in place' {
    It 'moves the file in when there is none yet' {
        $p = Join-Path $base 'new.json'; $tmp = "$p.tmp"
        [IO.File]::WriteAllText($tmp, 'one')
        Move-TempFile $tmp $p
        [IO.File]::ReadAllText($p) | Should Be 'one'
        Test-Path -LiteralPath $tmp | Should Be $false
    }

    It 'replaces a file that is there' {
        $p = Join-Path $base 'old.json'; $tmp = "$p.tmp"
        [IO.File]::WriteAllText($p, 'old'); [IO.File]::WriteAllText($tmp, 'new')
        Move-TempFile $tmp $p
        [IO.File]::ReadAllText($p) | Should Be 'new'
        Test-Path -LiteralPath $tmp | Should Be $false
    }

    It 'waits for a file another program holds for a moment' {
        $p = Join-Path $base 'held.json'; $tmp = "$p.tmp"
        [IO.File]::WriteAllText($p, 'old'); [IO.File]::WriteAllText($tmp, 'new')
        # Held open without delete sharing in another runspace. Signals, not timing: the holder says
        # when it holds the file and lets go 300 ms after the test says it is about to write, so the
        # write always meets the hold (a 300 ms hold watched by polling was missed under the
        # release gate's parallel load).
        $heldNow = New-Object Threading.ManualResetEventSlim($false)
        $writing = New-Object Threading.ManualResetEventSlim($false)
        $ps = [powershell]::Create()
        $null = $ps.AddScript({
            param($Path, $Held, $Go)
            $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
            $Held.Set()
            $null = $Go.Wait(10000)
            Start-Sleep -Milliseconds 300
            $fs.Dispose()
        }).AddArgument($p).AddArgument($heldNow).AddArgument($writing)
        $async = $ps.BeginInvoke()
        $heldNow.Wait(10000) | Should Be $true
        $held = $false
        try { $f = [IO.File]::Open($p, 'Open', 'Read', 'None'); $f.Dispose() } catch { $held = $true }
        $held | Should Be $true
        $writing.Set()
        Move-TempFile $tmp $p
        $null = $ps.EndInvoke($async); $ps.Dispose(); $heldNow.Dispose(); $writing.Dispose()
        [IO.File]::ReadAllText($p) | Should Be 'new'
    }

    It 'gives up on a file held all the time, removes the temporary file and says so' {
        $p = Join-Path $base 'locked.json'; $tmp = "$p.tmp"
        [IO.File]::WriteAllText($p, 'old'); [IO.File]::WriteAllText($tmp, 'new')
        $fs = [IO.File]::Open($p, 'Open', 'Read', 'Read')
        try {
            $threw = $false
            try { Move-TempFile $tmp $p } catch { $threw = $true }
            $threw | Should Be $true
        } finally { $fs.Dispose() }
        [IO.File]::ReadAllText($p) | Should Be 'old'
        Test-Path -LiteralPath $tmp | Should Be $false
    }
}

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
