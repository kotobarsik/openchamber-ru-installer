param(
  [string]$OpenChamberPath,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Под `irm ... | iex` путь скрипта пуст. $scriptDir нужен только для локального
# запуска из клона репозитория, так что пустым он быть не должен.
$scriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { '' }

# Windows PowerShell 5.1 на части машин не включает TLS 1.2, а он обязателен
# для raw.githubusercontent.com.
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

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

# Находит .js-файл в $Dir, в котором присутствуют ВСЕ искомые regex-паттерны.
# Сначала проверяет файлы с именем вида $PreferredFilter (если задан), затем все остальные.
function Find-ContentFile {
  param([string]$Dir,[string[]]$Patterns,[string]$PreferredFilter)
  $rx = @($Patterns | ForEach-Object { [regex]$_ })
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.js' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.bak$' })
  $test = {
    param($full)
    $s = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    foreach ($r in $rx) { if (-not $r.IsMatch($s)) { return $false } }
    return $true
  }
  if ($PreferredFilter) {
    foreach ($f in ($files | Where-Object { $_.Name -like $PreferredFilter })) {
      if (& $test $f.FullName) { return $f.FullName }
    }
  }
  foreach ($f in $files) {
    if (& $test $f.FullName) { return $f.FullName }
  }
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

# Откуда качать исходники перевода, когда установщик запущен из сети
# (`irm https://... | iex`) и рядом нет файлов репозитория.
# OC_RU_SOURCE — переопределение для тестов/зеркал.
$script:SourceBase = if ($env:OC_RU_SOURCE) { $env:OC_RU_SOURCE } else { 'https://raw.githubusercontent.com/kotobarsik/openchamber-ru-installer/main' }

# Отдаёт путь к i18n-исходнику: локальный файл из клона, иначе свежая загрузка
# в %TEMP%. Качаем каждый раз заново с cache-buster — иначе «обновить перевод»
# молча подставит старый файл из кэша.
function Get-MessagesFile {
  param([string]$Name)
  if ($scriptDir) {
    $local = Join-Path $scriptDir "i18n\messages\$Name"
    if (Test-Path -LiteralPath $local) { return $local }
  }
  $cacheDir = Join-Path $env:TEMP 'openchamber-ru'
  if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
  $out = Join-Path $cacheDir $Name
  # ${Name}, а не $Name? — в PowerShell '?' допустим в имени переменной,
  # и без скобок URL остался бы без имени файла.
  $url = "$script:SourceBase/i18n/messages/${Name}?$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  Write-Step "Скачиваю перевод: $Name"
  try {
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
  } catch {
    throw ("Не удалось скачать перевод ({0}): {1}. Проверьте интернет или задайте другой адрес через OC_RU_SOURCE." -f $Name, $_.Exception.Message)
  }
  return $out
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
  param([string]$Core,[string]$Intl,[string]$ChunkName)
  $res = @()
  $res += @{ n = 'locales';   ok = ($Core -match ',"ru"\]') }
  $res += @{ n = 'labels';    ok = ($Core -match 'ru:"common\.language\.russian"') }
  $res += @{ n = 'normalize'; ok = ($Core -match 'startsWith\("ru-"\)') }
  $res += @{ n = 'import';    ok = ($Core.Contains($ChunkName) -and ($Core -match '[A-Za-z_$][A-Za-z0-9_$]*==="ru"\?await')) }
  $res += @{ n = 'init';      ok = ($Core -match 'setLocale\("ru"\)') }
  # Подпись «Russian» для английского словаря: либо добавлена, либо EN-словарь
  # этой сборки не содержит карты подписей языков (очень старые сборки).
  $res += @{ n = 'en-label';  ok = (($Core -match '"common\.language\.russian":"Russian"') -or ($Core -notmatch '"common\.language\.hebrew":"Hebrew"')) }
  # INTL-карта: либо ru:"ru-RU" добавлен, либо карты нет вовсе (старые сборки).
  $res += @{ n = 'intl';      ok = (($Intl -match 'ru:"ru-RU"') -or ($Intl -notmatch '\{en:"en-US"')) }
  # Карта дневных подсказок лоадера (v2.5.x): либо ru добавлен, либо карты нет.
  $res += @{ n = 'copy-map';  ok = ((($Core + $Intl) -notmatch '\{de:\(\)=>[^{}]*he:\(\)=>') -or (($Core + $Intl) -match 'ru:\(\)=>Promise\.resolve\(\{copy:')) }
  return $res
}

