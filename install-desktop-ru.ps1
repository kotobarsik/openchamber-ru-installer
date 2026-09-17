param(
  [string]$OpenChamberPath,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Log { param([string]$m) try { Add-Content -LiteralPath $script:logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction SilentlyContinue } catch {} }
function Write-Step { param([string]$m) Write-Host "[i] $m" -ForegroundColor Cyan; Write-Log "[i] $m" }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green; Write-Log "[+] $m" }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow; Write-Log "[!] $m" }
function Write-Err  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; Write-Log "[x] $m" }
function Next-Step  { param([string]$m) $script:step++; Write-Step ("Шаг $($script:step)/$($script:totalSteps): $m") }

$script:logFile = Join-Path $env:TEMP 'openchamber-ru-patch.log'
$script:totalSteps = 7
$script:step = 0
try {
  if ((Get-Item -LiteralPath $script:logFile -ErrorAction SilentlyContinue).Length -gt 2MB) {
    Remove-Item -LiteralPath $script:logFile -Force -ErrorAction SilentlyContinue
  }
} catch { }

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
  if (-not (Test-Path -LiteralPath $FilePath)) { throw "Нет файла: $FilePath" }
  $raw = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
  $startMarker = "export const $ExportName = {"
  $start = $raw.IndexOf($startMarker)
  if ($start -lt 0) { throw "Не найден 'export const $ExportName = {' в $FilePath" }
  $start += $startMarker.Length
  $end = $raw.LastIndexOf('} as const')
  if ($end -lt 0) { $end = $raw.LastIndexOf('};') }
  if ($end -lt $start) { throw "Не найден конец объекта $ExportName в $FilePath" }
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
          "'" { [void]$keySb.Append("'") }
          '"' { [void]$keySb.Append('"') }
          '\' { [void]$keySb.Append('\') }
          'n' { [void]$keySb.Append("`n") }
          'r' { [void]$keySb.Append("`r") }
          't' { [void]$keySb.Append("`t") }
          default { [void]$keySb.Append($n) }
        }
        $i += 2
      } else {
        [void]$keySb.Append($body[$i]); $i++
      }
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
          "'" { [void]$valSb.Append("'") }
          '"' { [void]$valSb.Append('"') }
          '\' { [void]$valSb.Append('\') }
          'n' { [void]$valSb.Append("`n") }
          'r' { [void]$valSb.Append("`r") }
          't' { [void]$valSb.Append("`t") }
          default { [void]$valSb.Append($n) }
        }
        $i += 2
      } else {
        [void]$valSb.Append($body[$i]); $i++
      }
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

function Get-AppVersion {
  param([string]$InstallDir)
  try {
    $v = (Get-Item -LiteralPath (Join-Path $InstallDir 'OpenChamber.exe') -ErrorAction Stop).VersionInfo.FileVersion
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  } catch { }
  return 'unknown'
}

