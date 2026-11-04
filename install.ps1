# install.ps1 - installe Under The Bridge comme service Windows natif.
# A lancer dans un PowerShell administrateur (ou via install.cmd) :
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              installe / met a jour + demarre
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Interface auto      (ou "Wi-Fi", "Ethernet 2"...)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall   arrete + supprime
#
# Source des fichiers : dist\ (depot de dev, apres build.ps1) ou le dossier du
# script (package distribue). Cible : %ProgramFiles%\UnderTheBridge.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
param(
    [string]$Name = "UnderTheBridge",
    [string]$Interface = "",
    [switch]$Uninstall
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Log($m)  { Write-Host "-> $m" -ForegroundColor Green }
function Die($m)  { Write-Host "x  $m" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "A executer en administrateur."
}

$dest = Join-Path $env:ProgramFiles "UnderTheBridge"
$data = Join-Path $env:ProgramData "UnderTheBridge"
$utf8 = New-Object System.Text.UTF8Encoding($false)

if ($Uninstall) {
    if (Get-Service $Name -ErrorAction SilentlyContinue) {
        Stop-Service $Name -ErrorAction SilentlyContinue
        & sc.exe delete $Name | Out-Null
        Log "Service $Name supprime (fichiers laisses dans $dest et $data)."
    } else {
        Log "Service $Name absent."
    }
    exit 0
}

if (-not (Test-Path "$env:SystemRoot\System32\Npcap\wpcap.dll")) {
    Die "Npcap n'est pas installe. L'installer depuis https://npcap.com (sans le mode WinPcap), puis relancer."
}

# Depot de dev (dist\) ou package (fichiers a cote du script).
if (Test-Path "dist\bridge.exe") { $src = "dist" } else { $src = "." }
if (-not (Test-Path "$src\bridge.exe")) { Die "bridge.exe introuvable (depot : lancer build.cmd d'abord)." }
$template = "$src\bridge.conf"
if (-not (Test-Path $template)) { $template = "$src\bridge.conf.example" }
if (-not (Test-Path $template)) { Die "bridge.conf introuvable dans $src." }

# Migration : ancien service "AmalgameBridge" (meme port 1080) -> supprime,
# sa config est reprise si la nouvelle n'existe pas encore.
$legacy = "AmalgameBridge"
if ($Name -ne $legacy -and (Get-Service $legacy -ErrorAction SilentlyContinue)) {
    Stop-Service $legacy -ErrorAction SilentlyContinue
    & sc.exe delete $legacy | Out-Null
    Log "Ancien service $legacy supprime."
    $oldConf = Join-Path (Join-Path $env:ProgramFiles $legacy) "bridge.conf"
    if ((Test-Path $oldConf) -and -not (Test-Path (Join-Path $dest "bridge.conf"))) {
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item $oldConf (Join-Path $dest "bridge.conf")
        Log "Config reprise depuis $oldConf"
    }
    Start-Sleep -Milliseconds 500
}

# Service deja present : on l'arrete pour pouvoir remplacer l'exe.
$existing = Get-Service $Name -ErrorAction SilentlyContinue
if ($existing) { Stop-Service $Name -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }

New-Item -ItemType Directory -Force $dest, $data | Out-Null
Copy-Item -Force "$src\bridge.exe" $dest
Get-ChildItem $src -Filter *.dll | Copy-Item -Destination $dest -Force
if (Test-Path "$src\chrome-bridge.cmd") { Copy-Item -Force "$src\chrome-bridge.cmd" $dest }
$exe  = Join-Path $dest "bridge.exe"
$conf = Join-Path $dest "bridge.conf"

# Premiere installation : config a partir du modele + choix de l'interface.
$fresh = -not (Test-Path $conf)
if ($fresh) { Copy-Item $template $conf }
$text = [IO.File]::ReadAllText($conf, $utf8)

if ($fresh -or $Interface -ne "") {
    if ($Interface -eq "") {
        Write-Host ""
        Write-Host "Interfaces reseau disponibles :" -ForegroundColor Cyan
        & $exe --list-interfaces
        Write-Host ""
        Write-Host "Entree = auto (recommande) : la carte qui sert a Internet, choisie a chaque demarrage."
        $Interface = (Read-Host "Interface (Entree, ou un nom de la 1re colonne, ex. Wi-Fi ou Ethernet)").Trim()
        if ($Interface -eq "") { $Interface = "auto" }
    }
    $text = $text -replace "(?m)^\s*interface\s*=[^\r\n]*", "interface = $Interface"
    Log "Interface : $Interface"
}

# service_name = nom du service ; journal dans ProgramData par defaut.
$text = $text -replace "AmalgameBridge", $Name
$text = $text -replace "(?m)^\s*service_name\s*=[^\r\n]*", "service_name = $Name"
if ($fresh) {
    $text = $text -replace "(?m)^#\s*log_file\s*=[^\r\n]*", "log_file = $data\bridge.log"
}
[IO.File]::WriteAllText($conf, $text, $utf8)

& $exe --check-config --config $conf
if ($LASTEXITCODE -ne 0) { Die "configuration invalide : corriger $conf puis relancer." }

if (-not $existing) {
    # depend= npcap : le pilote doit etre charge avant l'ouverture de l'interface.
    & sc.exe create $Name binPath= "`"$exe`"" start= auto depend= npcap DisplayName= "Under The Bridge" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "sc.exe create a echoue" }
    & sc.exe description $Name "Proxy local SOCKS5 / HTTP CONNECT (127.0.0.1:1080) ; le trafic sort par une pile TCP/IP dediee sur l'interface configuree." | Out-Null
    & sc.exe failure $Name reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
}
Start-Service $Name
Start-Sleep -Seconds 1
Get-Service $Name
Log "Config  : $conf"
Log "Journal : $data\bridge.log"
Log "Proxy   : socks5://127.0.0.1:1080  ou  http://127.0.0.1:1080"