# Добавляет ru:"ru-RU" в INTL-карту локалей ({en:"en-US",...,tr:"tr-TR"}).
# Возвращает @{ text; state }: state = patched | already | skip | FAILED.
function Patch-IntlMap {
  param([string]$Text)
  $m = [regex]::Match($Text, '\{en:"en-US"[^{}]{0,400}?\}')
  if ($m.Success -and $m.Value -notmatch 'ru:"ru-RU"') {
    $replacement = $m.Value.Substring(0, $m.Value.Length - 1) + ',ru:"ru-RU"}'
    return @{ text = $Text.Substring(0, $m.Index) + $replacement + $Text.Substring($m.Index + $m.Length); state = 'patched' }
  }
  if ($Text -match 'ru:"ru-RU"') { return @{ text = $Text; state = 'already' } }
  if (-not $m.Success -and $Text -notmatch '\{en:"en-US"') {
    # Старые сборки (v1.14.x) могли не иметь этой карты вовсе — там и время
    # форматируется иначе. Не валим установку, только предупреждаем.
    return @{ text = $Text; state = 'skip' }
  }
  return @{ text = $Text; state = 'FAILED' }
}

function Patch-CopyMap {
  param([string]$Text)
  # В v2.5.x у лоадера появилась отдельная карта дневных подсказок
  # ({de:()=>...,...,he:()=>...}, экспорт copy), независимая от словаря UI.
  # Без ru в этой карте принудительный setLocale("ru") падает на Mvt[t]().
  # Ищем именно объект карты: "disable:()=>" тоже содержит подстроку "de:()=>".
  $mMap = [regex]::Match($Text, '\{de:\(\)=>[^{}]*he:\(\)=>[^{}]*\}')
  if (-not $mMap.Success) { return @{ text = $Text; state = 'skip' } }
  if ($Text -match 'ru:\(\)=>Promise\.resolve\(\{copy:') { return @{ text = $Text; state = 'already' } }
  $mEn = [regex]::Match($Text, 'byLocale:\{en:([A-Za-z_$][A-Za-z0-9_$]*)\}')
  if (-not $mEn.Success) { return @{ text = $Text; state = 'FAILED' } }
  $copyVar = $mEn.Groups[1].Value
  $insert = ',ru:()=>Promise.resolve({copy:' + $copyVar + '})'
  $insertAt = $mMap.Index + $mMap.Length - 1
  return @{ text = $Text.Substring(0, $insertAt) + $insert + $Text.Substring($insertAt); state = 'patched' }
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

# i18n-ядро (LOCALES-массив + карта подписей локалей) ищем ПО КОНТЕНТУ, а не по имени:
# в 2.2.x это отдельный chank index-*.js, в 2.1.x — тот же useAppFontEffects-*.js.
$coreFile = Find-ContentFile -Dir $assets -Patterns @('\["en"(?:,"[A-Za-z-]+")+\]', 'tr:"common\.language\.turkish"')
if (-not $coreFile) { throw "Не найдено ядро i18n (LOCALES-массив + карта локалей) в $assets" }
Write-Step "Файл ядра i18n: $(Split-Path -Leaf $coreFile)"

# INTL-карта locale -> Intl-тег ({en:"en-US",...,tr:"tr-TR"}) в 2.2.x живёт в
# лоадере useAppFontEffects-*.js, в 2.1.x — в том же файле, что и ядро.
$intlFile = Find-ContentFile -Dir $assets -Patterns @('\{en:"en-US"[^{}]{0,400}?\}') -PreferredFilter 'useAppFontEffects-*.js'
if (-not $intlFile) { $intlFile = $coreFile }
$sameFile = ($coreFile -eq $intlFile)
Write-Step "Файл INTL-карты: $(Split-Path -Leaf $intlFile)"
if ($sameFile) { Write-Host '  Ядро и INTL-карта в одном файле (раскладка 2.1.x).' -ForegroundColor DarkGray }

# Detect stale leftovers (e.g. app updated without uninstall): loader unpatched
# but .bak / ru chunks / stamp from a previous install still present.
$coreText = [System.IO.File]::ReadAllText($coreFile, [System.Text.Encoding]::UTF8)
$intlText  = [System.IO.File]::ReadAllText($intlFile, [System.Text.Encoding]::UTF8)
$ruMarkerRx = '==="ru"\?await|,"ru"\]|ru:"common\.language\.russian"|setLocale\("ru"\)|ru:"ru-RU"'
$filesHasRu = (($coreText -match $ruMarkerRx) -or ($intlText -match $ruMarkerRx))
$anyBak = @(Get-ChildItem -LiteralPath $assets -Filter '*.bak' -ErrorAction SilentlyContinue).Count -gt 0
$staleReason = $null
if ($stamp -and $stamp.appVersion -and $appVersion -ne 'unknown' -and $stamp.appVersion -ne $appVersion) {
  $staleReason = "приложение обновилось после патча (было $($stamp.appVersion), стало $appVersion)"
} elseif (-not $stamp -and $anyBak -and -not $filesHasRu) {
  $staleReason = 'найдены осиротевшие бэкапы прошлой установки'
}
if ($staleReason) {
  Write-Warn "Найдено устаревшее состояние патча ($staleReason) — удаляю остатки для чистой установки."
  Get-ChildItem -LiteralPath $assets -Filter '*.bak' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $stampPath) { Remove-Item -LiteralPath $stampPath -Force -ErrorAction SilentlyContinue }
  $stamp = $null
}