function Read-PatchStamp {
  param([string]$StampPath)
  if (-not (Test-Path -LiteralPath $StampPath)) { return $null }
  try { return (Get-Content -LiteralPath $StampPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

$script:createdBaks = @()
$script:touchedFiles = @()
$script:wroteChunk = $false

function Invoke-Rollback {
  param([string]$ChunkPath)
  Write-Warn 'Откатываю изменения...'
  foreach ($f in $script:touchedFiles) {
    $bak = "$f.bak"
    if (Test-Path -LiteralPath $bak) {
      Copy-Item -LiteralPath $bak -Destination $f -Force
      Write-Warn ("  восстановлен " + (Split-Path -Leaf $f))
    } else {
      Write-Err ("  нет бэкапа для " + (Split-Path -Leaf $f) + " — оставляю как есть")
    }
  }
  foreach ($b in $script:createdBaks) {
    if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Force }
  }
  if ($script:wroteChunk -and $ChunkPath -and (Test-Path -LiteralPath $ChunkPath)) {
    Remove-Item -LiteralPath $ChunkPath -Force
  }
  Write-Warn 'Откат завершён.'
}

function Test-PatchedLoader {
  param([string]$Loader,[string]$ChunkName)
  $res = @()
  $res += @{ n = 'locales';   ok = ($Loader -match ',"ru"\]') }
  $res += @{ n = 'labels';    ok = ($Loader -match 'ru:"common\.language\.russian"') }
  $res += @{ n = 'normalize'; ok = ($Loader -match 'startsWith\("ru-"\)') }
  $res += @{ n = 'import';    ok = ($Loader.Contains($ChunkName) -and ($Loader -match 't==="ru"')) }
  $res += @{ n = 'init';      ok = ($Loader -match 'setLocale\("ru"\)') }
  return $res
}

function Stop-AppIfRunning {
  param([switch]$Force)
  if ($env:OC_RU_SKIP_APPCHECK -eq '1') { Write-Warn 'Проверка запущенного приложения пропущена (OC_RU_SKIP_APPCHECK=1).'; return }
  $procs = @(Get-Process -Name 'OpenChamber' -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { Write-Ok 'OpenChamber не запущен.'; return }
  Write-Warn ("OpenChamber запущен (процессов: {0}). Патчить файлы запущенного приложения опасно." -f $procs.Count)
  $close = $false
  if ($Force) {
    $close = $true
  } else {
    $ans = Read-Host 'Закрыть OpenChamber сейчас? (Y/N)'
    if ($ans -match '^([YyДд]|[Yy]es|[Дд]а)$') { $close = $true }
  }
  if (-not $close) { throw 'Прервано: сначала полностью выйдите из OpenChamber (трей -> Quit) и запустите снова.' }
  Write-Step 'Закрываю OpenChamber...'
  Stop-Process -Name 'OpenChamber' -Force -ErrorAction SilentlyContinue
  $waited = 0
  while ((Get-Process -Name 'OpenChamber' -ErrorAction SilentlyContinue) -and ($waited -lt 15)) {
    Start-Sleep -Seconds 1; $waited++
  }
  if (Get-Process -Name 'OpenChamber' -ErrorAction SilentlyContinue) {
    throw 'Не смог закрыть OpenChamber. Выйдите вручную (трей -> Quit) и запустите снова.'
  }
  Write-Ok 'OpenChamber закрыт.'
}

Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ' OpenChamber Desktop — русский перевод      ' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ''
Write-Log '=== install started ==='

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) {
  $found = Find-OpenChamberInstall
  if ($found) {
    Write-Step "Установка найдена: $found"
    $OpenChamberPath = $found
  } else {
    $OpenChamberPath = Read-Host 'Путь к OpenChamber (папка с OpenChamber.exe)'
  }
}

if ([string]::IsNullOrWhiteSpace($OpenChamberPath)) { throw 'Нужен путь установки.' }
$install = (Resolve-Path -LiteralPath $OpenChamberPath).Path
if (-not (Test-InstallDir -Path $install)) {
  throw "Не похоже на установку OpenChamber: $install (нужны OpenChamber.exe и resources\web-dist\assets)"
}

$assets = Join-Path $install 'resources\web-dist\assets'
Write-Step "Папка assets: $assets"

Next-Step 'Проверка запущенного OpenChamber'
Stop-AppIfRunning -Force:$Force

$appVersion = Get-AppVersion -InstallDir $install
Write-Step "Версия приложения: $appVersion"
$stampPath = Join-Path $assets '.ru-patch.json'
$stamp = Read-PatchStamp -StampPath $stampPath

$i18nFile = Find-FileByPattern -Dir $assets -Pattern 'useAppFontEffects-*.js'
if (-not $i18nFile) { throw "Не найден useAppFontEffects-*.js в $assets" }
Write-Step "Файл лоадера i18n: $(Split-Path -Leaf $i18nFile)"

# Detect stale leftovers (e.g. app updated without uninstall): loader unpatched
# but .bak / ru chunks / stamp from a previous install still present.
$loaderText = [System.IO.File]::ReadAllText($i18nFile, [System.Text.Encoding]::UTF8)
$loaderHasRu = $loaderText -match 't==="ru"'
$anyBak = @(Get-ChildItem -LiteralPath $assets -Filter '*.bak' -ErrorAction SilentlyContinue).Count -gt 0
$staleReason = $null
if ($stamp -and $stamp.appVersion -and $appVersion -ne 'unknown' -and $stamp.appVersion -ne $appVersion) {
  $staleReason = "приложение обновилось после патча (было $($stamp.appVersion), стало $appVersion)"
} elseif (-not $stamp -and $anyBak -and -not $loaderHasRu) {
  $staleReason = 'найдены осиротевшие бэкапы прошлой установки'
}
if ($staleReason) {
  Write-Warn "Найдено устаревшее состояние патча ($staleReason) — удаляю остатки для чистой установки."
  Get-ChildItem -LiteralPath $assets -Filter '*.bak' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $stampPath) { Remove-Item -LiteralPath $stampPath -Force -ErrorAction SilentlyContinue }
  $stamp = $null
}

$ruSrc       = Join-Path $scriptDir 'i18n\messages\ru.ts'
$ruSettings  = Join-Path $scriptDir 'i18n\messages\ru.settings.ts'
if (-not (Test-Path -LiteralPath $ruSrc))      { throw "Нет файла: $ruSrc" }
if (-not (Test-Path -LiteralPath $ruSettings)) { throw "Нет файла: $ruSettings" }

Next-Step 'Разбор словарей ru.ts и ru.settings.ts'
$dictBody     = Parse-TsDictBody -FilePath $ruSrc      -ExportName 'dict'
$settingsBody = Parse-TsDictBody -FilePath $ruSettings -ExportName 'settingsDict'

$entries = @{}
$settingsEntries = Parse-EntriesFromJsBody -body $settingsBody
foreach ($k in $settingsEntries.Keys) { $entries[$k] = $settingsEntries[$k] }
$mainEntries = Parse-EntriesFromJsBody -body $dictBody
foreach ($k in $mainEntries.Keys) { $entries[$k] = $mainEntries[$k] }
Write-Ok ("Всего ключей перевода: {0}" -f $entries.Count)

if ($entries.Count -lt 100) { throw "Слишком мало ключей ($($entries.Count)) — исходники повреждены." }

$ruContent = Build-RuJsContent -entries $entries
$hash = Compute-ShortHash -content $ruContent
$ruFileName = "ru-$hash.js"
$ruPath = Join-Path $assets $ruFileName
Write-Step "Имя ru-чанка: $ruFileName"

Next-Step 'Генерация ru-чанка'
Write-Utf8NoBom -Path $ruPath -Content $ruContent
$script:wroteChunk = $true
Write-Ok "Записан $ruPath"
# NOTE: stale ru-*.js chunks are removed only after successful verification (see below),
# so a failed run never leaves the loader pointing at a deleted chunk.

Next-Step 'Бэкап и патч лоадера i18n'
Write-Step 'Бэкап лоадера...'
if (($loaderText -match 't==="ru"') -and -not (Test-Path -LiteralPath "$i18nFile.bak")) {
  Write-Warn 'Лоадер уже содержит RU-правки, а бэкапа нет — пропускаю бэкап.'
  Write-Warn 'Удаление пойдёт через хирургический откат лоадера.'
} elseif (Backup-File -Path $i18nFile) {
  Write-Ok 'Бэкап создан: useAppFontEffects-*.js.bak'
  $script:createdBaks += "$i18nFile.bak"
} elseif ($Force) {
  Copy-Item -LiteralPath $i18nFile -Destination "$i18nFile.bak" -Force
  Write-Warn 'Бэкап перезаписан (-Force).'
} else {
  Write-Warn 'Бэкап уже есть (укажите -Force чтобы перезаписать). Продолжаю.'
}

$loader = [System.IO.File]::ReadAllText($i18nFile, [System.Text.Encoding]::UTF8)
$origLoader = $loader

$patchStates = @{}
function Report-PatchState {
  param([string]$Name,[string]$State)
  $patchStates[$Name] = $State
  if ($State -eq 'patched') { Write-Ok "Пропатчено: $Name." }
  elseif ($State -eq 'already') { Write-Host "  $Name — уже пропатчено." -ForegroundColor DarkGray }
  else { Write-Err "НЕ УДАЛОСЬ пропатчить: $Name (якорь не найден)." }
}

$localesState = 'FAILED'
$m = [regex]::Match($loader, '\["en"(?:,"[A-Za-z-]+")+\]')
if ($m.Success -and $m.Value -notmatch '"ru"') {
  $arr = $m.Value.TrimEnd(']') + ',"ru"]'
  $loader = $loader.Substring(0, $m.Index) + $arr + $loader.Substring($m.Index + $m.Length)
  $localesState = 'patched'
} elseif ($loader -match ',"ru"\]') {
  $localesState = 'already'
}
Report-PatchState -Name 'LOCALES array' -State $localesState

$labelsState = 'FAILED'
$m = [regex]::Match($loader, 'tr:"common\.language\.turkish"\}')
$labelsReplacement = 'tr:"common.language.turkish",ru:"common.language.russian"}'
if (-not $m.Success) {
  # Fallback for older builds (v1.14.x) without de/tr locales
  $m = [regex]::Match($loader, '(ja:"common\.language\.japanese"\s*,?\s*\})')
  $labelsReplacement = 'ja:"common.language.japanese",ru:"common.language.russian"}'
}
if ($m.Success -and $loader -notmatch 'ru:"common\.language\.russian"') {
  $loader = $loader.Substring(0, $m.Index) + $labelsReplacement + $loader.Substring($m.Index + $m.Length)
  $labelsState = 'patched'
} elseif ($loader -match 'ru:"common\.language\.russian"') {
  $labelsState = 'already'
}
Report-PatchState -Name 'LOCALE_LABEL_KEYS' -State $labelsState

$normState = 'FAILED'
$m = [regex]::Match($loader, '(e==="tr"\|\|e\.startsWith\("tr-"\)\?"tr":)([A-Za-z_$][A-Za-z0-9_$]*)\}')
$normPrefix = $null; $normDefault = $null
if ($m.Success) { $normPrefix = $m.Groups[1].Value; $normDefault = $m.Groups[2].Value }
if (-not $m.Success) {
  # Fallback for older builds (v1.14.x)
  $m = [regex]::Match($loader, '(e==="pl"\|\|e\.startsWith\("pl-"\)\?"pl":)([A-Za-z_$][A-Za-z0-9_$]*)\}')
  if ($m.Success) { $normPrefix = $m.Groups[1].Value; $normDefault = $m.Groups[2].Value }
}
if ($m.Success -and $loader -notmatch 'startsWith\("ru-"\)') {
  $replacement = $normPrefix + 'e==="ru"||e.startsWith("ru-")?"ru":' + $normDefault + '}'
  $loader = $loader.Substring(0, $m.Index) + $replacement + $loader.Substring($m.Index + $m.Length)
  $normState = 'patched'
} elseif ($loader -match 'startsWith\("ru-"\)') {
  $normState = 'already'
}
Report-PatchState -Name 'normalizeLocale' -State $normState

$importState = 'FAILED'
if ($loader -match (':t==="ru"\?await\s+\w+\(\(\)=>import\("\./' + [regex]::Escape($ruFileName) + '"\)')) {
  # Актуальный ru-импорт уже на месте — делать нечего.
  $importState = 'already'
} else {
  # Remove any stale ru import first (old bare format and new Vite mapDeps format)
  $loader = $loader -replace ':t==="ru"\?await\s+\w+\(\(\)=>import\("\./ru-[^"]+\.js"\)(?:,__vite__mapDeps\(\[[0-9,]*\]\))?(?:,\[\])?\)', ''
  $m = [regex]::Match($loader, 't==="tr"\?await\s+(\w+)\(\(\)=>import\("\./tr-[A-Za-z0-9_.-]+\.js"\),(__vite__mapDeps\(\[[0-9,]+\]\))\)')
  $importFn = $null; $importDeps = $null
  if ($m.Success) { $importFn = $m.Groups[1].Value; $importDeps = $m.Groups[2].Value }
  if (-not $m.Success) {
    # Fallback for older builds (v1.14.x, bare imports without mapDeps)
    $m = [regex]::Match($loader, 't==="pl"\?await\s+([a-zA-Z_]+)\(\(\)=>import\("\./pl-[A-Za-z0-9_-]+\.js"\),\[\]\)')
    if ($m.Success) { $importFn = $m.Groups[1].Value; $importDeps = '[]' }
  }
  if ($m.Success) {
    $ruImport = ':t==="ru"?await ' + $importFn + '(()=>import("./' + $ruFileName + '"),' + $importDeps + ')'
    $insertionPoint = $m.Index + $m.Length
    $loader = $loader.Substring(0, $insertionPoint) + $ruImport + $loader.Substring($insertionPoint)
    $importState = 'patched'
  }
}
Report-PatchState -Name 'dynamic import chain' -State $importState

$jfState = 'FAILED'
$initOrigText = $null
$m = [regex]::Match($loader, 'function JF\(\)\{Is\.getState\(\)\.setLocale\(KF\(\)\)\}')
if ($m.Success -and $loader -notmatch 'setLocale\("ru"\)') {
  # Older builds (v1.14.x)
  $initOrigText = $m.Value
  $replacement = 'function JF(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}try{y3.delete("ru")}catch(e){}Is.getState().setLocale("ru")}'
  $loader = $loader.Substring(0, $m.Index) + $replacement + $loader.Substring($m.Index + $m.Length)
  $jfState = 'patched'
} elseif ($loader -match 'setLocale\("ru"\)') {
  $jfState = 'already'
}
if ($jfState -ne 'patched') {
  # Newer builds (v1.22.x): minified names differ, resolve them dynamically.
  # Init looks like: function $z(){po.getState().setLocale(Oz())}
  # Cache looks like: const Cm=new Map([[P0,A0]])
  $mi = [regex]::Match($loader, 'function ([A-Za-z_$][A-Za-z0-9_$]*)\(\)\{([A-Za-z_$][A-Za-z0-9_$]*)\.getState\(\)\.setLocale\(([A-Za-z_$][A-Za-z0-9_$]*)\(\)\)\}')
  $mc = [regex]::Match($loader, 'const ([A-Za-z_$][A-Za-z0-9_$]*)=new Map\(\[\[[A-Za-z_$][A-Za-z0-9_$]*,[A-Za-z_$][A-Za-z0-9_$]*\]\]\)')
  if ($mi.Success -and $mc.Success -and $loader -notmatch 'setLocale\("ru"\)') {
    $initOrigText = $mi.Value
    $fnInit = $mi.Groups[1].Value; $fnStore = $mi.Groups[2].Value
    $fnCache = $mc.Groups[1].Value
    $replacement = 'function ' + $fnInit + '(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}try{' + $fnCache + '.delete("ru")}catch(e){}' + $fnStore + '.getState().setLocale("ru")}'
    $loader = $loader.Substring(0, $mi.Index) + $replacement + $loader.Substring($mi.Index + $mi.Length)
    $jfState = 'patched'
  } elseif ($loader -match 'setLocale\("ru"\)') {
    $jfState = 'already'
  }
}
Report-PatchState -Name 'startup locale init' -State $jfState

$failedPatches = @($patchStates.Keys | Where-Object { $patchStates[$_] -eq 'FAILED' })
if ($failedPatches.Count -gt 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Не сработали патчи: " + ($failedPatches -join ', ') + ". Обычно это значит, что новая сборка OpenChamber изменила формат бандла. Файлы откатаны; сообщите об этом с версией приложения ($appVersion).")
}

if ($loader -ne $origLoader) {
  Write-Utf8NoBom -Path $i18nFile -Content $loader
  $script:touchedFiles += $i18nFile
  Write-Ok 'Пропатченный лоадер сохранён.'
} else {
  Write-Host '  Лоадер без изменений (всё уже применено).' -ForegroundColor DarkGray
}

Next-Step 'Патч остальных локалей'
Write-Step 'Добавляю common.language.russian в остальные локали...'
$localeFiles = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match '^(en|fr|zh-CN|zh-TW|uk|es|pt-BR|ko|pl|ja|de|tr)-' -and $_.Name -notmatch '^ru-'
}
$localeFailed = @()
foreach ($f in $localeFiles) {
  $bak = "$($f.FullName).bak"
  if (-not (Test-Path -LiteralPath $bak)) {
    $chunkText = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($chunkText -match 'common\.language\.russian') {
      Write-Warn "  $($f.Name) уже пропатчен, а бэкапа нет — пропускаю бэкап."
    } else {
      Copy-Item -LiteralPath $f.FullName -Destination $bak -Force
      $script:createdBaks += $bak
    }
  }
  $r = Patch-LocaleFile -Path $f.FullName
  switch ($r) {
    'patched'    { Write-Ok "  $($f.Name) -> пропатчено"; $script:touchedFiles += $f.FullName }
    'already'    { Write-Host ("  " + $f.Name + " -> уже пропатчено") -ForegroundColor DarkGray }
    'no-anchor'  { Write-Err "  $($f.Name) -> нет якоря"; $localeFailed += $f.Name }
  }
}
if ($localeFailed.Count -gt 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Не сработали патчи чанков локалей: " + ($localeFailed -join ', ') + ". Файлы откатаны.")
}

