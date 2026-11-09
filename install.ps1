# install.ps1 - installe Under The Bridge (service Windows, Npcap, Claude Code,
# raccourci Chrome). A lancer en administrateur, ou via install.cmd :
#
#   powershell -ExecutionPolicy Bypass -File install.ps1                 installe / met a jour
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Interface auto (ou "Wi-Fi", "Ethernet 2"...)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -NoClaude -NoShortcut
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall      supprime service, raccourci, config Claude
#
# Source des fichiers : dist\ (depot de dev, apres build.ps1) ou le dossier du
# script (package distribue). Cible : %ProgramFiles%\UnderTheBridge.
#
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
param(
    [string]$Name = "UnderTheBridge",
    [string]$Interface = "",
    [switch]$NoClaude,
    [switch]$NoShortcut,
    [switch]$Uninstall
)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Log($m)  { Write-Host "-> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "x  $m" -ForegroundColor Red; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die "A executer en administrateur."
}

$dest  = Join-Path $env:ProgramFiles "UnderTheBridge"
$data  = Join-Path $env:ProgramData "UnderTheBridge"
$utf8  = New-Object System.Text.UTF8Encoding($false)
$proxy = "http://127.0.0.1:1080"
$shortcutName = "Chrome (Under The Bridge).lnk"

# ---------------------------------------------------------------------------
# Utilisateur connecte : l'elevation peut se faire avec un autre compte
# administrateur ; Claude Code et le raccourci vont chez l'utilisateur de la
# session, pas chez l'administrateur.
# ---------------------------------------------------------------------------
function Get-SessionUser {
    $r = @{ Profile = $env:USERPROFILE; Desktop = [Environment]::GetFolderPath("Desktop"); LocalAppData = $env:LOCALAPPDATA }
    try {
        Add-Type -AssemblyName System.Management
        $cs = (New-Object System.Management.ManagementObjectSearcher("SELECT UserName FROM Win32_ComputerSystem")).Get()
        $user = $null
        foreach ($o in $cs) { $user = $o["UserName"] }
        if (-not $user) { return $r }
        $sid = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profs = (New-Object System.Management.ManagementObjectSearcher("SELECT LocalPath FROM Win32_UserProfile WHERE SID='$sid'")).Get()
        foreach ($p in $profs) { $r.Profile = $p["LocalPath"] }
        $r.LocalAppData = Join-Path $r.Profile "AppData\Local"
        $r.Desktop = Join-Path $r.Profile "Desktop"
        # Bureau eventuellement redirige (OneDrive...) : registre de l'utilisateur.
        $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
        if ($k) {
            $raw = $k.GetValue("Desktop", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($raw) { $r.Desktop = ($raw -replace "%USERPROFILE%", $r.Profile) }
            $k.Close()
        }
    } catch { }
    return $r
}

function Find-Chrome($localAppData) {
    foreach ($p in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                     "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                     "$localAppData\Google\Chrome\Application\chrome.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Claude Code : %USERPROFILE%\.claude\settings.json, cle "env" (fusion avec
# l'existant). Serialiseur .NET : ne depend pas des cmdlets JSON (absentes
# sur certaines installations de PowerShell 5.1).
function Set-ClaudeProxy($profileDir, [bool]$remove) {
    $dir  = Join-Path $profileDir ".claude"
    $file = Join-Path $dir "settings.json"
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = 16MB
        $root = New-Object "System.Collections.Generic.Dictionary[string,object]"
        if (Test-Path $file) {
            $raw = [IO.File]::ReadAllText($file, $utf8)
            if ($raw.Trim() -ne "") { $root = $js.DeserializeObject($raw) }
            if (-not ($root -is [System.Collections.IDictionary])) { Warn "$file : format inattendu, non modifie."; return }
        } elseif ($remove) { return }
        if (-not $root.ContainsKey("env") -or -not ($root["env"] -is [System.Collections.IDictionary])) {
            if ($remove) { return }
            $root["env"] = New-Object "System.Collections.Generic.Dictionary[string,object]"
        }
        $envMap = $root["env"]
        if ($remove) {
            if ($envMap.ContainsKey("HTTPS_PROXY") -and $envMap["HTTPS_PROXY"] -eq $proxy) {
                [void]$envMap.Remove("HTTPS_PROXY")
                if ($envMap.ContainsKey("NO_PROXY")) { [void]$envMap.Remove("NO_PROXY") }
            } else { return }
        } else {
            $envMap["HTTPS_PROXY"] = $proxy
            $envMap["NO_PROXY"] = "localhost,127.0.0.1"
        }
        New-Item -ItemType Directory -Force $dir | Out-Null
        if (Test-Path $file) { Copy-Item -Force $file "$file.bak" }
        [IO.File]::WriteAllText($file, (Format-Json $js.Serialize($root)), $utf8)
        if ($remove) { Log "Claude Code : proxy retire de $file" }
        else { Log "Claude Code : proxy $proxy dans $file (fermer et rouvrir VS Code / le terminal)" }
    } catch {
        Warn "Claude Code non configure ($($_.Exception.Message)). Ajouter a la main dans $file :"
        Warn "  { `"env`": { `"HTTPS_PROXY`": `"$proxy`", `"NO_PROXY`": `"localhost,127.0.0.1`" } }"
    }
}

# Indentation d'un JSON compact (respecte les chaines).
function Format-Json([string]$s) {
    $sb = New-Object Text.StringBuilder
    $depth = 0; $inStr = $false; $esc = $false
    foreach ($c in $s.ToCharArray()) {
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false } elseif ($c -eq [char]92) { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            { $_ -eq '{' -or $_ -eq '[' } { $depth++; [void]$sb.Append($c).Append("`n").Append("  " * $depth) }
            { $_ -eq '}' -or $_ -eq ']' } { $depth--; [void]$sb.Append("`n").Append("  " * $depth).Append($c) }
            ',' { [void]$sb.Append(",`n").Append("  " * $depth) }
            ':' { [void]$sb.Append(": ") }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString() -replace "\{\s+\}", "{}" -replace "\[\s+\]", "[]"
}

$session = Get-SessionUser

# Cartes reseau, listees par .NET : l'installeur ne lance jamais bridge.exe
# lui-meme, seul le service le fait.
function Show-Interfaces {
    $rows = foreach ($n in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $t = $n.NetworkInterfaceType
        if ($t -ne "Ethernet" -and $t -ne "Wireless80211" -and $t -ne "GigabitEthernet") { continue }
        $gw = ""
        try { $gw = ($n.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq "InterNetwork" } |
                     Select-Object -First 1).Address.ToString() } catch { }
        New-Object PSObject -Property ([ordered]@{ Nom = $n.Name; Etat = $n.OperationalStatus; Type = $t; Passerelle = $gw; Description = $n.Description })
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

# Dernieres lignes du journal du service (diagnostic d'echec).
function Show-LogTail {
    $log = Join-Path $data "bridge.log"
    if (Test-Path $log) {
        Write-Host "Dernieres lignes de $log :" -ForegroundColor Cyan
        Get-Content $log -Tail 15 | ForEach-Object { Write-Host "   $_" }
    }
}

function Die-Blocked($what) {
    Warn "$what."
    Warn "Si le journal ci-dessus ne montre pas d'erreur de configuration, un antivirus"
    Warn "ou une politique de securite bloque peut-etre $exe"
    Warn "(voir le journal de l'antivirus). Faites autoriser ce programme par"
    Warn "l'administrateur du poste, puis relancez install.cmd."
    exit 1
}

# ---------------------------------------------------------------------------
if ($Uninstall) {
    if (Get-Service $Name -ErrorAction SilentlyContinue) {
        Stop-Service $Name -ErrorAction SilentlyContinue
        & sc.exe delete $Name | Out-Null
        Log "Service $Name supprime (fichiers laisses dans $dest et $data)."
    } else {
        Log "Service $Name absent."
    }
    $lnk = Join-Path $session.Desktop $shortcutName
    if (Test-Path $lnk) { Remove-Item -Force $lnk; Log "Raccourci supprime du Bureau." }
    Set-ClaudeProxy $session.Profile $true
    Log "Npcap reste installe (Parametres > Applications pour le supprimer)."
    exit 0
}

# Depot de dev (dist\) ou package (fichiers a cote du script).
if (Test-Path "dist\bridge.exe") { $src = "dist" } else { $src = "." }
if (-not (Test-Path "$src\bridge.exe")) { Die "bridge.exe introuvable (depot : lancer build.cmd d'abord)." }
$template = "$src\bridge.conf"
if (-not (Test-Path $template)) { $template = "$src\bridge.conf.example" }
if (-not (Test-Path $template)) { Die "bridge.conf introuvable dans $src." }

# Fichiers telecharges (zip GitHub) : on retire la marque "provenant
# d'Internet" (Zone.Identifier), source des alertes SmartScreen.
Get-ChildItem -Recurse $src -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Npcap (pilote de capture) : telecharge depuis npcap.com et installe.
# Sa licence gratuite interdit de l'inclure dans le package et reserve
# l'installation silencieuse a l'edition OEM : son assistant s'ouvre donc,
# il suffit de garder les options par defaut.
# ---------------------------------------------------------------------------
function Test-Npcap { return (Test-Path "$env:SystemRoot\System32\Npcap\wpcap.dll") }

function Test-NpcapSignature($file) {
    try {
        $sig = Get-AuthenticodeSignature $file -ErrorAction Stop
        return ($sig.Status -eq "Valid" -and $sig.SignerCertificate.Subject -match "Nmap Software|Insecure\.Com")
    } catch {
        try {
            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
                [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($file))
            $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
            return ($chain.Build($cert) -and $cert.Subject -match "Nmap Software|Insecure\.Com")
        } catch { return $false }
    }
}

if (-not (Test-Npcap)) {
    Log "Npcap n'est pas installe : installation."
    $installer = Get-ChildItem $src -Filter "npcap*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($installer) {
        $installer = $installer.FullName
    } else {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object Net.WebClient
            $wc.Headers.Add("User-Agent", "UnderTheBridge-installer")
            $page = $wc.DownloadString("https://npcap.com/")
            # Version la plus recente citee sur la page.
            $best = $null
            foreach ($m in [regex]::Matches($page, "dist/npcap-([0-9]+\.[0-9]+)\.exe")) {
                if (-not $best -or [version]$m.Groups[1].Value -gt [version]$best) { $best = $m.Groups[1].Value }
            }
            if (-not $best) { throw "lien de telechargement introuvable sur npcap.com" }
            $url = "https://npcap.com/dist/npcap-$best.exe"
            $installer = Join-Path $env:TEMP "npcap-$best.exe"
            Log "Telechargement de $url"
            $wc.DownloadFile($url, $installer)
        } catch {
            Warn "Telechargement impossible ($($_.Exception.Message))."
            $installer = $null
        }
    }
    if ($installer -and -not (Test-NpcapSignature $installer)) {
        Warn "$installer n'est pas signe par l'editeur de Npcap : ignore."
        $installer = $null
    }
    if ($installer) {
        Write-Host ""
        Write-Host "L'assistant Npcap va s'ouvrir : cliquez sur 'I Agree', 'Install', puis 'Finish'" -ForegroundColor Cyan
        Write-Host "(les options proposees par defaut conviennent)." -ForegroundColor Cyan
        Start-Process -FilePath $installer -Wait
    } else {
        Write-Host ""
        Write-Host "Installez Npcap a la main : la page https://npcap.com va s'ouvrir." -ForegroundColor Cyan
        Start-Process "https://npcap.com/#download"
        Read-Host "Appuyez sur Entree une fois Npcap installe"
    }
    if (-not (Test-Npcap)) { Die "Npcap n'est toujours pas installe : relancer install.cmd apres l'avoir installe." }
    Log "Npcap installe."
}

# ---------------------------------------------------------------------------
# Migration : ancien service "AmalgameBridge" (meme port 1080) -> supprime,
# sa config est reprise si la nouvelle n'existe pas encore.
# ---------------------------------------------------------------------------
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
Get-ChildItem $dest -File | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
}
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
        Show-Interfaces
        Write-Host ""
        Write-Host "Entree = auto (recommande) : la carte qui sert a Internet, suivie automatiquement."
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