$ruSrc       = Get-MessagesFile 'ru.ts'
$ruSettings  = Get-MessagesFile 'ru.settings.ts'

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

Next-Step 'Бэкап и патч файлов i18n'
$patchFiles = @($coreFile)
if (-not $sameFile) { $patchFiles += $intlFile }
foreach ($pf in $patchFiles) {
  $leaf = Split-Path -Leaf $pf
  $pfHasRu = ([System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8) -match $ruMarkerRx)
  if ($pfHasRu -and -not (Test-Path -LiteralPath "$pf.bak")) {
    Write-Warn "$leaf уже содержит RU-правки, а бэкапа нет — пропускаю бэкап."
    Write-Warn 'Удаление пойдёт через хирургический откат.'
  } elseif (Backup-File -Path $pf) {
    Write-Ok "Бэкап создан: $leaf.bak"
    $script:createdBaks += "$pf.bak"
  } elseif ($Force -and -not $pfHasRu) {
    Copy-Item -LiteralPath $pf -Destination "$pf.bak" -Force
    Write-Warn "Бэкап перезаписан (-Force): $leaf.bak"
  } elseif ($Force) {
    # КРИТИЧНО: перезаписать бэкап уже пропатченным лоадером нельзя — откат
    # станет невозможен, и uninstall не сможет вернуть стоковый файл.
    Write-Warn "$leaf уже пропатчен, а бэкап есть — бэкап НЕ перезаписываю (даже с -Force)."
  } else {
    Write-Warn "Бэкап уже есть ($leaf.bak, укажите -Force чтобы перезаписать). Продолжаю."
  }
}

$core = $coreText
$intl = $intlText
$origCore = $core
$origIntl = $intl

$patchStates = @{}
function Report-PatchState {
  param([string]$Name,[string]$State)
  $patchStates[$Name] = $State
  if ($State -eq 'patched') { Write-Ok "Пропатчено: $Name." }
  elseif ($State -eq 'already') { Write-Host "  $Name — уже пропатчено." -ForegroundColor DarkGray }
  elseif ($State -eq 'skip') { Write-Warn "Пропущено: $Name (якоря нет, старая сборка)." }
  else { Write-Err "НЕ УДАЛОСЬ пропатчить: $Name (якорь не найден)." }
}