Next-Step 'Проверка установки'
$verifyErrors = @()
$diskLoader = [System.IO.File]::ReadAllText($i18nFile, [System.Text.Encoding]::UTF8)
foreach ($c in (Test-PatchedLoader -Loader $diskLoader -ChunkName $ruFileName)) {
  if (-not $c.ok) { $verifyErrors += ("loader." + $c.n) }
}
if (-not (Test-Path -LiteralPath $ruPath)) {
  $verifyErrors += 'chunk.missing'
} else {
  $chunkText = [System.IO.File]::ReadAllText($ruPath, [System.Text.Encoding]::UTF8)
  $chunkKeys = ([regex]::Matches($chunkText, '":"')).Count
  if ($chunkKeys -lt 100) { $verifyErrors += 'chunk.too-few-keys' }
  if ($chunkText -notmatch '"common\.language\.russian":"') { $verifyErrors += 'chunk.no-russian-name' }
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($nodeCmd) {
    & node --check $ruPath | Out-Null
    if ($LASTEXITCODE -ne 0) { $verifyErrors += 'chunk.syntax' } else { Write-Ok 'Синтаксис чанка OK (node --check).' }
    & node --check $i18nFile | Out-Null
    if ($LASTEXITCODE -ne 0) { $verifyErrors += 'loader.syntax' } else { Write-Ok 'Синтаксис лоадера OK (node --check).' }
  } else {
    Write-Host '  node не найден — пропускаю проверку синтаксиса JS.' -ForegroundColor DarkGray
  }
  Write-Ok ("Ключей в чанке: $chunkKeys")
}
if ($verifyErrors.Count -gt 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Проверка не пройдена: " + ($verifyErrors -join ', ') + ". Файлы откатаны.")
}
Write-Ok 'Проверка пройдена.'

