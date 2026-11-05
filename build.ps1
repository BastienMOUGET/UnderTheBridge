# build.ps1 - build amalgame-bridge (bridge.exe) on Windows.
#
# Same recipe as gateway / logonoff: amc transpiles, the gcc bundled by
# the Amalgame installer compiles lwIP and links. `amc build` is avoided
# on purpose (it re-invokes amc through an unquoted path, which breaks
# under "C:\Program Files\...").
#
# Usage: double-click build.cmd, or
#   powershell -ExecutionPolicy Bypass -File build.ps1 [-Debug]
# Overrides: $env:AMC (path to amc.exe), $env:GCC_BIN (folder holding gcc.exe).
#
# Npcap is NOT needed to build (wpcap.dll is loaded at run time), only to run.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
param([switch]$Debug)

# "Continue", not "Stop": PowerShell 5.1 turns any stderr line of a native
# program into a terminating error. Failures go through $LASTEXITCODE.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Log($m)  { Write-Host "-> $m" -ForegroundColor Green }
function Die($m)  { Write-Host "x  $m" -ForegroundColor Red; exit 1 }

# Toujours des tableaux [string[]] : PowerShell ramene un tableau a un
# element a une simple chaine, et "chaine + tableau" concatene du texte.
[string[]]$opt = if ($Debug) { @("-O0", "-g") } else { @("-O2") }

function RunGcc([string[]]$argv, [string]$what) {
    & $gcc $argv
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("   commande : `"" + $gcc + "`" " + (($argv | ForEach-Object { "`"$_`"" }) -join " ")) -ForegroundColor Yellow
        Die "echec de gcc : $what"
    }
}

# -- amc + its install prefix --
$amc = $env:AMC
if (-not $amc) {
    $c = Get-Command amc -ErrorAction SilentlyContinue
    if ($c) { $amc = $c.Source }
}
if (-not $amc -or -not (Test-Path $amc)) { Die "amc.exe introuvable (PATH ou `$env:AMC)" }
$prefix = Split-Path (Split-Path $amc -Parent) -Parent
$runtime = Join-Path $prefix "share\amalgame\runtime"
$libamalgame = Join-Path $prefix "share\amalgame\lib\libamalgame.a"
if (-not (Test-Path $runtime))     { Die "runtime amc introuvable : $runtime" }
if (-not (Test-Path $libamalgame)) { Die "libamalgame.a introuvable : $libamalgame" }

# -- gcc: $env:GCC_BIN, then the one bundled with amc, then PATH --
$gccBin = $env:GCC_BIN
if (-not $gccBin) {
    foreach ($cand in @((Join-Path $prefix "gcc\bin"), (Join-Path (Split-Path $amc -Parent) "..\gcc\bin"))) {
        if (Test-Path (Join-Path $cand "gcc.exe")) { $gccBin = (Resolve-Path $cand).Path; break }
    }
}
if (-not $gccBin) {
    $g = Get-Command gcc -ErrorAction SilentlyContinue
    if ($g) { $gccBin = Split-Path $g.Source -Parent }
}
if (-not $gccBin) { Die "gcc introuvable : reinstallez Amalgame avec l'option gcc integre, ou definissez `$env:GCC_BIN" }
$env:PATH = "$gccBin;$(Split-Path $amc -Parent);$env:PATH"
$gcc = Join-Path $gccBin "gcc.exe"
Log "amc : $amc"
Log "gcc : $gcc"

New-Item -ItemType Directory -Force build | Out-Null
$obj = "build\obj-windows"
New-Item -ItemType Directory -Force $obj | Out-Null

# -- lwIP + glue C (incremental) --
$lw = "vendor\lwip\src"
$srcs = @(Get-ChildItem "$lw\core\*.c") + @(Get-ChildItem "$lw\core\ipv4\*.c") +
        @(Get-Item "$lw\netif\ethernet.c") + @(Get-Item "src\native\bridge_lwip.c")
$opts = Get-Item "src\native\lwipopts.h"
[string[]]$objs = @()
Log "lwIP ($($srcs.Count) fichiers)"
foreach ($f in $srcs) {
    $o = Join-Path $obj ($f.BaseName + ".o")
    $stale = -not (Test-Path $o)
    if (-not $stale) {
        $ot = (Get-Item $o).LastWriteTime
        $stale = ($f.LastWriteTime -gt $ot) -or ($opts.LastWriteTime -gt $ot)
    }
    if ($stale) {
        [string[]]$cargs = $opt + @("-Wall", "-Wno-address", "-Isrc\native", "-I$lw\include",
                                    "-c", [string]$f.FullName, "-o", [string]$o)
        RunGcc $cargs $f.Name
    }
    $objs += [string]$o
}

# -- transpile (sys.am first: winsock2.h before windows.h; socks.am before config.am;
#    facade.am before main.am: ServiceEvent fields used there) --
Log "amc"
$am = @("src\sys.am", "src\bytes.am", "src\link.am", "src\net.am", "src\hostsock.am",
        "src\socks.am", "src\config.am", "vendor\amalgame-service\facade.am", "src\main.am")
Remove-Item build\bridge.c -ErrorAction SilentlyContinue
& $amc --quiet -o "build\bridge" @am
if (-not (Test-Path "build\bridge.c")) { Die "amc n'a pas produit build\bridge.c" }

# -- link --
Log "gcc (edition de liens)"
[string[]]$linkArgs = $opt + @("-pthread", "-w", "-Isrc\native", "-I$lw\include", "-I$runtime",
                               "build\bridge.c") + [string[]]$objs + @([string]$libamalgame,
                               "-lgc", "-lm", "-lws2_32", "-liphlpapi", "-ladvapi32", "-o", "build\bridge.exe")
RunGcc $linkArgs "edition de liens"
if (-not (Test-Path "build\bridge.exe")) { Die "build\bridge.exe absent apres gcc" }

# -- dist\ : exe, config example, toolchain DLLs it imports --
Log "Preparation de dist\"
New-Item -ItemType Directory -Force dist | Out-Null
# Un bridge en cours verrouille dist\bridge.exe : on l'arrete d'abord.
# Seulement ceux lances depuis dist\ : le service (Program Files) n'est pas concerne.
$distExe = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "dist\bridge.exe"))
Get-Process -Name bridge -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $distExe) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 400
Copy-Item -Force build\bridge.exe dist\bridge.exe
Copy-Item -Force bridge.conf.example dist\bridge.conf.example
# Ne jamais ecraser une config deja editee dans dist\.
if (-not (Test-Path "dist\bridge.conf")) { Copy-Item bridge.conf.example dist\bridge.conf }
$objdump = Join-Path $gccBin "objdump.exe"
if (Test-Path $objdump) {
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue("dist\bridge.exe")
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue()
        foreach ($line in (& $objdump -p $f 2>$null | Select-String "DLL Name:")) {
            $dll = ($line -replace ".*DLL Name:\s*", "").Trim()
            $src = Join-Path $gccBin $dll
            if ((Test-Path $src) -and -not (Test-Path "dist\$dll")) {
                Copy-Item $src dist\
                $queue.Enqueue("dist\$dll")
            }
        }
    }
}
Write-Host "OK : dist\bridge.exe" -ForegroundColor Green