$localesState = 'FAILED'
$m = [regex]::Match($core, '\["en"(?:,"[A-Za-z-]+")+\]')
if ($m.Success -and $m.Value -notmatch '"ru"') {
  $arr = $m.Value.TrimEnd(']') + ',"ru"]'
  $core = $core.Substring(0, $m.Index) + $arr + $core.Substring($m.Index + $m.Length)
  $localesState = 'patched'
} elseif ($core -match ',"ru"\]') {
  $localesState = 'already'
}
Report-PatchState -Name 'LOCALES array' -State $localesState

$labelsState = 'FAILED'
# В 2.3.1 после tr идут ar/he, поэтому старый якорь '…turkish"}' больше не совпадает.
# Цепляемся к самой паре tr и вставляем ru сразу после неё (закрывающая скобка
# объекта остаётся на месте, что верно и для старых сборок, где tr был последним).
$m = [regex]::Match($core, 'tr:"common\.language\.turkish"')
$labelsReplacement = 'tr:"common.language.turkish",ru:"common.language.russian"'
if (-not $m.Success) {
  # Fallback for older builds (v1.14.x) without de/tr locales
  $m = [regex]::Match($core, '(ja:"common\.language\.japanese"\s*,?\s*\})')
  $labelsReplacement = 'ja:"common.language.japanese",ru:"common.language.russian"}'
}
if ($m.Success -and $core -notmatch 'ru:"common\.language\.russian"') {
  $core = $core.Substring(0, $m.Index) + $labelsReplacement + $core.Substring($m.Index + $m.Length)
  $labelsState = 'patched'
} elseif ($core -match 'ru:"common\.language\.russian"') {
  $labelsState = 'already'
}
Report-PatchState -Name 'LOCALE_LABEL_KEYS' -State $labelsState

# EN-словарь встроен в ядро, и подписи языков берутся из него как запасной вариант
# (e[t] ?? en[t] ?? t). Без ключа common.language.russian в английском интерфейсе
# список языков показал бы сырое имя ключа вместо «Russian». Локали-чанки получают
# эту пару в шаге 5, английскому словарю её добавляем здесь.
$enLabelState = 'FAILED'
if ($core -match '"common\.language\.russian":"Russian"') {
  $enLabelState = 'already'
} else {
  $mEn = [regex]::Match($core, '"common\.language\.hebrew":"Hebrew",')
  if ($mEn.Success) {
    $core = $core.Substring(0, $mEn.Index + $mEn.Length) + '"common.language.russian":"Russian",' + $core.Substring($mEn.Index + $mEn.Length)
    $enLabelState = 'patched'
  } elseif ($core -notmatch '"common\.language\.hebrew":"Hebrew"') {
    # Старые сборки без ar/he в словаре — подпись некуда вставлять, не валим установку.
    $enLabelState = 'skip'
  }
}
Report-PatchState -Name 'EN dict (common.language.russian)' -State $enLabelState

# normalizeLocale: имя параметра функции берём из реального кода tr-ветки через
# обратную ссылку (в 2.2.0 параметр t, в 2.1.x был e).
# В 2.3.1 после tr-ветки идут ar/he, поэтому якорь, требовавший '…"tr":}' (конец
# цепочки), больше не срабатывает. Цепляемся к самой tr-ветке и вставляем ru-ветку
# ПЕРЕД ней — это одинаково верно и для старых сборок, где после tr шла '}'.
$normState = 'FAILED'
$m = [regex]::Match($core, '([A-Za-z_$][A-Za-z0-9_$]*)==="tr"\|\|\1\.startsWith\("tr-"\)\?"tr":')
$normParam = $null
if ($m.Success) { $normParam = $m.Groups[1].Value }
if (-not $m.Success) {
  # Fallback for older builds (v1.14.x): последняя известная локаль — pl
  $m = [regex]::Match($core, '([A-Za-z_$][A-Za-z0-9_$]*)==="pl"\|\|\1\.startsWith\("pl-"\)\?"pl":')
  if ($m.Success) { $normParam = $m.Groups[1].Value }
}
if ($m.Success -and $core -notmatch 'startsWith\("ru-"\)') {
  $replacement = $normParam + '==="ru"||' + $normParam + '.startsWith("ru-")?"ru":' + $m.Value
  $core = $core.Substring(0, $m.Index) + $replacement + $core.Substring($m.Index + $m.Length)
  $normState = 'patched'
} elseif ($core -match 'startsWith\("ru-"\)') {
  $normState = 'already'
}
Report-PatchState -Name 'normalizeLocale' -State $normState

