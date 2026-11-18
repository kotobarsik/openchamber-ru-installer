# Bootstrap for: irm https://raw.githubusercontent.com/kotobarsik/openchamber-ru-installer/main/install.ps1 | iex
#
# This file is ASCII without a BOM on purpose. Windows PowerShell 5.1 keeps a
# leading U+FEFF when it downloads a .ps1 as text, so piping the main script
# straight into iex makes PowerShell try to run the BOM as a command and print
# a confusing error. The main script needs its BOM (it contains Cyrillic and is
# also run from disk), so strip it here instead.
$ErrorActionPreference = 'Stop'
iex ((irm https://raw.githubusercontent.com/kotobarsik/openchamber-ru-installer/main/install-desktop-ru.ps1).TrimStart([char]0xFEFF))
