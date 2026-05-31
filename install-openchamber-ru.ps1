param(
  [string]$OpenChamberPath
)

$ErrorActionPreference = 'Stop'

function Save-File {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )
  Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Require-Path {
  param([string]$Path,[string]$Label)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing ${Label}: $Path"
  }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-OpenChamberRepo {
  param([string]$CandidatePath)
  if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return $false }
  if (-not (Test-Path -LiteralPath $CandidatePath -PathType Container)) { return $false }
  $pkg = Join-Path $CandidatePath 'package.json'
  $runtime = Join-Path $CandidatePath 'packages/ui/src/lib/i18n/runtime.ts'
  $store = Join-Path $CandidatePath 'packages/ui/src/lib/i18n/store.ts'
  return (Test-Path -LiteralPath $pkg) -and (Test-Path -LiteralPath $runtime) -and (Test-Path -LiteralPath $store)
}

function Find-OpenChamberRepo {
  $candidates = New-Object System.Collections.Generic.List[string]

  # Script directory and parents
  $cursor = $scriptDir
  for ($i = 0; $i -lt 6 -and -not [string]::IsNullOrWhiteSpace($cursor); $i++) {
    if (-not $candidates.Contains($cursor)) { [void]$candidates.Add($cursor) }
    $parent = Split-Path -Parent $cursor
    if ($parent -eq $cursor) { break }
    $cursor = $parent
  }

  # Common roots
  $docs = [Environment]::GetFolderPath('MyDocuments')
  if ($docs) { [void]$candidates.Add($docs) }
  if (Test-Path 'D:\.codex') { [void]$candidates.Add('D:\.codex') }
  if (Test-Path 'C:\Users') { [void]$candidates.Add('C:\Users') }

  foreach ($root in $candidates) {
    if (Test-OpenChamberRepo -CandidatePath $root) { return (Resolve-Path -LiteralPath $root).Path }
    try {
      $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop
      foreach ($dir in $dirs) {
        if (Test-OpenChamberRepo -CandidatePath $dir.FullName) {
          return (Resolve-Path -LiteralPath $dir.FullName).Path
        }
      }
    } catch {
      # ignore inaccessible folders
    }
  }

  # Shallow recursive search in common roots
  $deepRoots = @($docs, 'D:\.codex')
  foreach ($deepRoot in $deepRoots) {
    if (-not (Test-Path -LiteralPath $deepRoot -PathType Container)) { continue }
    try {
      $dirs = Get-ChildItem -LiteralPath $deepRoot -Directory -Recurse -Depth 3 -ErrorAction Stop
      foreach ($dir in $dirs) {
        if (Test-OpenChamberRepo -CandidatePath $dir.FullName) {
          return (Resolve-Path -LiteralPath $dir.FullName).Path
        }
      }
    } catch {
      # ignore inaccessible folders
    }
  }

  return $null
}

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) {
  $autoFound = Find-OpenChamberRepo
  if ($autoFound) {
    Write-Host "Auto-detected repository: $autoFound"
    $OpenChamberPath = $autoFound
  } else {
    $OpenChamberPath = Read-Host 'Path to openchamber repository (folder with package.json and packages/)'
  }
}

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) {
  throw 'Repository path is required.'
}

$repo = (Resolve-Path -LiteralPath $OpenChamberPath).Path
$runtimePath = Join-Path $repo 'packages/ui/src/lib/i18n/runtime.ts'
$storePath = Join-Path $repo 'packages/ui/src/lib/i18n/store.ts'
$messagesDir = Join-Path $repo 'packages/ui/src/lib/i18n/messages'

Require-Path $runtimePath 'runtime.ts'
Require-Path $storePath 'store.ts'
Require-Path $messagesDir 'messages directory'

$ruSrc = Join-Path $scriptDir 'i18n/messages/ru.ts'
$ruSettingsSrc = Join-Path $scriptDir 'i18n/messages/ru.settings.ts'
Require-Path $ruSrc 'ru.ts'
Require-Path $ruSettingsSrc 'ru.settings.ts'

