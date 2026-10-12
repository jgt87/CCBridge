# A page as a PDF or PowerPoint deck (lib/PageExport.psm1). Edge itself (printing, capturing) runs in
# the app; here: the deck's parts, the export names and the script for schedules. Made-up pictures.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\PageExport.psm1') -Force
Add-Type -AssemblyName System.IO.Compression

Describe 'A page as a report' {
    It 'names the export after the page and the time' {
        Get-ExportName 'reports/sales overview.html' 'pdf' ([datetime]'2026-03-04 05:06') | Should Be 'Runbooks/Exports/sales-overview-20260304-0506.pdf'
    }
    It 'makes a deck: a title slide, then a slide per picture with its title' {
        $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
        $bytes = ConvertTo-PptxBytes 'Monthly & weekly' @(@{ title = 'Orders <per> month'; png = $png; width = 600; height = 300 }, @{ title = 'Key figures'; png = $png; width = 900; height = 100 }) 'March'
        $zip = New-Object IO.Compression.ZipArchive((New-Object IO.MemoryStream(, $bytes)), [IO.Compression.ZipArchiveMode]::Read)
        try {
            $names = @($zip.Entries | ForEach-Object { $_.FullName })
            $names[0] | Should Be '[Content_Types].xml'
            foreach ($n in 'ppt/presentation.xml', 'ppt/slides/slide1.xml', 'ppt/slides/slide3.xml', 'ppt/media/image2.png', 'ppt/theme/theme1.xml', 'ppt/slideMasters/slideMaster1.xml') { $names -contains $n | Should Be $true }
            $read = { param($n) $r = New-Object IO.StreamReader($zip.GetEntry($n).Open()); try { $r.ReadToEnd() } finally { $r.Dispose() } }
            (& $read 'ppt/slides/slide1.xml') | Should Match 'Monthly &amp; weekly'
            (& $read 'ppt/slides/slide2.xml') | Should Match 'Orders &lt;per&gt; month'
            (& $read 'ppt/slides/_rels/slide2.xml.rels') | Should Match 'media/image1\.png'
            (& $read 'ppt/presentation.xml') | Should Match '<p:sldId id="258" r:id="rId4"/>'
        } finally { $zip.Dispose() }
    }
    It 'writes a script that saves the PDF with Edge alone' {
        $p = Join-Path $env:TEMP ('ccb-export-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            Write-ExportScript $p | Should Be 'Scripts/Export-Page.ps1'
            $f = Join-Path $p 'Scripts\Export-Page.ps1'
            $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e)
            @($e).Count | Should Be 0
            [IO.File]::ReadAllText($f) | Should Match '--print-to-pdf='
        } finally { Remove-Item $p -Recurse -Force }
    }
}
