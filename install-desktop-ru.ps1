param(
  [string]$OpenChamberPath,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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
    if (Test-InstallDir -Path $c) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $null
}

function Test-InstallDir {
  param([string]$Path)
  $assets = Join-Path $Path 'resources\web-dist\assets'
  return (Test-Path -LiteralPath (Join-Path $Path 'OpenChamber.exe')) -and (Test-Path -LiteralPath $assets)
}

function Find-FileByPattern {
  param([string]$Dir,[string]$Pattern)
  $f = Get-ChildItem -LiteralPath $Dir -Filter $Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function Backup-File {
  param([string]$Path)
  $bak = "$Path.bak"
  if (Test-Path -LiteralPath $bak) { return $false }
  Copy-Item -LiteralPath $Path -Destination $bak -Force
  return $true
}

function Write-Utf8NoBom {
  param([string]$Path,[string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function ConvertTo-StringEscape {
  param([string]$s)
  if ($null -eq $s) { return '' }
  $s = $s -replace '\\', '\\\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
  return $s
}

function Parse-TsDictBody {
  param([string]$FilePath,[string]$ExportName)
  if (-not (Test-Path -LiteralPath $FilePath)) { throw "Missing: $FilePath" }
  $raw = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
  $startMarker = "export const $ExportName = {"
  $start = $raw.IndexOf($startMarker)
  if ($start -lt 0) { throw "Cannot find 'export const $ExportName = {' in $FilePath" }
  $start += $startMarker.Length
  $end = $raw.LastIndexOf('} as const')
  if ($end -lt 0) { $end = $raw.LastIndexOf('};') }
  if ($end -lt $start) { throw "Cannot find end of $ExportName object in $FilePath" }
  return $raw.Substring($start, $end - $start).Trim()
}

function Parse-EntriesFromJsBody {
  param([string]$body)
  $entries = @{}
  $i = 0
  $len = $body.Length
  while ($i -lt $len) {
    while ($i -lt $len -and ([char]::IsWhiteSpace($body[$i]) -or $body[$i] -eq ',')) { $i++ }
    if ($i -ge $len) { break }
    $ch = $body[$i]
    if ($ch -eq '.') {
      while ($i -lt $len -and $body[$i] -ne ',') { $i++ }
      continue
    }
    if ($ch -ne "'" -and $ch -ne '"') { $i++; continue }
    $quote = $ch
    $i++
    $keySb = New-Object System.Text.StringBuilder
    while ($i -lt $len -and $body[$i] -ne $quote) {
      if ($body[$i] -eq '\' -and ($i + 1) -lt $len) {
        $n = $body[$i + 1]
        switch ($n) {
          "'" { [void]$keySb.Append("'"); $i += 2; continue }
          '"' { [void]$keySb.Append('"'); $i += 2; continue }
          '\' { [void]$keySb.Append('\'); $i += 2; continue }
          'n' { [void]$keySb.Append("`n"); $i += 2; continue }
          'r' { [void]$keySb.Append("`r"); $i += 2; continue }
          't' { [void]$keySb.Append("`t"); $i += 2; continue }
          default { [void]$keySb.Append($n); $i += 2; continue }
        }
      }
      [void]$keySb.Append($body[$i]); $i++
    }
    $i++
    while ($i -lt $len -and [char]::IsWhiteSpace($body[$i])) { $i++ }
    if ($i -ge $len -or $body[$i] -ne ':') { continue }
    $i++
    while ($i -lt $len -and [char]::IsWhiteSpace($body[$i])) { $i++ }
    if ($i -ge $len) { break }
    $vQuote = $body[$i]
    if ($vQuote -ne "'" -and $vQuote -ne '"') {
      while ($i -lt $len -and $body[$i] -ne ',' -and $body[$i] -ne '}') { $i++ }
      continue
    }
    $i++
    $valSb = New-Object System.Text.StringBuilder
    while ($i -lt $len -and $body[$i] -ne $vQuote) {
      if ($body[$i] -eq '\' -and ($i + 1) -lt $len) {
        $n = $body[$i + 1]
        switch ($n) {
          "'" { [void]$valSb.Append("'"); $i += 2; continue }
          '"' { [void]$valSb.Append('"'); $i += 2; continue }
          '\' { [void]$valSb.Append('\'); $i += 2; continue }
          'n' { [void]$valSb.Append("`n"); $i += 2; continue }
          'r' { [void]$valSb.Append("`r"); $i += 2; continue }
          't' { [void]$valSb.Append("`t"); $i += 2; continue }
          default { [void]$valSb.Append($n); $i += 2; continue }
        }
      }
      [void]$valSb.Append($body[$i]); $i++
    }
    $i++
    if ($keySb.Length -gt 0) {
      $entries[$keySb.ToString()] = $valSb.ToString()
    }
  }
  return $entries
}

function Build-RuJsContent {
  param([hashtable]$entries)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('const dict={')
  $first = $true
  foreach ($k in ($entries.Keys | Sort-Object)) {
    if (-not $first) { [void]$sb.Append(',') }
    $first = $false
    $v = $entries[$k]
    [void]$sb.Append('"')
    [void]$sb.Append((ConvertTo-StringEscape -s $k))
    [void]$sb.Append('":"')
    [void]$sb.Append((ConvertTo-StringEscape -s $v))
    [void]$sb.Append('"')
  }
  [void]$sb.Append('};export{dict as dict};')
  return $sb.ToString()
}

function Patch-LocaleFile {
  param([string]$Path)
  $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ($content -match 'common\.language\.russian') { return 'already' }
  $m = [regex]::Match($content, '("common\.language\.polish"\s*:\s*"[^"]+",)')
  $isDouble = $true
  if (-not $m.Success) {
    $m = [regex]::Match($content, "('common\.language\.polish'\s*:\s*'[^']+',)")
    $isDouble = $false
  }
  if (-not $m.Success) { return 'no-anchor' }
  $insert = if ($isDouble) {
    $m.Value + """common.language.russian"":""Russian"","
  } else {
    $m.Value + "'common.language.russian':'Russian',"
  }
  $new = $content.Substring(0, $m.Index) + $insert + $content.Substring($m.Index + $m.Length)
  Write-Utf8NoBom -Path $Path -Content $new
  return 'patched'
}

function Compute-ShortHash {
  param([string]$content)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
  $hash = $sha.ComputeHash($bytes)
  return (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
}

Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ' OpenChamber Desktop - Russian Translation  ' -ForegroundColor Yellow
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
if (-not (Test-InstallDir -Path $install)) {
  throw "Not a valid OpenChamber install: $install (need OpenChamber.exe and resources\web-dist\assets)"
}

$assets = Join-Path $install 'resources\web-dist\assets'
Write-Step "Assets folder: $assets"

$i18nFile = Find-FileByPattern -Dir $assets -Pattern 'useAppFontEffects-*.js'
if (-not $i18nFile) { throw "Cannot find useAppFontEffects-*.js in $assets" }
Write-Step "i18n loader:   $(Split-Path -Leaf $i18nFile)"

$ruSrc       = Join-Path $scriptDir 'i18n\messages\ru.ts'
$ruSettings  = Join-Path $scriptDir 'i18n\messages\ru.settings.ts'
if (-not (Test-Path -LiteralPath $ruSrc))      { throw "Missing: $ruSrc" }
if (-not (Test-Path -LiteralPath $ruSettings)) { throw "Missing: $ruSettings" }

Write-Step 'Parsing ru.ts and ru.settings.ts...'
$dictBody     = Parse-TsDictBody -FilePath $ruSrc      -ExportName 'dict'
$settingsBody = Parse-TsDictBody -FilePath $ruSettings -ExportName 'settingsDict'

$entries = @{}
$settingsEntries = Parse-EntriesFromJsBody -body $settingsBody
foreach ($k in $settingsEntries.Keys) { $entries[$k] = $settingsEntries[$k] }
$mainEntries = Parse-EntriesFromJsBody -body $dictBody
foreach ($k in $mainEntries.Keys) { $entries[$k] = $mainEntries[$k] }
Write-Ok ("Total translation keys: {0}" -f $entries.Count)

if ($entries.Count -lt 100) { throw "Too few entries parsed ($($entries.Count)). Source files may be corrupted." }

$ruContent = Build-RuJsContent -entries $entries
$hash = Compute-ShortHash -content $ruContent
$ruFileName = "ru-$hash.js"
$ruPath = Join-Path $assets $ruFileName
Write-Step "Generated ru chunk name: $ruFileName"

$existingRu = Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $ruFileName }
foreach ($old in $existingRu) {
  Write-Warn "Removing stale ru chunk: $($old.Name)"
  Remove-Item -LiteralPath $old.FullName -Force
}

Write-Utf8NoBom -Path $ruPath -Content $ruContent
Write-Ok "Wrote $ruPath"

Write-Step 'Backing up i18n loader...'
if (Backup-File -Path $i18nFile) {
  Write-Ok 'Backup created: useAppFontEffects-*.js.bak'
} elseif ($Force) {
  Copy-Item -LiteralPath $i18nFile -Destination "$i18nFile.bak" -Force
  Write-Warn 'Backup overwritten (-Force).'
} else {
  Write-Warn 'Backup already exists (use -Force to overwrite). Continuing.'
}

$loader = [System.IO.File]::ReadAllText($i18nFile, [System.Text.Encoding]::UTF8)
$origLoader = $loader

$localesPatch = $false
$m = [regex]::Match($loader, '\["en","fr","zh-CN","zh-TW","uk","es","pt-BR","ko","pl","ja"\]')
if ($m.Success -and $loader -notmatch '"ru"') {
  $loader = $loader.Substring(0, $m.Index) + '["en","fr","zh-CN","zh-TW","uk","es","pt-BR","ko","pl","ja","ru"]' + $loader.Substring($m.Index + $m.Length)
  $localesPatch = $true
}
if ($localesPatch) { Write-Ok 'Patched LOCALES array.' } else { Write-Warn 'LOCALES array anchor not found (or "ru" already present).' }

$labelsPatch = $false
$m = [regex]::Match($loader, '(ja:"common\.language\.japanese"\s*,?\s*\})')
if ($m.Success -and $loader -notmatch 'ru:"common\.language\.russian"') {
  $replacement = 'ja:"common.language.japanese",ru:"common.language.russian"}'
  $loader = $loader.Substring(0, $m.Index) + $replacement + $loader.Substring($m.Index + $m.Length)
  $labelsPatch = $true
}
if ($labelsPatch) { Write-Ok 'Patched LOCALE_LABEL_KEYS.' } else { Write-Warn 'LOCALE_LABEL_KEYS anchor not found (or ru label already present).' }

$normPatch = $false
$m = [regex]::Match($loader, '(e==="pl"\|\|e\.startsWith\("pl-"\)\?"pl":\$1\})')
if ($m.Success -and $loader -notmatch 'e==="ru"\|\|e\.startsWith\("ru-"\)') {
  $replacement = 'e==="pl"||e.startsWith("pl-")?"pl":e==="ru"||e.startsWith("ru-")?"ru":$1}'
  $loader = $loader.Substring(0, $m.Index) + $replacement + $loader.Substring($m.Index + $m.Length)
  $normPatch = $true
}
if ($normPatch) { Write-Ok 'Patched normalizeLocale.' } else { Write-Warn 'normalizeLocale anchor not found (or ru branch already present).' }

$importPatch = $false
# Remove any stale ru import first
$loader = $loader -replace ':t==="ru"\?await\s+[a-zA-Z_]+\(\(\)=>import\("\./ru-[A-Za-z0-9_-]+\.js"\),\[\]\)', ''
$m = [regex]::Match($loader, 't==="pl"\?await\s+([a-zA-Z_]+)\(\(\)=>import\("\./pl-[A-Za-z0-9_-]+\.js"\),\[\]\)')
if ($m.Success -and $loader -notmatch ([regex]::Escape($ruFileName))) {
  $importFn = $m.Groups[1].Value
  $ruImport = ':t==="ru"?await ' + $importFn + '(()=>import("./' + $ruFileName + '"),[])'
  $insertionPoint = $m.Index + $m.Length
  $loader = $loader.Substring(0, $insertionPoint) + $ruImport + $loader.Substring($insertionPoint)
  $importPatch = $true
}
if ($importPatch) { Write-Ok 'Patched dynamic import chain.' } else { Write-Warn 'Dynamic import anchor not found (or ru import already present).' }

$defaultLocalePatch = $false
$m = [regex]::Match($loader, ',n2="en",')
if ($m.Success) {
  $loader = $loader.Substring(0, $m.Index) + ',n2="ru",' + $loader.Substring($m.Index + $m.Length)
  $defaultLocalePatch = $true
}
if ($defaultLocalePatch) { Write-Ok 'Set default locale to Russian.' } else { Write-Warn 'Default locale anchor not found.' }

$jfPatch = $false
$m = [regex]::Match($loader, 'function JF\(\)\{Is\.getState\(\)\.setLocale\(KF\(\)\)\}')
if ($m.Success -and $loader -notmatch 'localStorage\.setItem\("openchamber\.i18n\.v1"') {
  $replacement = 'function JF(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}Is.getState().setLocale(KF())}'
  $loader = $loader.Substring(0, $m.Index) + $replacement + $loader.Substring($m.Index + $m.Length)
  $jfPatch = $true
}
if ($jfPatch) { Write-Ok 'Forced Russian locale on startup.' } else { Write-Warn 'JF() anchor not found or already patched.' }

if ($loader -ne $origLoader) {
  Write-Utf8NoBom -Path $i18nFile -Content $loader
  Write-Ok 'Saved patched i18n loader.'
} else {
  Write-Warn 'Loader content unchanged.'
}

Write-Step 'Patching other locale chunks to add common.language.russian...'
$localeFiles = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match '^(en|fr|zh-CN|zh-TW|uk|es|pt-BR|ko|pl|ja)-' -and $_.Name -notmatch '^ru-'
}
foreach ($f in $localeFiles) {
  $bak = "$($f.FullName).bak"
  if (-not (Test-Path -LiteralPath $bak)) {
    Copy-Item -LiteralPath $f.FullName -Destination $bak -Force
  }
  $r = Patch-LocaleFile -Path $f.FullName
  switch ($r) {
    'patched'    { Write-Ok "  $($f.Name) -> patched" }
    'already'    { Write-Warn "  $($f.Name) -> already patched" }
    'no-anchor'  { Write-Warn "  $($f.Name) -> no anchor" }
  }
}

Write-Host ''
Write-Ok 'Russian translation installed successfully.'
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor White
Write-Host '  1. Fully quit OpenChamber (system tray -> Quit).'
Write-Host '  2. Start OpenChamber again.'
Write-Host '  3. Open Settings -> Appearance -> Language -> Russian.'
Write-Host ''
Write-Host 'To uninstall:' -ForegroundColor DarkGray
Write-Host '  Run uninstall-desktop-ru.cmd'
Write-Host ''
