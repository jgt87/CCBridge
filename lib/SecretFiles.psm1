# Files that hold secrets (.env, .npmrc, private keys, user secrets...): Copilot sees which keys
# are set, never their values. Reads and searches show the values as <hidden>; such files are not
# written or edited by Copilot (it would have to send the values back, and a masked copy would
# overwrite them), and they are not attached to a message. Example files (.env.example, .sample,
# .template, .dist) are meant to be shared and stay as they are.

$ErrorActionPreference = 'Stop'

$script:Hidden = '<hidden>'

function Get-SecretFileKind([string]$Path) {
    <# 'keyvalue' (KEY=VALUE or key: value lines), 'json' (string values), 'key' (a private key or
       certificate store: nothing of it is shown) or $null (not a secret file). #>
    $name = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($name -match '\.(example|sample|template|dist|defaults?)$' -or $name -match '\.(example|sample|template)\.') { return $null }
    if ($name -match '^\.env(\..+)?$' -or $name -match '\.env$') { return 'keyvalue' }
    if ($name -in '.npmrc', '.pypirc', '.netrc', '_netrc', '.git-credentials', '.htpasswd', 'credentials', '.dockercfg') { return 'keyvalue' }
    if ($name -in 'secrets.json', 'usersecrets.json', 'credentials.json', 'client_secret.json', 'service-account.json') { return 'json' }
    if ($name -match '^client_secret.*\.json$') { return 'json' }
    if ($name -match '\.(pem|key|pfx|p12|jks|keystore|ppk|kdbx)$' -or $name -in 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519') { return 'key' }
    $null
}

function Hide-SecretValues {
    <# The text of a secret file with every value replaced by <hidden>: keys, sections, comments and
       empty values stay. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $kind = Get-SecretFileKind $Path
    if (-not $kind) { return $Text }
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    if ($kind -eq 'key') { return "($($lines.Length) lines of key or certificate material, not shown)" }
    if ($kind -eq 'json') {
        # Every string that follows a key ("name": "value") is hidden; numbers and booleans too.
        return [regex]::Replace($Text, '("(?:[^"\\]|\\.)*"\s*:\s*)("(?:[^"\\]|\\.)*"|-?\d[\d.eE+-]*|true|false)', { param($m) $m.Groups[1].Value + '"' + $script:Hidden + '"' })
    }
    $out = foreach ($l in $lines) {
        if ($l -match '^\s*(#|;|\[|$)') { $l; continue }   # comments, sections (not //: .npmrc keys start with //)
        # KEY=VALUE, export KEY=VALUE, //registry/:_authToken=VALUE; else key: value
        $m = [regex]::Match($l, '^(\s*(?:export\s+)?[^=\s][^=]*=\s*)(\S.*)$')
        if (-not $m.Success) { $m = [regex]::Match($l, '^(\s*[\w.-]+\s*:\s*)(\S.*)$') }
        if ($m.Success) { $m.Groups[1].Value + $script:Hidden; continue }
        # .netrc style: machine HOST login NAME password VALUE
        if ($l -match '(?i)\b(password|login|account)\s+\S') { [regex]::Replace($l, '(?i)\b(password|login|account)\s+\S+', { param($x) $x.Groups[1].Value + ' ' + $script:Hidden }); continue }
        # https://user:token@host (.git-credentials)
        if ($l -match '://[^/\s:@]+:[^@\s]+@') { [regex]::Replace($l, '(://[^/\s:@]+:)[^@\s]+@', ('$1' + $script:Hidden + '@')); continue }
        $l
    }
    @($out) -join "`n"
}

function Get-SecretValues {
    <# The values in a secret file's text (5 characters or more, quotes taken off), so they can be
       taken out of command output: a command such as "type .env" must not show them either. #>
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Text)
    $kind = Get-SecretFileKind $Path
    if (-not $kind) { return @() }
    $vals = New-Object System.Collections.Generic.List[string]
    if ($kind -eq 'key') {
        foreach ($l in $Text.Replace("`r`n", "`n").Split("`n")) { $t = $l.Trim(); if ($t.Length -ge 8 -and $t -notmatch '^-----') { $vals.Add($t) } }
    } elseif ($kind -eq 'json') {
        foreach ($m in [regex]::Matches($Text, '"(?:[^"\\]|\\.)*"\s*:\s*"((?:[^"\\]|\\.)*)"')) { $vals.Add($m.Groups[1].Value) }
    } else {
        foreach ($l in $Text.Replace("`r`n", "`n").Split("`n")) {
            if ($l -match '^\s*(#|;|\[|$)') { continue }
            $m = [regex]::Match($l, '^\s*(?:export\s+)?[^=\s][^=]*=\s*(\S.*)$')
            if (-not $m.Success) { $m = [regex]::Match($l, '^\s*[\w.-]+\s*:\s*(\S.*)$') }
            if ($m.Success) { $vals.Add($m.Groups[1].Value.Trim().Trim('"', "'")) }
            foreach ($x in [regex]::Matches($l, '(?i)\b(?:password|login|account)\s+(\S+)')) { $vals.Add($x.Groups[1].Value) }
            foreach ($x in [regex]::Matches($l, '://[^/\s:@]+:([^@\s]+)@')) { $vals.Add($x.Groups[1].Value) }
        }
    }
    @($vals | Where-Object { $_.Length -ge 5 } | Sort-Object Length -Descending -Unique)
}

function Hide-KnownSecrets {
    <# Text with every one of these values replaced by <hidden> (longest first). #>
    param([AllowEmptyString()][string]$Text, [string[]]$Values)
    if (-not $Text) { return $Text }
    foreach ($v in @($Values | Where-Object { $_ })) { if ($Text.Contains($v)) { $Text = $Text.Replace($v, $script:Hidden) } }
    $Text
}

function Get-SecretWriteRefusal([string]$Path) {
    if (-not (Get-SecretFileKind $Path)) { return $null }
    $name = [IO.Path]::GetFileName($Path)
    "$name holds secrets, which the helper program never shows to you or lets you change (you only see which keys are set). Tell the user exactly what to add or change in $name (the key and what its value is for, never a real value), and use a placeholder in code or in an example file such as $name.example."
}

Export-ModuleMember -Function Get-SecretValues, Hide-KnownSecrets, Get-SecretFileKind, Hide-SecretValues, Get-SecretWriteRefusal