Copy-Item -LiteralPath $ruSrc -Destination (Join-Path $messagesDir 'ru.ts') -Force
Copy-Item -LiteralPath $ruSettingsSrc -Destination (Join-Path $messagesDir 'ru.settings.ts') -Force

# Patch runtime.ts
$runtime = Get-Content -Raw -LiteralPath $runtimePath

if ($runtime -notmatch "export\s+type\s+Locale\s*=\s*[^;]*'ru'") {
  $runtime = [regex]::Replace($runtime, "(export\s+type\s+Locale\s*=\s*[^;]*?)\s*;", "$1 | 'ru';", 1)
}

if ($runtime -notmatch "export\s+const\s+LOCALES\s*=\s*\[[^\]]*'ru'") {
  $runtime = [regex]::Replace($runtime, "(export\s+const\s+LOCALES\s*=\s*\[[^\]]*?)\]", "$1, 'ru']", 1)
}

if ($runtime -notmatch "common\.language\.russian") {
  $runtime = $runtime -replace "common.language.polish'", "common.language.polish' | 'common.language.russian'"
}

if ($runtime -notmatch "ru\s*:\s*'common\.language\.russian'") {
  $runtime = [regex]::Replace($runtime, "(pl\s*:\s*'common\.language\.polish',)", "$1`r`n  ru: 'common.language.russian',", 1)
}

if ($runtime -notmatch "normalized === 'ru'") {
  $runtime = [regex]::Replace(
    $runtime,
    "(if \(normalized === 'pl' \|\| normalized\.startsWith\('pl-'\)\) \{\r?\n\s*return 'pl';\r?\n\s*\})",
    "$1`r`n  if (normalized === 'ru' || normalized.startsWith('ru-')) {`r`n    return 'ru';`r`n  }",
    1
  )
}

Save-File -Path $runtimePath -Content $runtime

# Patch store.ts
$store = Get-Content -Raw -LiteralPath $storePath
if ($store -notmatch "\.\/messages\/ru") {
  $old = "              : locale === 'pl'`r`n                ? await import('./messages/pl') as { dict: I18nDictionary }`r`n                : { dict: enDict };"
  $new = "              : locale === 'pl'`r`n                ? await import('./messages/pl') as { dict: I18nDictionary }`r`n                : locale === 'ru'`r`n                  ? await import('./messages/ru') as { dict: I18nDictionary }`r`n                : { dict: enDict };"
  $store = $store.Replace($old, $new)
}
Save-File -Path $storePath -Content $store

# Ensure language label exists in all locales
$singleQuoteFiles = @('en.ts','ko.ts','pl.ts','zh-CN.ts','zh-TW.ts')
$doubleQuoteFiles = @('es.ts','pt-BR.ts','uk.ts')

foreach ($fileName in $singleQuoteFiles) {
  $path = Join-Path $messagesDir $fileName
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $content = Get-Content -Raw -LiteralPath $path
  if ($content -notmatch 'common\.language\.russian') {
    $content = [regex]::Replace(
      $content,
      "('common\.language\.polish'\s*:\s*'[^']+',)",
      "$1`r`n  'common.language.russian': 'Russian',",
      1
    )
    Save-File -Path $path -Content $content
  }
}

foreach ($fileName in $doubleQuoteFiles) {
  $path = Join-Path $messagesDir $fileName
  if (-not (Test-Path -LiteralPath $path)) { continue }
  $content = Get-Content -Raw -LiteralPath $path
  if ($content -notmatch 'common\.language\.russian') {
    $content = [regex]::Replace(
      $content,
      '("common\.language\.polish"\s*:\s*"[^"]+",)',
      "$1`r`n  ""common.language.russian"": ""Russian"",",
      1
    )
    Save-File -Path $path -Content $content
  }
}

Write-Host ''
Write-Host 'Russian translation installed successfully.' -ForegroundColor Green
Write-Host "Repository: $repo"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '1) bun install'
Write-Host '2) bun run dev:web:hmr'
Write-Host '3) Open Settings -> Language -> Russian'