# Only now is it safe to remove obsolete ru chunks (loader references the new one).
Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $ruFileName } | ForEach-Object {
  Write-Warn "Удаляю устаревший ru-чанк: $($_.Name)"
  Remove-Item -LiteralPath $_.FullName -Force
}

if ($appVersion -ne 'unknown') {
  $stampObj = [pscustomobject]@{
    appVersion = $appVersion
    chunk      = $ruFileName
    keys       = $entries.Count
    date       = (Get-Date).ToString('o')
    loader     = (Split-Path -Leaf $i18nFile)
    initOrig   = $initOrigText
  }
  Write-Utf8NoBom -Path $stampPath -Content ($stampObj | ConvertTo-Json)
  Write-Ok 'Штамп патча записан (.ru-patch.json).'
}

Next-Step 'Чистка кэша'
Write-Step 'Чищу кэш Service Worker...'
$swPath = "$env:APPDATA\OpenChamber\Service Worker"
$cachePath = "$env:APPDATA\OpenChamber\Cache\Cache_Data"
$scriptCachePath = "$env:APPDATA\OpenChamber\ScriptCache"
$cleared = $false
if (Test-Path $swPath) { Remove-Item -Recurse -Force "$swPath\*" -ErrorAction SilentlyContinue; $cleared = $true }
if (Test-Path $cachePath) { Remove-Item -Recurse -Force "$cachePath\*" -ErrorAction SilentlyContinue; $cleared = $true }
if (Test-Path $scriptCachePath) { Remove-Item -Recurse -Force "$scriptCachePath\*" -ErrorAction SilentlyContinue; $cleared = $true }
if ($cleared) { Write-Ok 'Кэш очищен — старый перевод подтягиваться не будет.' } else { Write-Warn 'Кэш не найден.' }

Write-Host ''
Write-Ok 'Русский перевод успешно установлен.'
Write-Host ("  Приложение: $appVersion | Ключей: $($entries.Count) | Чанк: $ruFileName") -ForegroundColor DarkGray
Write-Host ("  Лог: " + $script:logFile) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Дальше:' -ForegroundColor White
Write-Host '  1. Полностью выйдите из OpenChamber (трей -> Quit).'
Write-Host '  2. Запустите OpenChamber снова.'
Write-Host '  3. Откройте Settings -> Appearance -> Language -> Russian.'
Write-Host ''
Write-Host 'Удаление:' -ForegroundColor DarkGray
Write-Host '  Запустите uninstall-desktop-ru.cmd'
Write-Host ''
