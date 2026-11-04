# package.ps1 - construit le zip distribuable de Under The Bridge.
#
#   powershell -ExecutionPolicy Bypass -File package.ps1            build + zip
#   powershell -ExecutionPolicy Bypass -File package.ps1 -NoBuild   zip de dist\ tel quel
#
# Produit package\UnderTheBridge-<version>.zip (+ .sha256). Le bridge.conf
# personnel de dist\ n'est PAS inclus : seul le modele l'est.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
param(
    [string]$Version = (Get-Date -Format "yyyy.MM.dd"),
    [switch]$NoBuild
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Log($m)  { Write-Host "-> $m" -ForegroundColor Green }
function Die($m)  { Write-Host "x  $m" -ForegroundColor Red; exit 1 }

if (-not $NoBuild) {
    Log "Compilation (build.ps1)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build.ps1")
    if ($LASTEXITCODE -ne 0) { Die "build.ps1 a echoue" }
}
if (-not (Test-Path "dist\bridge.exe")) { Die "dist\bridge.exe absent : lancer build.cmd." }

$name  = "UnderTheBridge-$Version"
$stage = Join-Path "package" $name
$zip   = Join-Path "package" "$name.zip"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
if (Test-Path $zip)   { Remove-Item -Force $zip }
New-Item -ItemType Directory -Force $stage, (Join-Path $stage "licenses") | Out-Null

Log "Assemblage de $stage"
Copy-Item dist\bridge.exe $stage
Get-ChildItem dist -Filter *.dll | Copy-Item -Destination $stage
Copy-Item bridge.conf.example $stage
Copy-Item install.ps1, chrome-bridge.cmd $stage
Copy-Item packaging\install.cmd, packaging\uninstall.cmd, packaging\LISEZMOI.txt $stage
Copy-Item licenses\* (Join-Path $stage "licenses")
Copy-Item LICENSE (Join-Path $stage "licenses\UnderTheBridge-LICENSE.txt")
Copy-Item NOTICE (Join-Path $stage "licenses\UnderTheBridge-NOTICE.txt")
Set-Content -Encoding ASCII (Join-Path $stage "VERSION.txt") "Under The Bridge $Version"

# Controle rapide : l'exe demarre et l'auto-test de config passe.
& (Join-Path $stage "bridge.exe") --help | Out-Null
if ($LASTEXITCODE -ne 0) { Die "bridge.exe ne demarre pas depuis le package (DLL manquante ?)" }

Log "Compression"
Compress-Archive -Path $stage -DestinationPath $zip
# .NET direct : Get-FileHash manque sur certaines installations de PowerShell 5.1.
$sha = [Security.Cryptography.SHA256]::Create()
$fs  = [IO.File]::OpenRead((Resolve-Path $zip).Path)
try { $hash = ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace "-", "").ToLower() }
finally { $fs.Close(); $sha.Dispose() }
Set-Content -Encoding ASCII "$zip.sha256" "$hash  $name.zip"

Get-ChildItem $stage | Select-Object Name, Length | Format-Table -AutoSize
Log "OK : $zip"
Log "SHA256 : $hash"