# INTL-карта locale -> Intl-тег ({en:"en-US",...,tr:"tr-TR"}) не знает про "ru",
# и getCurrentIntlLocale() молча падает на "en-US": 12-часовой формат (AM/PM),
# en-US порядок дат и запятая в числах. Добавляем ru:"ru-RU" -> 24-часовой формат.
# В двухфайловой раскладке (2.2.x) карта в лоадере $intl, в однофайловой (2.1.x) — в ядре.
$intlState = 'FAILED'
$intlTarget = if ($sameFile) { $core } else { $intl }
$r = Patch-IntlMap -Text $intlTarget
$intlTarget = $r.text
if ($sameFile) { $core = $intlTarget } else { $intl = $intlTarget }
$intlState = $r.state
if ($intlState -eq 'skip') { Write-Warn 'INTL-карта локалей не найдена (старая сборка?) — формат времени останется системным.' }
Report-PatchState -Name 'INTL locale map (ru -> ru-RU)' -State $intlState

# Динамический импорт ru-чанка: режем ветку tr/pl и вставляем ru-ветку сразу после.
# Имя параметра и import-функции берём из реального кода (в 2.2.0 это e + Ue,
# в 2.1.x были t + имя с m).
$importState = 'FAILED'
if ($core -match (':[A-Za-z_$][A-Za-z0-9_$]*==="ru"\?await\s+\w+\(\(\)=>import\("\./' + [regex]::Escape($ruFileName) + '"\)')) {
  # Актуальный ru-импорт уже на месте — делать нечего.
  $importState = 'already'
} else {
  # Remove any stale ru import first (old bare format and new Vite mapDeps format)
  $core = $core -replace ':[A-Za-z_$][A-Za-z0-9_$]*==="ru"\?await\s+\w+\(\(\)=>import\("\./ru-[^"]+\.js"\)(?:,__vite__mapDeps\(\[[0-9,]*\]\))?(?:,\[\])?\)', ''
  $m = [regex]::Match($core, '([A-Za-z_$][A-Za-z0-9_$]*)==="tr"\?await\s+(\w+)\(\(\)=>import\("\./tr-[A-Za-z0-9_.-]+\.js"\),(__vite__mapDeps\(\[[0-9,]+\]\))\)')
  $importParam = $null; $importFn = $null; $importDeps = $null
  if ($m.Success) { $importParam = $m.Groups[1].Value; $importFn = $m.Groups[2].Value; $importDeps = $m.Groups[3].Value }
  if (-not $m.Success) {
    # Fallback for older builds (v1.14.x, bare imports without mapDeps)
    $m = [regex]::Match($core, '([A-Za-z_$][A-Za-z0-9_$]*)==="pl"\?await\s+([a-zA-Z_]+)\(\(\)=>import\("\./pl-[A-Za-z0-9_-]+\.js"\),\[\]\)')
    if ($m.Success) { $importParam = $m.Groups[1].Value; $importFn = $m.Groups[2].Value; $importDeps = '[]' }
  }
  if ($m.Success) {
    $ruImport = ':' + $importParam + '==="ru"?await ' + $importFn + '(()=>import("./' + $ruFileName + '"),' + $importDeps + ')'
    $insertionPoint = $m.Index + $m.Length
    $core = $core.Substring(0, $insertionPoint) + $ruImport + $core.Substring($insertionPoint)
    $importState = 'patched'
  }
}
Report-PatchState -Name 'dynamic import chain' -State $importState