# La configuration est verifiee par le service a son demarrage (une erreur
# l'arrete et s'inscrit dans le journal, affiche ci-dessous le cas echeant).

if (-not $existing) {
    # depend= npcap : le pilote doit etre charge avant l'ouverture de l'interface.
    & sc.exe create $Name binPath= "`"$exe`"" start= auto depend= npcap DisplayName= "Under The Bridge" | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "sc.exe create a echoue" }
    & sc.exe description $Name "Proxy local SOCKS5 / HTTP CONNECT (127.0.0.1:1080) ; le trafic sort par une pile TCP/IP dediee sur l'interface configuree." | Out-Null
}
# Demarrage differe (~2 min apres le boot, reseau en general pret) et
# relance en cas d'echec. Applique aussi aux installations existantes.
& sc.exe config $Name start= delayed-auto | Out-Null
& sc.exe failure $Name reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
& sc.exe failureflag $Name 1 | Out-Null
try { Start-Service $Name -ErrorAction Stop }
catch { Warn "Demarrage du service : $($_.Exception.Message)" }
Start-Sleep -Seconds 3
$svc = Get-Service $Name
$svc | Format-Table -AutoSize Status, Name, DisplayName
if ($svc.Status -ne "Running") {
    Show-LogTail
    Die-Blocked "Le service $Name n'a pas demarre (etat : $($svc.Status)) : configuration invalide, ou programme bloque"
}

# ---------------------------------------------------------------------------
# Raccourci Chrome sur le Bureau de l'utilisateur
# ---------------------------------------------------------------------------
if (-not $NoShortcut) {
    $chrome = Find-Chrome $session.LocalAppData
    if ($chrome) {
        try {
            $profileDir = Join-Path $session.LocalAppData "ChromeBridge"
            $lnkPath = Join-Path $session.Desktop $shortcutName
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($lnkPath)
            $lnk.TargetPath = $chrome
            $lnk.Arguments = "--proxy-server=`"socks5://127.0.0.1:1080`" " +
                "--host-resolver-rules=`"MAP * ~NOTFOUND , EXCLUDE 127.0.0.1 , EXCLUDE localhost , EXCLUDE [::1]`" " +
                "--user-data-dir=`"$profileDir`""
            $lnk.IconLocation = "$chrome,0"
            $lnk.Description = "Chrome a travers Under The Bridge (profil separe)"
            $lnk.WorkingDirectory = Split-Path $chrome
            $lnk.Save()
            Log "Raccourci cree : $lnkPath"
        } catch {
            Warn "Raccourci Chrome non cree : $($_.Exception.Message)"
        }
    } else {
        Warn "Chrome introuvable : pas de raccourci (chrome-bridge.cmd reste disponible dans $dest)."
    }
}

# ---------------------------------------------------------------------------
# Claude Code (terminal et VS Code) : proxy HTTP
# ---------------------------------------------------------------------------
if (-not $NoClaude) {
    $ans = (Read-Host "Configurer Claude Code pour passer par le proxy ? (O/n)").Trim().ToLower()
    if ($ans -eq "" -or $ans -eq "o" -or $ans -eq "y") { Set-ClaudeProxy $session.Profile $false }
}

Write-Host ""
Log "Config  : $conf"
Log "Journal : $data\bridge.log"
Log "Proxy   : socks5://127.0.0.1:1080  ou  $proxy"
