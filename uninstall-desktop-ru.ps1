param(
  [string]$OpenChamberPath,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$m) try { Add-Content -LiteralPath $script:logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction SilentlyContinue } catch {} }
function Write-Step { param([string]$m) Write-Host "[i] $m" -ForegroundColor Cyan; Write-Log "[i] $m" }
function Write-Ok   { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green; Write-Log "[+] $m" }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow; Write-Log "[!] $m" }
function Write-Err  { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red; Write-Log "[x] $m" }

$script:logFile = Join-Path $env:TEMP 'openchamber-ru-patch.log'
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
    $assets = Join-Path $c 'resources\web-dist\assets'
    if ((Test-Path -LiteralPath (Join-Path $c 'OpenChamber.exe')) -and (Test-Path -LiteralPath $assets)) {
      return (Resolve-Path -LiteralPath $c).Path
    }
  }
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

function Restore-FromBackup {
  param([string]$Path)
  $bak = "$Path.bak"
  if (-not (Test-Path -LiteralPath $bak)) { return $false }
  Copy-Item -LiteralPath $bak -Destination $Path -Force
  Remove-Item -LiteralPath $bak -Force
  return $true
}

function Get-AppVersion {
  param([string]$InstallDir)
  try {
    $v = (Get-Item -LiteralPath (Join-Path $InstallDir 'OpenChamber.exe') -ErrorAction Stop).VersionInfo.FileVersion
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  } catch { }
  return 'unknown'
}

function Remove-RuFromLoader {
  # Best-effort surgical reversal of the RU patch when no .bak exists.
  # Returns @{ text = <loader>; initLeft = <bool> }.
  param([string]$Loader,[string]$InitOrig)
  $l = $Loader
  $l = [regex]::Replace($l, '(\["en"(?:,"[A-Za-z-]+")*),"ru"\]', '$1]')
  # В 2.3.1 ru вставляется после tr, а дальше идут ar/he, поэтому '…russian"}' уже не
  # закрывает объект — вырезаем саму пару целиком, не трогая следующую за ней.
  $l = $l -replace ',ru:"common\.language\.russian"', ''
  # Подпись «Russian» в английском словаре внутри ядра (шаг «EN dict»).
  $l = $l -replace '"common\.language\.russian":"Russian",', ''
  # Имя параметра normalizeLocale гибкое (в 2.2.0 t, в 2.1.x e) — вырезаем по маске.
  $l = $l -replace '[A-Za-z_$][A-Za-z0-9_$]*==="ru"\|\|[A-Za-z_$][A-Za-z0-9_$]*\.startsWith\("ru-"\)\?"ru":', ''
  $l = $l -replace ',ru:"ru-RU"\}', '}'
  # Имя параметра импорта гибкое (в 2.2.0 e, в 2.1.x t).
  $l = $l -replace ':[A-Za-z_$][A-Za-z0-9_$]*==="ru"\?await\s+\w+\(\(\)=>import\("\./ru-[^"]+\.js"\)(?:,__vite__mapDeps\(\[[0-9,]*\]\))?(?:,\[\])?\)', ''
  $initLeft = $false
  if ($l -match 'setLocale\("ru"\)') {
    $reversed = $false
    # Older builds (v1.14.x): forced init has fixed minified names — reversible exactly.
    $oldForced = 'function JF(){try{typeof window!="undefined"&&window.localStorage.setItem("openchamber.i18n.v1",JSON.stringify({locale:"ru"}))}catch{}try{y3.delete("ru")}catch(e){}Is.getState().setLocale("ru")}'
    if ($l.Contains($oldForced)) {
      $l = $l.Replace($oldForced, 'function JF(){Is.getState().setLocale(KF())}')
      $reversed = $true
    } elseif ($InitOrig -and ($m2 = [regex]::Match($l, 'function \$?[A-Za-z0-9_]+\(\)\{try\{typeof window!="undefined"&&window\.localStorage\.setItem\("openchamber\.i18n\.v1",JSON\.stringify\(\{locale:"ru"\}\)\)\}catch\{\}try\{.*?\}catch\(e\)\{\}.*\.getState\(\)\.setLocale\("ru"\)\}')).Success) {
      $l = $l.Substring(0, $m2.Index) + $InitOrig + $l.Substring($m2.Index + $m2.Length); $reversed = $true
    }
    if (-not $reversed) { $initLeft = ($l -match 'setLocale\("ru"\)') }
  }
  return @{ text = $l; initLeft = $initLeft }
}

