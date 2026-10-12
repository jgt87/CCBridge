# Server-side code in a project that runs no server: reported as an error with where the data can come
# from instead, and not taken for a new file that a page should load. Made-up code.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-srv-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force
Import-Module (Join-Path $root 'lib\Imports.psm1') -Force

$fn = "const SOURCE = 'https://items.example.com/api/items';`nexport default async function handler(request, response) {`n  const r = await fetch(SOURCE);`n  response.status(200).json(await r.json());`n}`n"

Describe 'Server-side code' {
    It 'knows the usual kinds' {
        Get-ServerCodeKind $fn | Should Match 'serverless API function'
        Get-ServerCodeKind "module.exports = async (req, res) => { res.end('x') }" | Should Match 'module\.exports'
        Get-ServerCodeKind "exports.handler = async (event) => ({ statusCode: 200 })" | Should Match 'exports\.handler'
        Get-ServerCodeKind "export async function GET(request) { return Response.json([]) }" | Should Match 'API route'
        Get-ServerCodeKind "const express = require('express'); const app = express();" | Should Match 'Express'
        Get-ServerCodeKind "require('http').createServer((q, s) => s.end()).listen(3000)" | Should Match 'http server'
        Get-ServerCodeKind "export default function draw(chart) { chart.render(); }`ndocument.addEventListener('click', handler);" | Should Be ''
        Get-ServerCodeKind "fetch('data/items.json').then((r) => r.json())" | Should Be ''
    }
    It 'reports it as an error in a project without a server of its own' {
        $p = Join-Path $env:TEMP ('ccb-srv-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            $f = @(Find-ServerCode $p 'api/items.js' $fn)
            $f[0] | Should Match '^line 2: this is server-side code \(a serverless API function'
            $f[0] | Should Match 'Then remove this file'
            @(Find-ServerCode $p 'tests/api.test.js' $fn).Count | Should Be 0
            # A real Node project with a server package: its server code is its own.
            [IO.File]::WriteAllText((Join-Path $p 'package.json'), '{ "dependencies": { "express": "^4.19.0" } }')
            @(Find-ServerCode $p 'server.js' "const express = require('express');").Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'is not asked to be loaded by a page' {
        $p = Join-Path $env:TEMP ('ccb-srv2-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'api') -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $p 'index.html'), '<!doctype html><title>x</title><script src="js/app.js"></script>')
            [IO.File]::WriteAllText((Join-Path $p 'api\items.js'), $fn)
            [IO.File]::WriteAllText((Join-Path $p 'lonely.js'), 'console.log(1);')
            @(Find-UnloadedFiles $p @('api/items.js', 'lonely.js')) -join ',' | Should Be 'lonely.js'
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