# Отдельная карта дневных подсказок в лоадере (v2.5.x). Если её не патчить,
# принудительный русский locale падает с "Mvt[t] is not a function" ещё до
# отрисовки интерфейса. Для ru используем английский copy как безопасный запасной
# вариант: подсказки декоративные, а словарь UI грузится отдельной веткой выше.
$copyState = 'skip'
$copyTargets = if ($sameFile) { @('core') } else { @('intl','core') }
foreach ($copyTargetName in $copyTargets) {
  $copyTarget = if ($copyTargetName -eq 'core') { $core } else { $intl }
  $copyResult = Patch-CopyMap -Text $copyTarget
  if ($copyResult.state -eq 'skip') { continue }
  if ($copyTargetName -eq 'core') { $core = $copyResult.text } else { $intl = $copyResult.text }
  $copyState = $copyResult.state
  break
}
if ($copyState -eq 'skip') { Write-Host '  Карта дневных подсказок не найдена (эта сборка её не использует).' -ForegroundColor DarkGray }
Report-PatchState -Name 'copy locale map (ru fallback)' -State $copyState

$jfState = 'FAILED'
$initOrigText = $null
$m = [regex]::Match($core, 'function JF\(\)\{Is\.getState\(\)\.setLocale\(KF\(\)\)\}')
if ($m.Success -and $core -notmatch 'setLocale\("ru"\)') {
  # Older builds (v1.14.x)
  $initOrigText = $m.Value
  $replacement = 'function JF(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}try{y3.delete("ru")}catch(e){}Is.getState().setLocale("ru")}'
  $core = $core.Substring(0, $m.Index) + $replacement + $core.Substring($m.Index + $m.Length)
  $jfState = 'patched'
} elseif ($core -match 'setLocale\("ru"\)') {
  $jfState = 'already'
}
if ($jfState -ne 'patched') {
  # Newer builds (v1.22.x): minified names differ, resolve them dynamically.
  # Init looks like: function $z(){po.getState().setLocale(Oz())}
  # Cache looks like: const Cm=new Map([[P0,A0]]) (в 2.2.0 кэш объявлен без const: yr=new Map([[pi,ui]]))
  $mi = [regex]::Match($core, 'function ([A-Za-z_$][A-Za-z0-9_$]*)\(\)\{([A-Za-z_$][A-Za-z0-9_$]*)\.getState\(\)\.setLocale\(([A-Za-z_$][A-Za-z0-9_$]*)\(\)\)\}')
  $mc = [regex]::Match($core, '(?:const )?([A-Za-z_$][A-Za-z0-9_$]*)=new Map\(\[\[[A-Za-z_$][A-Za-z0-9_$]*,[A-Za-z_$][A-Za-z0-9_$]*\]\]\)')
  if ($mi.Success -and $mc.Success -and $core -notmatch 'setLocale\("ru"\)') {
    $initOrigText = $mi.Value
    $fnInit = $mi.Groups[1].Value; $fnStore = $mi.Groups[2].Value
    $fnCache = $mc.Groups[1].Value
    $replacement = 'function ' + $fnInit + '(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}try{' + $fnCache + '.delete("ru")}catch(e){}' + $fnStore + '.getState().setLocale("ru")}'
    $core = $core.Substring(0, $mi.Index) + $replacement + $core.Substring($mi.Index + $mi.Length)
    $jfState = 'patched'
  } elseif ($core -match 'setLocale\("ru"\)') {
    $jfState = 'already'
  }
}
Report-PatchState -Name 'startup locale init' -State $jfState

# Повторный запуск поверх уже пропатченного ядра не может восстановить исходный
# вид init-функции — берём его из штампа прошлой установки, иначе удаление
# без .bak не сможет вернуть файл байт-в-байт.
if (-not $initOrigText -and $stamp -and $stamp.initOrig -and ($core -match 'setLocale\("ru"\)')) {
  $initOrigText = $stamp.initOrig
}

$failedPatches = @($patchStates.Keys | Where-Object { $patchStates[$_] -eq 'FAILED' })
if ($failedPatches.Count -gt 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Не сработали патчи: " + ($failedPatches -join ', ') + ". Обычно это значит, что новая сборка OpenChamber изменила формат бандла. Файлы откатаны; сообщите об этом с версией приложения ($appVersion).")
}

if ($core -ne $origCore) {
  Write-Utf8NoBom -Path $coreFile -Content $core
  $script:touchedFiles += $coreFile
  Write-Ok 'Пропатченное ядро i18n сохранено.'
} else {
  Write-Host '  Ядро i18n без изменений (всё уже применено).' -ForegroundColor DarkGray
}
if (-not $sameFile) {
  if ($intl -ne $origIntl) {
    Write-Utf8NoBom -Path $intlFile -Content $intl
    $script:touchedFiles += $intlFile
    Write-Ok 'Пропатченный лоадер INTL сохранён.'
  } else {
    Write-Host '  INTL-лоадер без изменений (всё уже применено).' -ForegroundColor DarkGray
  }
}

