# Coding guardrails: generated paths, new dependencies, risky code, debug leftovers and swallowed
# errors, and .env files outside .gitignore. Each rule looks only at what a change adds.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Guardrails.psm1') -Force

function New-GuardProject {
    $dir = Join-Path $env:TEMP ('ccb-guard-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $dir | Out-Null
    $dir
}

Describe 'Test-GeneratedPath' {
    It 'refuses package folders, .git, dist and lock files' {
        Test-GeneratedPath 'node_modules/react/index.js' | Should Match 'generate'
        Test-GeneratedPath 'web/dist/app.js' | Should Match 'dist/'
        Test-GeneratedPath '.git/config' | Should Match 'generate'
        Test-GeneratedPath 'package-lock.json' | Should Match 'lock file'
        Test-GeneratedPath 'api/poetry.lock' | Should Match 'lock file'
    }
    It 'allows normal source files and names that only look alike' {
        Test-GeneratedPath 'src/app.js' | Should BeNullOrEmpty
        Test-GeneratedPath 'docs/distribution.md' | Should BeNullOrEmpty
        Test-GeneratedPath 'Scripts/build.ps1' | Should BeNullOrEmpty
        Test-GeneratedPath 'package.json' | Should BeNullOrEmpty
    }
    It 'counts build/ and out/ only in a project with a build tool' {
        $p = New-GuardProject
        Test-GeneratedPath 'build/notes.md' $p | Should BeNullOrEmpty
        [IO.File]::WriteAllText((Join-Path $p 'package.json'), '{}')
        Test-GeneratedPath 'build/main.js' $p | Should Match 'build output'
        Remove-Item $p -Recurse -Force
    }
}

Describe 'Find-NewDependencies' {
    It 'reports packages a change adds, not ones that only change version' {
        $old = '{ "dependencies": { "react": "^19.0.0" } }'
        $new = '{ "dependencies": { "react": "^19.2.0", "left-pad": "1.3.0" }, "devDependencies": { "vitest": "^5.0.0" } }'
        @(Find-NewDependencies 'package.json' $old $new) -join ';' | Should Be 'npm left-pad@1.3.0;npm vitest@^5.0.0'
    }
    It 'reads requirements, pyproject and .csproj' {
        @(Find-NewDependencies 'requirements.txt' "requests==2.31`n" "requests==2.32`nflask>=3 # web`n") -join ';' | Should Be 'pip flask>=3'
        @(Find-NewDependencies 'pyproject.toml' "[project]`ndependencies = [`"httpx`"]" "[project]`ndependencies = [`"httpx`", `"rich>=13`"]") -join ';' | Should Be 'pip rich>=13'
        @(Find-NewDependencies 'app/App.csproj' '' '<ItemGroup><PackageReference Include="Serilog" Version="4.0.0" /></ItemGroup>') -join ';' | Should Be 'nuget Serilog@4.0.0'
    }
    It 'reports scripts and stylesheets from other sites in pages' {
        $new = '<link rel="stylesheet" href="https://cdn.example.com/x.css"><script src="https://cdn.example.com/lib.js"></script><script src="js/app.js"></script>'
        @(Find-NewDependencies 'index.html' '' $new) -join ';' | Should Be 'script https://cdn.example.com/lib.js;stylesheet https://cdn.example.com/x.css'
    }
    It 'gives nothing for an unchanged or unreadable file' {
        @(Find-NewDependencies 'package.json' '{ "dependencies": { "a": "1" } }' '{ "dependencies": { "a": "1" } }').Count | Should Be 0
        @(Find-NewDependencies 'package.json' '' '{ broken').Count | Should Be 0
    }
}

Describe 'Find-RiskyCode' {
    It 'reports risky constructs a change adds, with their line' {
        $new = "const a = 1;`nel.innerHTML = userText;`nconst f = eval(code);"
        $r = @(Find-RiskyCode 'src/app.js' 'const a = 1;' $new)
        $r.Count | Should Be 2
        ($r -join "`n") | Should Match 'line 2: innerHTML'
        ($r -join "`n") | Should Match 'line 3: eval'
    }
    It 'allows innerHTML with a fixed text, comments and constructs that were already there' {
        @(Find-RiskyCode 'a.js' '' "el.innerHTML = '';`n// eval(x) is not used").Count | Should Be 0
        @(Find-RiskyCode 'a.js' 'x = eval(y);' "x = eval(y);`nz = 1;").Count | Should Be 0
    }
    It 'knows Python, PowerShell and SQL built from strings' {
        @(Find-RiskyCode 'run.py' '' "subprocess.run(cmd, shell=True)`nos.system(cmd)`ndata = pickle.loads(b)").Count | Should Be 3
        @(Find-RiskyCode 'run.py' '' 'cur.execute(f"SELECT * FROM t WHERE id={uid}")').Count | Should Be 1
        @(Find-RiskyCode 'run.py' '' 'cur.execute("SELECT * FROM t WHERE id=%s", (uid,))').Count | Should Be 0
        @(Find-RiskyCode 'go.ps1' '' 'Invoke-Expression $cmd').Count | Should Be 1
        @(Find-RiskyCode 'cfg.py' '' 'yaml.load(f, Loader=yaml.SafeLoader)').Count | Should Be 0
    }
}

Describe 'Find-ChangeSmells' {
    It 'reports debug leftovers a change adds' {
        $r = @(Find-ChangeSmells 'src/app.test.js' '' "it.only('works', () => {});`ndebugger;`nalert('hi');")
        $r.Count | Should Be 3
        ($r -join "`n") | Should Match 'line 1: a focused test'
        @(Find-ChangeSmells 'main.py' '' "x = 1`nbreakpoint()").Count | Should Be 1
    }
    It 'reports empty catch blocks and except: pass, not a catch with a comment' {
        @(Find-ChangeSmells 'a.js' '' "try { go(); } catch (e) {}").Count | Should Be 1
        @(Find-ChangeSmells 'a.js' '' "try { go(); } catch (e) { /* offline is fine */ }").Count | Should Be 0
        $py = "try:`n    go()`nexcept ValueError:`n    pass"
        (@(Find-ChangeSmells 'a.py' '' $py))[0] | Should Match '^line 3: an error is caught and silently ignored'
        @(Find-ChangeSmells 'a.ps1' '' 'try { Go } catch { }').Count | Should Be 1
    }
    It 'does not report what was already there' {
        $old = "try { go(); } catch (e) {}`nalert('x');"
        @(Find-ChangeSmells 'a.js' $old "$old`nconst y = 2;").Count | Should Be 0
    }
}

Describe 'Find-UnignoredEnv' {
    It 'reports a new .env that .gitignore does not cover, in a git project' {
        $p = New-GuardProject
        New-Item -ItemType Directory (Join-Path $p '.git') | Out-Null
        [IO.File]::WriteAllText((Join-Path $p '.env'), 'KEY=1')
        [IO.File]::WriteAllText((Join-Path $p '.env.example'), 'KEY=')
        @(Find-UnignoredEnv $p @('.env', '.env.example'))[0] | Should Match '^\.env: .*add the line \.env'
        [IO.File]::WriteAllText((Join-Path $p '.gitignore'), "node_modules/`n.env*`n")
        @(Find-UnignoredEnv $p @('.env')).Count | Should Be 0
        Remove-Item $p -Recurse -Force
    }
    It 'stays quiet in a project without git (and the executor applies the rules)' {
        Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
        $q = New-GuardProject
        { Assert-Writable $q 'node_modules/x/index.js' } | Should Throw
        { Assert-Writable $q 'package-lock.json' } | Should Throw
        { Assert-Writable $q 'src/index.js' } | Should Not Throw
        # A PowerShell file gets a BOM once it holds non-ASCII text; other files do not.
        $f = Join-Path $q 'run.ps1'
        Write-TextFile $f "Write-Host 'plain'" $false $false 'utf8'
        ([IO.File]::ReadAllBytes($f))[0] | Should Be 0x57
        Write-TextFile $f "Write-Host 'caf$([char]0xE9)'" $false $false 'utf8'
        $b = [IO.File]::ReadAllBytes($f)
        "$($b[0]),$($b[1]),$($b[2])" | Should Be '239,187,191'
        Write-TextFile (Join-Path $q 'notes.txt') "caf$([char]0xE9)" $false $false 'utf8'
        ([IO.File]::ReadAllBytes((Join-Path $q 'notes.txt')))[0] | Should Be 0x63
        Remove-Item $q -Recurse -Force
        $p = New-GuardProject
        [IO.File]::WriteAllText((Join-Path $p '.env'), 'KEY=1')
        @(Find-UnignoredEnv $p @('.env')).Count | Should Be 0
        Remove-Item $p -Recurse -Force
    }
}
