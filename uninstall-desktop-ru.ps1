param(
  [string]$OpenChamberPath
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[i] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }

function Find-OpenChamberInstall {
  $candidates = New-Object System.Collections.Generic.List[string]
  $local = Join-Path $env:LOCALAPPDATA 'Programs\@openchamberelectron'
  if (Test-Path -LiteralPath $local) { [void]$candidates.Add($local) }
  try {
    $keys = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
      Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like '*OpenChamber*'
      } | ForEach-Object {
        if ($_.InstallLocation -and (Test-Path -LiteralPath $_.InstallLocation)) {
          [void]$candidates.Add($_.InstallLocation)
        }
        if ($_.DisplayIcon) {
          $ic = Split-Path -Parent $_.DisplayIcon
          if ($ic -and (Test-Path -LiteralPath $ic)) { [void]$candidates.Add($ic) }
        }
        if ($_.UninstallString) {
          $u = $_.UninstallString
          if ($u.StartsWith('"')) { $u = $u.Substring(1) }
          $u = $u -replace '"[^"]*$', ''
          $un = Split-Path -Parent $u
          if ($un -and (Test-Path -LiteralPath $un)) { [void]$candidates.Add($un) }
        }
      }
    }
  } catch { }
  foreach ($c in $candidates) {
    $assets = Join-Path $c 'resources\web-dist\assets'
    if ((Test-Path -LiteralPath (Join-Path $c 'OpenChamber.exe')) -and (Test-Path -LiteralPath $assets)) {
      return (Resolve-Path -LiteralPath $c).Path
    }
  }
  return $null
}

function Restore-FromBackup {
  param([string]$Path)
  $bak = "$Path.bak"
  if (-not (Test-Path -LiteralPath $bak)) { return $false }
  Copy-Item -LiteralPath $bak -Destination $Path -Force
  Remove-Item -LiteralPath $bak -Force
  return $true
}

Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ' OpenChamber Desktop - Uninstall RU patch   ' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ''

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) {
  $found = Find-OpenChamberInstall
  if ($found) {
    Write-Step "Auto-detected install: $found"
    $OpenChamberPath = $found
  } else {
    $OpenChamberPath = Read-Host 'Path to OpenChamber install (folder with OpenChamber.exe)'
  }
}

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) { throw 'Install path is required.' }
$install = (Resolve-Path -LiteralPath $OpenChamberPath).Path
$assets = Join-Path $install 'resources\web-dist\assets'
if (-not (Test-Path -LiteralPath $assets)) { throw "Assets folder not found: $assets" }

Write-Step 'Removing ru-*.js chunks...'
$ruFiles = Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue
foreach ($f in $ruFiles) {
  Remove-Item -LiteralPath $f.FullName -Force
  Write-Ok "  Removed $($f.Name)"
}
if (-not $ruFiles) { Write-Warn '  No ru-*.js chunks found.' }

Write-Step 'Restoring i18n loader from backup...'
$i18nFile = Get-ChildItem -LiteralPath $assets -Filter 'useAppFontEffects-*.js' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($i18nFile) {
  if (Restore-FromBackup -Path $i18nFile.FullName) {
    Write-Ok "  Restored $(Split-Path -Leaf $i18nFile.FullName)"
  } else {
    Write-Warn '  No backup for i18n loader. Manual reinstall of OpenChamber may be needed.'
  }
} else {
  Write-Warn '  useAppFontEffects-*.js not found.'
}

Write-Step 'Restoring locale chunks from backups...'
$localeFiles = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match '^(en|fr|zh-CN|zh-TW|uk|es|pt-BR|ko|pl|ja)-'
}
$restored = 0
foreach ($f in $localeFiles) {
  if (Restore-FromBackup -Path $f.FullName) {
    Write-Ok "  Restored $($f.Name)"
    $restored++
  }
}
if ($restored -eq 0) { Write-Warn '  No locale backups found.' }

Write-Host ''
Write-Ok 'Russian translation uninstalled.'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host '  1. Fully quit OpenChamber (system tray -> Quit).'
Write-Host '  2. Start OpenChamber again.'
Write-Host ''
