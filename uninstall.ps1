# Bootstrap for: irm https://raw.githubusercontent.com/hays0503/openchamber-ru-installer/main/uninstall.ps1 | iex
#
# ASCII without a BOM on purpose, see install.ps1 for why.
$ErrorActionPreference = 'Stop'
iex ((irm https://raw.githubusercontent.com/hays0503/openchamber-ru-installer/main/uninstall-desktop-ru.ps1).TrimStart([char]0xFEFF))