Next-Step 'Патч остальных локалей'
Write-Step 'Добавляю common.language.russian в остальные локали...'
$localeFiles = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match '^(en|fr|zh-CN|zh-TW|uk|es|pt-BR|ko|pl|ja|de|tr|nl|ar|he)-' -and $_.Name -notmatch '^ru-'
}
$localeFailed = @()
$localeSkipped = @()
$localeHandled = 0
foreach ($f in $localeFiles) {
  # NOTE: начиная с 2.0.3 сборка кладёт рядом сторонние данные локалей
  # (пакеты иконочного пикера вида de-DE-*.js, ru-RU-*.js) с тем же префиксом
  # имени. Настоящие словари UI всегда содержат ключи common.language.* —
  # файлы без них пропускаем, а не валим установку.
  $probe = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  if ($probe -notmatch 'common\.language\.') {
    Write-Host ("  " + $f.Name + " -> не словарь UI, пропускаю") -ForegroundColor DarkGray
    $localeSkipped += $f.Name
    continue
  }
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
    'patched'    { Write-Ok "  $($f.Name) -> пропатчено"; $script:touchedFiles += $f.FullName; $localeHandled++ }
    'already'    { Write-Host ("  " + $f.Name + " -> уже пропатчено") -ForegroundColor DarkGray; $localeHandled++ }
    'no-anchor'  { Write-Err "  $($f.Name) -> нет якоря"; $localeFailed += $f.Name }
  }
}
if ($localeFailed.Count -gt 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Не сработали патчи чанков локалей: " + ($localeFailed -join ', ') + ". Файлы откатаны.")
}
if ($localeHandled -eq 0) {
  Invoke-Rollback -ChunkPath $ruPath
  throw ("Не найден ни один словарь локалей (пропущено посторонних файлов: $($localeSkipped.Count)). Похоже, новая сборка OpenChamber изменила формат чанков. Файлы откатаны.")
}
if ($localeSkipped.Count -gt 0) {
  Write-Host ("  Пропущено посторонних файлов: $($localeSkipped.Count)") -ForegroundColor DarkGray
}

Next-Step 'Проверка установки'
$verifyErrors = @()
$diskCore = [System.IO.File]::ReadAllText($coreFile, [System.Text.Encoding]::UTF8)
$diskIntl = if ($sameFile) { $diskCore } else { [System.IO.File]::ReadAllText($intlFile, [System.Text.Encoding]::UTF8) }
foreach ($c in (Test-PatchedLoader -Core $diskCore -Intl $diskIntl -ChunkName $ruFileName)) {
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
    & node --check $coreFile | Out-Null
    if ($LASTEXITCODE -ne 0) { $verifyErrors += 'core.syntax' } else { Write-Ok 'Синтаксис ядра OK (node --check).' }
    & node --check $intlFile | Out-Null
    if ($LASTEXITCODE -ne 0) { $verifyErrors += 'intl.syntax' } else { Write-Ok 'Синтаксис INTL-лоадера OK (node --check).' }
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
# NOTE: удаляем только наши чанки вида ru-<8 hex>.js; stock-файлы сборки
# (ru-RU-*.js и т.п., появились в 2.0.3) трогать нельзя.
Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $ruFileName -and $_.Name -match '^ru-[0-9a-f]{8}\.js$' } | ForEach-Object {
  Write-Warn "Удаляю устаревший ru-чанк: $($_.Name)"
  Remove-Item -LiteralPath $_.FullName -Force
}

if ($appVersion -ne 'unknown') {
  $stampObj = [pscustomobject]@{
    appVersion = $appVersion
    chunk      = $ruFileName
    keys       = $entries.Count
    date       = (Get-Date).ToString('o')
    core       = (Split-Path -Leaf $coreFile)
    intl       = if ($sameFile) { $null } else { (Split-Path -Leaf $intlFile) }
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
