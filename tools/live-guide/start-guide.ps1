param([string]$SaveTo, [switch]$ChooseSaveFolder, [switch]$NoOpenFolder)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot '../..')
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js 22 or newer, then reopen PowerShell.' }
$guideCodex = Get-Command codex -ErrorAction SilentlyContinue
if (-not $guideCodex) { throw 'Install Codex CLI, then run codex login before starting the guide.' }
$env:SCAN_CODEX = $guideCodex.Source
$guideSettingsPath = Join-Path (Get-Location) 'data/live/bridge-settings.json'
$guideSavedSettings = $null
if (Test-Path -LiteralPath $guideSettingsPath) { $guideSavedSettings = Get-Content -LiteralPath $guideSettingsPath -Raw | ConvertFrom-Json }
if (-not $SaveTo) { $SaveTo = $guideSavedSettings.exportDirectory }
if ($ChooseSaveFolder -or -not $SaveTo) {
  Add-Type -AssemblyName System.Windows.Forms
  $guideFolderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $guideFolderDialog.Description = 'Choose where complete live survey exports should be saved on this PC.'
  $guideFolderDialog.ShowNewFolderButton = $true
  if ($SaveTo -and (Test-Path -LiteralPath $SaveTo)) { $guideFolderDialog.SelectedPath = $SaveTo }
  if ($guideFolderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    $guideFolderDialog.Dispose()
    Write-Host 'No save location chosen. Receiver was not started.'
    exit 0
  }
  $SaveTo = $guideFolderDialog.SelectedPath
  $guideFolderDialog.Dispose()
}
New-Item -ItemType Directory -Force -Path $SaveTo | Out-Null
$SaveTo = (Resolve-Path -LiteralPath $SaveTo).Path
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $guideSettingsPath) | Out-Null
@{exportDirectory=$SaveTo} | ConvertTo-Json | Set-Content -LiteralPath $guideSettingsPath -Encoding UTF8
$env:SCAN_EXPORT_DIR = $SaveTo
if ($NoOpenFolder) { node tools/live-guide/server.mjs --guide }
else { node tools/live-guide/server.mjs --guide --open-exports }
