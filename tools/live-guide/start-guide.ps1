$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot '../..')
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js 22 or newer, then reopen PowerShell.' }
$guideCodex = Get-Command codex -ErrorAction SilentlyContinue
if (-not $guideCodex) { throw 'Install Codex CLI, then run codex login before starting the guide.' }
$env:SCAN_CODEX = $guideCodex.Source
node tools/live-guide/server.mjs --guide
