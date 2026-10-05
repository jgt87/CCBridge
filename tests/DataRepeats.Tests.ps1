# Repeated data (JSON records in a data copy, object and array literals) is no sign of code added
# twice (Lint Test-Duplicates, $script:DataLine); repeated code still is. The data is made up.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force

Describe 'Repeated lines in data and in code' {
    $record = '  {', '    "title": "Standup",', '    "start": "09:00",', '    "end": "09:15",', '    "room": "Room 1",', '    "tags": ["team", "daily"],', '    "optional": false,', '    "organizer": null,', '    "count": 3', '  },'
    It 'does not report JSON records repeated in a data copy' {
        $js = "window.exampleData = [`n" + (($record + $record + $record) -join "`n") + "`n];"
        Test-Duplicates $js 'data/example.js' | Should BeNullOrEmpty
    }
    It 'still reports the same code lines added twice' {
        $code = 'function load(list) {', '  const out = [];', '  for (const x of list) {', '    if (!x.title) continue;', '    out.push(x.title.trim());', '    console.info(x.title);', '    total += x.count;', '    seen.add(x.id);', '    render(x);', '  }', '  return out;', '}'
        $twice = (($code -join "`n") + "`n" + ((($code | Select-Object -Skip 1) -join "`n") -replace 'function load', ''))
        Test-Duplicates $twice 'src/app.js' | Should Match 'repeat lines'
    }
}