function Stop-AppIfRunning {
  param([switch]$Force)
  if ($env:OC_RU_SKIP_APPCHECK -eq '1') { Write-Warn 'Проверка запущенного приложения пропущена (OC_RU_SKIP_APPCHECK=1).'; return }
  $procs = @(Get-Process -Name 'OpenChamber' -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { Write-Ok 'OpenChamber не запущен.'; return }
  Write-Warn ("OpenChamber запущен (процессов: {0}). Восстанавливать файлы запущенного приложения опасно." -f $procs.Count)
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
Write-Host ' OpenChamber Desktop — удаление RU-патча    ' -ForegroundColor Yellow
Write-Host '============================================' -ForegroundColor DarkGray
Write-Host ''
Write-Log '=== uninstall started ==='

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
$assets = Join-Path $install 'resources\web-dist\assets'
if (-not (Test-Path -LiteralPath $assets)) { throw "Папка assets не найдена: $assets" }

Stop-AppIfRunning -Force:$Force

$appVersion = Get-AppVersion -InstallDir $install
Write-Step "Версия приложения: $appVersion"
$stampPath = Join-Path $assets '.ru-patch.json'
$stamp = $null
if (Test-Path -LiteralPath $stampPath) {
  try { $stamp = Get-Content -LiteralPath $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
if ($stamp -and $stamp.appVersion -and $appVersion -ne 'unknown' -and $stamp.appVersion -ne $appVersion -and -not $Force) {
  throw ("OpenChamber обновился после патча (было $($stamp.appVersion), стало $appVersion). Восстановление старых бэкапов сломает установку. Переустановите OpenChamber начисто или используйте -Force на свой риск.")
}

Write-Step 'Удаляю ru-*.js чанки...'
$ruFiles = Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^ru-[0-9a-f]{8}\.js$' }
foreach ($f in $ruFiles) {
  Remove-Item -LiteralPath $f.FullName -Force
  Write-Ok "  Удалён $($f.Name)"
}
if (-not $ruFiles) { Write-Host '  ru-*.js чанки не найдены.' -ForegroundColor DarkGray }

Write-Step 'Восстанавливаю файлы i18n...'
# Сначала берём имена из штампа (там точные имена файлов), иначе ищем по контенту.
$coreFile = $null; $intlFile = $null
if ($stamp -and $stamp.core) {
  $cand = Join-Path $assets $stamp.core
  if (Test-Path -LiteralPath $cand) { $coreFile = $cand }
}
if (-not $coreFile) {
  $coreFile = Find-ContentFile -Dir $assets -Patterns @('\["en"(?:,"[A-Za-z-]+")+\]', 'tr:"common\.language\.turkish"')
}
if ($stamp -and $stamp.intl) {
  $cand = Join-Path $assets $stamp.intl
  if (Test-Path -LiteralPath $cand) { $intlFile = $cand }
}
if (-not $intlFile) {
  $intlFile = Find-ContentFile -Dir $assets -Patterns @('\{en:"en-US"[^{}]{0,400}?\}') -PreferredFilter 'useAppFontEffects-*.js'
}
if (-not $intlFile) { $intlFile = $coreFile }

# Карта дневных подсказок (2.7.3+) живёт в отдельном useAppFontEffects-*.js.
$tipsFile = $null
if ($stamp -and $stamp.tips) {
  $cand = Join-Path $assets $stamp.tips
  if (Test-Path -LiteralPath $cand) { $tipsFile = $cand }
}
if (-not $tipsFile) {
  $tipsFile = Find-ContentFile -Dir $assets -Patterns @('byLocale:\{en:[A-Za-z_$][A-Za-z0-9_$]*\}', 'de:\(\)=>', 'he:\(\)=>')
}
if ($tipsFile -eq $coreFile -or $tipsFile -eq $intlFile) { $tipsFile = $null }

$initLeft = $false
foreach ($pf in @(@($coreFile) + @($intlFile) + @($tipsFile) | Select-Object -Unique)) {
  if (-not $pf -or -not (Test-Path -LiteralPath $pf)) { continue }
  $leaf = Split-Path -Leaf $pf
  if (Restore-FromBackup -Path $pf) {
    Write-Ok "  Восстановлен $leaf"
  } else {
    Write-Warn "  Бэкапа $leaf нет — пробую хирургический откат..."
    $loaderText = [System.IO.File]::ReadAllText($pf, [System.Text.Encoding]::UTF8)
    $changed = $false
    if ($loaderText -match '==="ru"\?await|,"ru"\]|ru:"common\.language\.russian"|"common\.language\.russian":"Russian"|startsWith\("ru-"\)|setLocale\("ru"\)|ru:"ru-RU"') {
      $rev = Remove-RuFromLoader -Loader $loaderText -InitOrig $stamp.initOrig
      $loaderText = $rev.text
      $changed = $true
      if ($rev.initLeft) { $initLeft = $true }
    }
    $reduced = $loaderText -replace ',ru:\(\)=>Promise\.resolve\(\{copy:[A-Za-z_$][A-Za-z0-9_$]*\}\)', ''
    if ($reduced -ne $loaderText) { $loaderText = $reduced; $changed = $true }
    if ($changed) {
      [System.IO.File]::WriteAllText($pf, $loaderText, (New-Object System.Text.UTF8Encoding $false))
      Write-Ok '  RU-правки вырезаны.'
    } else {
      Write-Host "  В $leaf нет RU-правок." -ForegroundColor DarkGray
    }
  }
}
if (-not $coreFile) { Write-Warn '  Ядро i18n не найдено — проверка маркеров ограничена.' }

Write-Step 'Восстанавливаю чанки локалей из бэкапов...'
# Список локалей держим в паре с установщиком (install-desktop-ru.ps1, шаг 5).
# Если добавить новую локаль там и забыть здесь — uninstall оставит её .bak.
$localeRx = '^(en|fr|zh-CN|zh-TW|uk|es|pt-BR|ko|pl|ja|de|tr|nl|ar|he)-'
$localeFiles = Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match $localeRx
}
$restored = 0
$surgicallyCleaned = 0
foreach ($f in $localeFiles) {
  if (Restore-FromBackup -Path $f.FullName) {
    Write-Ok "  Восстановлен $($f.Name)"
    $restored++
  } else {
    # No backup: remove the key our installer adds (both quote styles).
    $t = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $t2 = $t -replace '"common\.language\.russian":"Russian",', ''
    $t2 = $t2 -replace "'common\.language\.russian':'Russian',", ''
    if ($t2 -ne $t) {
      [System.IO.File]::WriteAllText($f.FullName, $t2, (New-Object System.Text.UTF8Encoding $false))
      Write-Ok "  Хирургически почищен $($f.Name)"
      $surgicallyCleaned++
    }
  }
}
if ($restored -eq 0 -and $surgicallyCleaned -eq 0) { Write-Host '  Бэкапы локалей не найдены.' -ForegroundColor DarkGray }

if (Test-Path -LiteralPath $stampPath) {
  Remove-Item -LiteralPath $stampPath -Force -ErrorAction SilentlyContinue
  Write-Ok 'Штамп патча удалён.'
}

Write-Step 'Проверяю удаление...'
$verifyOk = $true
$leftRu = @(Get-ChildItem -LiteralPath $assets -Filter 'ru-*.js' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^ru-[0-9a-f]{8}\.js$' })
if ($leftRu.Count -gt 0) { Write-Err ("  остались чанки: " + (($leftRu | ForEach-Object { $_.Name }) -join ', ')); $verifyOk = $false }
$leftBak = @(Get-ChildItem -LiteralPath $assets -Filter '*.bak' -ErrorAction SilentlyContinue)
if ($leftBak.Count -gt 0) { Write-Warn ("  остались бэкапы: " + (($leftBak | ForEach-Object { $_.Name }) -join ', ')) }
if ($coreFile -and (Test-Path -LiteralPath $coreFile)) {
  $finalLoader = [System.IO.File]::ReadAllText($coreFile, [System.Text.Encoding]::UTF8)
  $markers = @('==="ru"?await', ',"ru"]', 'ru:"common.language.russian"', '"common.language.russian":"Russian"', 'startsWith("ru-")', 'setLocale("ru")', 'ru:"ru-RU"')
  $hit = @($markers | Where-Object { $finalLoader.Contains($_) })
  if ($hit.Count -gt 0) { Write-Err ("  в ядре остались RU-маркеры: " + ($hit -join ', ')); $verifyOk = $false }
}
if ($intlFile -and $intlFile -ne $coreFile -and (Test-Path -LiteralPath $intlFile)) {
  $finalIntl = [System.IO.File]::ReadAllText($intlFile, [System.Text.Encoding]::UTF8)
  if ($finalIntl.Contains('ru:"ru-RU"')) { Write-Err '  в INTL-лоадере остался маркер ru:"ru-RU"'; $verifyOk = $false }
}
if ($tipsFile -and (Test-Path -LiteralPath $tipsFile)) {
  $finalTips = [System.IO.File]::ReadAllText($tipsFile, [System.Text.Encoding]::UTF8)
  if ($finalTips -match ',ru:\(\)=>Promise\.resolve\(\{copy:') { Write-Err '  в карте подсказок остался RU-фолбэк'; $verifyOk = $false }
}
$localeLeft = @(Get-ChildItem -LiteralPath $assets -Filter '*.js' -ErrorAction SilentlyContinue | Where-Object {
  $_.Name -match $localeRx
} | Where-Object {
  [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) -match 'common\.language\.russian'
})
if ($localeLeft.Count -gt 0) { Write-Warn ("  в локалях остался ключ Russian: " + (($localeLeft | ForEach-Object { $_.Name }) -join ', ') + " (без патча лоадера ни на что не влияет)") }
if ($initLeft) {
  Write-Warn '  Принуждение русского при старте снять не удалось (нет бэкапа).'
  Write-Warn '  Остальное чисто; для 100% стока переустановите OpenChamber.'
} elseif ($verifyOk) {
  Write-Ok 'Удаление проверено, всё чисто.'
} else {
  throw 'Удаление неполное — см. ошибки выше. Переустановка OpenChamber вернёт стоковые файлы.'
}

Write-Host ''
Write-Ok 'Русский перевод удалён.'
Write-Host ("  Лог: " + $script:logFile) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Дальше:' -ForegroundColor White
Write-Host '  1. Полностью выйдите из OpenChamber (трей -> Quit).'
Write-Host '  2. Запустите OpenChamber снова.'
Write-Host ''
