# npm packages (lib/Packages.psm1, Agent Publish-PackagesNeeded / Invoke-PackagesJob): which
# package.json lists packages node_modules does not have, the card for it, and npm install started
# by a person. npm itself is mocked: no downloads here.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Packages.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function New-NodeProject {
    $p = Join-Path $env:TEMP ('ccb-npm-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'web'), (Join-Path $p 'node_modules\react') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'package.json'), '{ "dependencies": { "react": "^19.0.0", "@vitejs/plugin-react": "^5.0.0" }, "devDependencies": { "vite": "^7.0.0" } }')
    [IO.File]::WriteAllText((Join-Path $p 'node_modules\react\package.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $p 'web\package.json'), '{ "dependencies": { "react": "^19.0.0" } }')
    $p
}

Describe 'Which packages are missing' {
    It 'checks every package.json up to two levels down, scoped names and packages installed further up' {
        $p = New-NodeProject
        New-Item -ItemType Directory (Join-Path $p 'node_modules\deep\x') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'node_modules\deep\package.json'), '{ "dependencies": { "nope": "1" } }')
        $s = @(Get-PackageState $p)
        ($s | ForEach-Object { $_.folder }) -join ',' | Should Be ',web'
        $rootState = $s | Where-Object { $_.folder -eq '' }
        $rootState.total | Should Be 3
        (@($rootState.missing) | Sort-Object) -join ',' | Should Be '@vitejs/plugin-react,vite'
        @(($s | Where-Object { $_.folder -eq 'web' }).missing).Count | Should Be 0   # react from the root's node_modules
        Format-PackageNeed $rootState | Should Be '2 of 3 package(s) are not installed yet (@vitejs/plugin-react, vite)'
        Get-NpmInstallCommand '' | Should Be 'npm install --no-fund --no-audit'
        Get-NpmInstallCommand 'web' | Should Be 'npm install --no-fund --no-audit --prefix "web"'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'says so for a package.json that is not valid JSON' {
        $p = New-NodeProject
        [IO.File]::WriteAllText((Join-Path $p 'web\package.json'), '{ broken')
        (@(Get-PackageState $p) | Where-Object { $_.folder -eq 'web' }).error | Should Match 'not valid JSON'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'The packages card and npm install' {
    It 'shows the card once per set of missing packages' {
        $p = New-NodeProject
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        Mock -ModuleName Agent Get-RealCommand { 'C:\node\npm.cmd' }
        Publish-PackagesNeeded $s
        Publish-PackagesNeeded $s
        $cards = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'packages-needed' })
        $cards.Count | Should Be 1
        $cards[0].folder | Should Be ''
        $cards[0].npm | Should Be $true
        $cards[0].text | Should Match '2 of 3 package'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'runs npm install in the folder, with a run card, and reports what is still missing' {
        $p = New-NodeProject
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        Mock -ModuleName Agent Get-RealCommand { 'C:\node\npm.cmd' }
        Mock -ModuleName Agent Invoke-RunAction {
            # npm puts the packages in place and writes a lock file.
            foreach ($n in 'vite', '@vitejs\plugin-react') { New-Item -ItemType Directory (Join-Path $ProjectRoot "node_modules\$n") -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $ProjectRoot "node_modules\$n\package.json"), '{}') }
            [IO.File]::WriteAllText((Join-Path $ProjectRoot 'package-lock.json'), '{ "lockfileVersion": 3 }')
            @{ exitCode = 0; output = 'added 2 packages'; timedOut = $false; cancelled = $false }
        }
        Invoke-PackagesJob $s ''
        $ev = @(Get-AgentEvents $s 0)
        ($ev | Where-Object { $_.type -eq 'action' }).target | Should Be 'npm install --no-fund --no-audit'
        ($ev | Where-Object { $_.type -eq 'action-result' }).ok | Should Be $true
        ($ev | Where-Object { $_.type -eq 'status' } | Select-Object -Last 1).text | Should Match 'every package in package\.json is there now'
        @($ev | Where-Object { $_.type -eq 'checkpoint' }).Count | Should Be 1   # package-lock.json: Undo can take it back
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'explains a blocked registry and says when npm is not installed' {
        $p = New-NodeProject
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p
        Mock -ModuleName Agent Get-RealCommand { 'C:\node\npm.cmd' }
        Mock -ModuleName Agent Invoke-RunAction { @{ exitCode = 1; output = 'npm error code ETIMEDOUT'; timedOut = $false; cancelled = $false } }
        Invoke-PackagesJob $s ''
        $ev = @(Get-AgentEvents $s 0)
        ($ev | Where-Object { $_.type -eq 'action-result' }).output | Should Match 'proxy or a blocked registry'
        ($ev | Where-Object { $_.type -eq 'error' }).text | Should Match 'still missing'
        Mock -ModuleName Agent Get-RealCommand { $null }
        $s2 = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s2.ProjectRoot = $p
        Invoke-PackagesJob $s2 ''
        (@(Get-AgentEvents $s2 0) | Where-Object { $_.type -eq 'error' }).hint | Should Match 'Node\.js > Install for me'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
