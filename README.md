# Установщик русского перевода для OpenChamber Desktop

Простой установщик русского перевода для **десктоп-версии** OpenChamber (Windows, Electron).

## Установка
1. Установите OpenChamber Desktop (скачайте установщик с https://github.com/openchamber/openchamber/releases).
2. Скачайте этот репозиторий (Code → Download ZIP или `git clone`).
3. Запустите `install-desktop-ru.cmd`.
   - Путь к установленному OpenChamber будет найден автоматически (через реестр / `%LOCALAPPDATA%\Programs\@openchamberelectron`).
   - Если автообнаружение не сработало, передайте путь аргументом:
     ```
     install-desktop-ru.cmd "C:\Users\Имя\AppData\Local\Programs\@openchamberelectron"
     ```
4. Полностью закройте OpenChamber (через значок в трее → Quit).
5. Запустите OpenChamber снова, откройте **Settings → Appearance → Language → Russian**.

## Удаление
Запустите `uninstall-desktop-ru.cmd` — оригинальные файлы будут восстановлены из резервных копий (`.bak`), а `ru-*.js` удалён.

## Что делает установщик
- Находит установленное приложение OpenChamber (реестр / стандартные пути).
- Создаёт резервные копии (`.bak`) патчимых файлов в `resources\web-dist\assets\`.
- Генерирует чанк `ru-<hash>.js` из `i18n/messages/ru.ts` и `i18n/messages/ru.settings.ts`.
- Патчит `useAppFontEffects-*.js`:
  - добавляет `'ru'` в массив `LOCALES`,
  - добавляет `ru: 'common.language.russian'` в `LOCALE_LABEL_KEYS`,
  - добавляет ветку `ru` / `ru-*` в `normalizeLocale`,
  - добавляет динамический импорт `import("./ru-<hash>.js")` в цепочку загрузчика словарей.
- Патчит все остальные локали (`en`, `fr`, `zh-CN`, `zh-TW`, `uk`, `es`, `pt-BR`, `ko`, `pl`, `ja`), добавляя ключ `common.language.russian` (на каждом языке отображается как `"Russian"`).

## Что входит
- `install-desktop-ru.cmd` / `install-desktop-ru.ps1` — установщик.
- `uninstall-desktop-ru.cmd` / `uninstall-desktop-ru.ps1` — удаление.
- `i18n/messages/ru.ts` / `i18n/messages/ru.settings.ts` — исходники перевода.

## Совместимость
Тестировалось на OpenChamber Desktop **v1.14.1** (Windows x64, Electron-сборка).

Скрипт не требует прав администратора: приложение ставится в `%LOCALAPPDATA%\Programs\` и пользователь имеет права на запись.

## Ограничения
- Стартовые (bootstrap) сообщения приложения («Connecting:», «Connected!» и т. п.) остаются на английском — они встроены в другой бандл и показываются лишь кратко при запуске.
- После официального обновления OpenChamber (`auto-update`) перевод нужно установить заново — обновление перезаписывает `resources/web-dist/`.
- Если динамические имена функций/чанков изменятся в будущей версии OpenChamber, патчи могут не найтись — в этом случае скрипт выведет предупреждение и оставит бэкапы для ручного отката.

## Примечания
- Файл `app.asar` не трогается — веб-UI лежит в `resources/web-dist/` отдельно.
- Все изменения обратимы через `uninstall-desktop-ru.cmd`.
