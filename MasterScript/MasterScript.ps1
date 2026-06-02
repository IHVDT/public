<#
===============================================================================
 UNO - MASTER TOOLKIT
 Auteur:  Nick Hoogkamer (Operations)
 Versie:  1.2.0
 Doel:    Centraal menu voor laptop-oplevering en -beheer.

 Bronnen / credits:
   - Master_Enroll        : Brandon van Dijk
   - DriverUpdate         : (third-party Windows Update driver search)
   - BitlockerCheck       : Nick Hoogkamer
   - Auto-update          : GitHub (IHVDT/public)
 Samengevoegd tot Ã©Ã©n menugestuurd masterscript.

 LET OP: Dit script schrijft NIETS naar de klant-laptop.
         Alle logs en tijdelijke bestanden blijven op de USB-stick.
===============================================================================

 Opties:
   1) Enrollment (Autopilot / Intune)
   2) Driver updates
   3) Laptopgegevens ophalen en tonen
   4) BitlockerCheck (self-healing)
   5) Enrollment-/Intune-status (dsregcmd)
   9) Rollback (vorige versie terugzetten)
   0) Afsluiten
===============================================================================
#>

# --- Parameters --------------------------------------------------------------
param(
    [switch]$SkipUpdate
)

# --- Vereisten ---------------------------------------------------------------
#Requires -Version 5.1

# --- Versie & Update configuratie --------------------------------------------
$ScriptVersion  = "1.2.0"
$GitHubUser     = "IHVDT"
$GitHubRepo     = "public"
$GitHubBranch   = "main"
$ScriptFolder   = "MasterScript"
$BaseURL        = "https://raw.githubusercontent.com/$GitHubUser/$GitHubRepo/$GitHubBranch/$ScriptFolder"

# --- Paden (alles op de USB, NIETS op de klant-laptop) -----------------------
$ScriptRoot     = Split-Path -Parent $PSCommandPath
$LogDir         = Join-Path $ScriptRoot "Logs"
$TempDir        = Join-Path $ScriptRoot "Temp"
if (-not (Test-Path $LogDir))  { New-Item -Path $LogDir  -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory -Force | Out-Null }

# Zorg dat we als Administrator draaien; zo niet, herstart verhoogd.
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Dit script vereist beheerdersrechten. Herstarten als Administrator..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs
    } catch {
        Write-Host "Kon niet verhogen naar Administrator. Start PowerShell handmatig als Administrator." -ForegroundColor Red
    }
    return
}

$Host.UI.RawUI.WindowTitle = "UNO - Master Toolkit v$ScriptVersion"

# --- Helper functies (uniforme, rustige output) ------------------------------
function Write-Section($t){ Write-Host "`n==== $t ====" -ForegroundColor Cyan }
function Write-Info($t)   { Write-Host "[INFO]  $t" -ForegroundColor White }
function Write-Warn($t)   { Write-Host "[LET OP] $t" -ForegroundColor Yellow }
function Write-OK($t)     { Write-Host "[OK]    $t" -ForegroundColor Green }
function Write-Err($t)    { Write-Host "[FOUT]  $t" -ForegroundColor Red }

function Pause-Menu {
    Write-Host ""
    Write-Host "Druk op een toets om terug te keren naar het menu..." -ForegroundColor DarkGray
    [void][System.Console]::ReadKey($true)
}

# =============================================================================
# AUTO-UPDATE FUNCTIE
# =============================================================================
function Invoke-AutoUpdate {
    <#
    .SYNOPSIS
        Controleert GitHub op een nieuwere versie en werkt het script bij.
        Draait stil op de achtergrond - bij geen internet gewoon door.
    #>

    # --- Stap 1: Online versie ophalen ---------------------------------------
    $versionURL = "$BaseURL/version.txt"
    try {
        $response = Invoke-WebRequest -Uri $versionURL -UseBasicParsing `
                        -TimeoutSec 5 -ErrorAction Stop
        $remoteVersion = $response.Content.Trim()
    }
    catch {
        # Geen internet of GitHub niet bereikbaar - stil doorgaan
        return @{ Updated = $false; Message = $null }
    }

    # --- Stap 2: Versies vergelijken -----------------------------------------
    try {
        $local  = [version]$ScriptVersion
        $remote = [version]$remoteVersion
    }
    catch {
        return @{ Updated = $false; Message = $null }
    }

    if ($remote -le $local) {
        # Alles up-to-date
        return @{ Updated = $false; Message = $null }
    }

    # --- Stap 3: Nieuwe versie beschikbaar! ----------------------------------
    Write-Host ""
    Write-Host "   Nieuwe versie beschikbaar: v$ScriptVersion -> v$remoteVersion" `
        -ForegroundColor Yellow
    Write-Host "   Bijwerken..." -ForegroundColor DarkGray

    $scriptURL  = "$BaseURL/MasterScript.ps1"
    $scriptPath = $PSCommandPath   # Pad van het huidige draaiende script
    $backupPath = "$scriptPath.bak"

    try {
        # Download nieuw script naar tijdelijk bestand
        $tempFile = "$scriptPath.tmp"
        Invoke-WebRequest -Uri $scriptURL -OutFile $tempFile `
            -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop

        # Controleer of download geldig is (niet leeg / niet een foutpagina)
        $content = Get-Content $tempFile -Raw -ErrorAction Stop
        if ($content.Length -lt 500 -or $content -notmatch 'UNO') {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            return @{ Updated = $false; Message = "Download lijkt ongeldig, update overgeslagen." }
        }

        # Backup maken van huidige versie
        if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
        Copy-Item -Path $scriptPath -Destination $backupPath -Force

        # Overschrijf met nieuwe versie
        Move-Item -Path $tempFile -Destination $scriptPath -Force

        # --- Stap 4: Changelog ophalen (optioneel) ---------------------------
        $changelogMsg = $null
        try {
            $clURL = "$BaseURL/changelog.txt"
            $cl = (Invoke-WebRequest -Uri $clURL -UseBasicParsing `
                       -TimeoutSec 5 -ErrorAction Stop).Content
            # Pak alleen de regels van de nieuwe versie
            $section = ($cl -split "(?m)^##\s") |
                       Where-Object { $_ -match "^$remoteVersion" } |
                       Select-Object -First 1
            if ($section) { $changelogMsg = $section.Trim() }
        }
        catch { }

        return @{
            Updated      = $true
            NewVersion   = $remoteVersion
            Changelog    = $changelogMsg
            BackupPath   = $backupPath
        }
    }
    catch {
        # Download mislukt - opruimen en doorgaan met huidige versie
        Remove-Item "$scriptPath.tmp" -Force -ErrorAction SilentlyContinue
        return @{ Updated = $false; Message = "Update mislukt: $($_.Exception.Message)" }
    }
}

# =============================================================================
# ROLLBACK FUNCTIE
# =============================================================================
function Invoke-Rollback {
    Show-Header
    Write-Section "Rollback naar vorige versie"

    $backupPath = "$PSCommandPath.bak"
    if (Test-Path $backupPath) {
        Write-Info "Backup gevonden: $backupPath"
        $confirm = Read-Host "Weet je zeker dat je wilt terugdraaien? (J/n)"
        if ($confirm -match '^[Nn]') {
            Write-Info "Rollback geannuleerd."
        }
        else {
            Copy-Item -Path $backupPath -Destination $PSCommandPath -Force
            Write-OK "Teruggedraaid naar vorige versie."
            Write-Warn "Script wordt herstart..."
            Start-Sleep -Seconds 2
            & $PSCommandPath -SkipUpdate
            exit
        }
    }
    else {
        Write-Err "Geen backup gevonden om naar terug te draaien."
    }
    Pause-Menu
}

# --- Header / banner ---------------------------------------------------------
function Show-Header {
    Clear-Host
    $line = "================================================================"
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "   _   _ _   _  ___      __  __         _           " -ForegroundColor Cyan
    Write-Host "  | | | | \ | |/ _ \    |  \/  |__ _ __| |_ ___ _ _ " -ForegroundColor Cyan
    Write-Host "  | |_| |  \| | (_) |   | |\/| / _`` (_-<  _/ -_) '_|" -ForegroundColor Cyan
    Write-Host "   \___/|_|\__|\___/    |_|  |_\__,_/__/\__\___|_|  " -ForegroundColor Cyan
    Write-Host ""
    Write-Host "                  M A S T E R   T O O L K I T" -ForegroundColor White
    Write-Host $line -ForegroundColor DarkCyan
    $cn = $env:COMPUTERNAME
    $usr = $env:USERNAME
    $now = Get-Date -Format "dddd dd-MM-yyyy HH:mm"
    Write-Host ("  Toestel: {0,-20} Gebruiker: {1}" -f $cn, $usr) -ForegroundColor DarkGray
    Write-Host ("  Datum:   {0}" -f $now) -ForegroundColor DarkGray
    Write-Host ("  Versie:  v{0}" -f $ScriptVersion) -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkCyan
}

# --- Menu --------------------------------------------------------------------
function Show-Menu {
    Show-Header
    Write-Host ""
    Write-Host "   Kies een optie:" -ForegroundColor White
    Write-Host ""
    Write-Host "     [1] " -ForegroundColor Green   -NoNewline; Write-Host "Enrollment        " -NoNewline -ForegroundColor White; Write-Host "(Autopilot / Intune)" -ForegroundColor DarkGray
    Write-Host "     [2] " -ForegroundColor Green   -NoNewline; Write-Host "Driver updates    " -NoNewline -ForegroundColor White; Write-Host "(zoek & installeer drivers)" -ForegroundColor DarkGray
    Write-Host "     [3] " -ForegroundColor Green   -NoNewline; Write-Host "Laptopgegevens    " -NoNewline -ForegroundColor White; Write-Host "(hardware & systeem)" -ForegroundColor DarkGray
    Write-Host "     [4] " -ForegroundColor Green   -NoNewline; Write-Host "BitlockerCheck    " -NoNewline -ForegroundColor White; Write-Host "(controle & self-healing)" -ForegroundColor DarkGray
    Write-Host "     [5] " -ForegroundColor Green   -NoNewline; Write-Host "Enrollment-status " -NoNewline -ForegroundColor White; Write-Host "(Azure AD / Intune)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "     [9] " -ForegroundColor DarkYellow -NoNewline; Write-Host "Rollback          " -NoNewline -ForegroundColor White; Write-Host "(vorige versie terugzetten)" -ForegroundColor DarkGray
    Write-Host "     [0] " -ForegroundColor Red     -NoNewline; Write-Host "Afsluiten" -ForegroundColor White
    Write-Host ""
    Write-Host "   ----------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "   Tip: voer eerst optie 5 uit om de status te checken." -ForegroundColor DarkGray
    Write-Host ""
}

# =============================================================================
# OPTIE 1 - ENROLLMENT (Autopilot / Intune)   [bron: Brandon van Dijk]
# =============================================================================
function Invoke-Enrollment {
    Show-Header
    Write-Section "Enrollment - Autopilot / Intune"
    Write-Warn "Hiervoor is een actieve internetverbinding vereist."
    Write-Host ""
    $go = Read-Host "Doorgaan met enrollment? (J/n)"
    if ($go -match '^[Nn]') { Write-Info "Geannuleerd."; Pause-Menu; return }

    try {
        # Forceer dat (non-terminating) fouten alsnog in de catch belanden.
        $ErrorActionPreference = 'Stop'

        # 0) Internet vooraf controleren - zonder verbinding heeft enrollment geen zin.
        Write-Info "Internetverbinding controleren..."
        if (-not (Test-Connection -ComputerName login.microsoftonline.com -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
            Write-Err "Geen verbinding met Microsoft (login.microsoftonline.com). Enrollment afgebroken."
            Pause-Menu; return
        }
        Write-OK "Internetverbinding in orde."

        # 1) Benodigde module installeren.
        Write-Info "PSWindowsUpdate module installeren..."
        Install-Module -Name PSWindowsUpdate -Force -ErrorAction Stop
        Write-OK "Module gereed."

        # 2) Driver-updates op de achtergrond starten.
        Write-Info "Beschikbare driver-updates installeren (op de achtergrond)..."
        Invoke-Expression 'cmd /c start powershell -Command Install-WindowsUpdate -Install -AcceptAll -UpdateType Driver -MicrosoftUpdate -ForceDownload -ForceInstall -IgnoreReboot'
        Write-OK "Windows Update gestart."

        # 3) Autopilot-gegevens uploaden naar Intune.
        Write-Info "Autopilot-gegevens uploaden naar Microsoft Intune..."
        Write-Warn "Er verschijnt een Microsoft-aanmeldvenster. Log in met een account dat toestellen mag inschrijven."

        # Temp-map op de USB-stick, NIET op de klant-laptop
        if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory | Out-Null }
        Save-Script -Name Get-WindowsAutoPilotInfo -Path $TempDir -Force -ErrorAction Stop

        $apScript = Join-Path $TempDir "Get-WindowsAutoPilotInfo.ps1"
        if (-not (Test-Path $apScript)) {
            Write-Err "Autopilot-script kon niet worden gedownload. Enrollment afgebroken."
            Pause-Menu; return
        }

        # Aparte try rond de upload: een gesloten/afgebroken login geeft een fout
        # die we hier expliciet opvangen, in plaats van stilletjes door te lopen.
        $apOk = $false
        try {
            # Bewust ZONDER -Reboot, zodat we eerst het resultaat kunnen tonen
            # en het menu niet verliezen bij een geslaagde upload.
            & $apScript -Online -Assign
            if ($?) { $apOk = $true }
        }
        catch {
            Write-Err "Aanmelden of uploaden is niet voltooid: $($_.Exception.Message)"
            Write-Warn "Waarschijnlijk is het aanmeldvenster gesloten zonder in te loggen."
        }

        if ($apOk) {
            Write-OK "Autopilot-upload voltooid - toestel is aangemeld bij Intune."
            Write-Host ""
            $rb = Read-Host "Nu herstarten om de enrollment af te ronden? (J/n)"
            if ($rb -match '^[Nn]') {
                Write-Warn "Niet herstart. Herstart het toestel later handmatig om de enrollment af te ronden."
            } else {
                Write-Info "Herstarten over 3 seconden..."
                Start-Sleep -Seconds 3
                Restart-Computer -Force
            }
        } else {
            Write-Err "Enrollment is NIET voltooid. Kies optie 1 opnieuw en log dit keer wel in."
        }
    }
    catch {
        Write-Err "Er ging iets mis tijdens enrollment: $($_.Exception.Message)"
    }
    finally {
        # Opruimen op de USB-stick
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Pause-Menu
}

# =============================================================================
# OPTIE 2 - DRIVER UPDATES   [bron: DriverUpdate.ps1]
# =============================================================================
function Invoke-DriverUpdates {
    Show-Header
    Write-Section "Driver updates"
    try {
        $UpdateSvc = New-Object -ComObject Microsoft.Update.ServiceManager
        $UpdateSvc.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"") | Out-Null

        $Session  = New-Object -ComObject Microsoft.Update.Session
        $Searcher = $Session.CreateUpdateSearcher()
        $Searcher.ServiceID       = '7971f918-a847-4430-9279-4a52d1efe18d'
        $Searcher.SearchScope     = 1   # MachineOnly
        $Searcher.ServerSelection = 3   # Third Party

        Write-Info "Zoeken naar driver-updates..."
        $SearchResult = $Searcher.Search("IsInstalled=0 and Type='Driver'")
        $Updates = $SearchResult.Updates

        if ($Updates.Count -eq 0) {
            Write-OK "Geen nieuwe driver-updates gevonden. Systeem is up-to-date."
            Pause-Menu; return
        }

        Write-Info ("{0} driver-update(s) gevonden:" -f $Updates.Count)
        $Updates | Select-Object Title, DriverVerDate, DriverManufacturer | Format-Table -AutoSize | Out-Host

        $UpdatesToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        $Updates | ForEach-Object { $UpdatesToDownload.Add($_) | Out-Null }

        Write-Info "Drivers downloaden..."
        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $UpdatesToDownload
        $Downloader.Download() | Out-Null

        $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        $Updates | ForEach-Object { if ($_.IsDownloaded) { $UpdatesToInstall.Add($_) | Out-Null } }

        Write-Info "Drivers installeren..."
        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $UpdatesToInstall
        $Result = $Installer.Install()

        Write-OK "Installatie voltooid."
        if ($Result.RebootRequired) {
            Write-Warn "Een herstart is vereist om de installatie af te ronden."
        }

        # Third-party service weer opruimen
        $UpdateSvc.Services |
            Where-Object { $_.IsDefaultAUService -eq $false -and $_.ServiceID -eq "7971f918-a847-4430-9279-4a52d1efe18d" } |
            ForEach-Object { $UpdateSvc.RemoveService($_.ServiceID) }
    }
    catch {
        Write-Err "Driver update mislukt: $($_.Exception.Message)"
    }
    Pause-Menu
}

# =============================================================================
# OPTIE 3 - LAPTOPGEGEVENS
# =============================================================================
function Show-SystemInfo {
    Show-Header
    Write-Section "Laptopgegevens"

    try {
        $cs   = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os   = Get-CimInstance Win32_OperatingSystem
        $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $bat  = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1

        $ramGB  = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $diskTot= [math]::Round($disk.Size / 1GB, 1)
        $diskFree=[math]::Round($disk.FreeSpace / 1GB, 1)
        $upTime = (Get-Date) - $os.LastBootUpTime

        # TPM
        $tpm = $null
        try { $tpm = Get-Tpm -ErrorAction Stop } catch {}

        function Row($label, $value) {
            Write-Host ("  {0,-22}" -f $label) -ForegroundColor White -NoNewline
            Write-Host (": {0}" -f $value) -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "  --- Systeem ---------------------------------------" -ForegroundColor DarkCyan
        Row "Computernaam"    $env:COMPUTERNAME
        Row "Fabrikant"       $cs.Manufacturer
        Row "Model"           $cs.Model
        Row "Serienummer"     $bios.SerialNumber
        Row "BIOS-versie"     $bios.SMBIOSBIOSVersion

        Write-Host "  --- Hardware --------------------------------------" -ForegroundColor DarkCyan
        Row "Processor"       ($cpu.Name.Trim())
        Row "Cores / Threads" ("{0} / {1}" -f $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
        Row "Werkgeheugen"    ("{0} GB" -f $ramGB)
        Row "Schijf C: totaal"("{0} GB" -f $diskTot)
        Row "Schijf C: vrij"  ("{0} GB" -f $diskFree)
        if ($bat) { Row "Accu (resterend)" ("{0}%" -f $bat.EstimatedChargeRemaining) }

        Write-Host "  --- Software / OS ---------------------------------" -ForegroundColor DarkCyan
        Row "Besturingssysteem" $os.Caption
        Row "Versie / Build"  ("{0} ({1})" -f $os.Version, $os.BuildNumber)
        Row "Geinstalleerd op" $os.InstallDate
        Row "Laatst opgestart" $os.LastBootUpTime
        Row "Uptime"          ("{0}d {1}u {2}m" -f $upTime.Days, $upTime.Hours, $upTime.Minutes)

        Write-Host "  --- Security --------------------------------------" -ForegroundColor DarkCyan
        if ($tpm) {
            Row "TPM aanwezig"  $tpm.TpmPresent
            Row "TPM gereed"    $tpm.TpmReady
        } else {
            Row "TPM"           "Niet gevonden / niet leesbaar"
        }
        try {
            $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
            Row "BitLocker C:"  ("{0} ({1}%)" -f $bl.ProtectionStatus, $bl.EncryptionPercentage)
        } catch { Row "BitLocker C:" "Status onbekend" }

        Write-Host "  --- Netwerk ---------------------------------------" -ForegroundColor DarkCyan
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
              Select-Object -First 1
        if ($ip) { Row "IPv4-adres" $ip.IPAddress }
        $online = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue
        Row "Internet"       ($(if ($online) { "Verbonden" } else { "Geen verbinding" }))

        # Exporteren naar USB-stick
        Write-Host ""
        $exp = Read-Host "Gegevens exporteren naar USB-stick? (J/n)"
        if ($exp -notmatch '^[Nn]') {
            $outFile = Join-Path $LogDir ("SystemInfo_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format "yyyyMMdd_HHmm"))
            $report = @"
UNO - Laptopgegevens
Gegenereerd: $(Get-Date -Format "yyyy-MM-dd HH:mm")

Computernaam   : $env:COMPUTERNAME
Fabrikant      : $($cs.Manufacturer)
Model          : $($cs.Model)
Serienummer    : $($bios.SerialNumber)
BIOS-versie    : $($bios.SMBIOSBIOSVersion)
Processor      : $($cpu.Name.Trim())
Werkgeheugen   : $ramGB GB
Schijf C:      : $diskFree GB vrij van $diskTot GB
OS             : $($os.Caption) $($os.Version) (build $($os.BuildNumber))
Laatst gestart : $($os.LastBootUpTime)
"@
            $report | Out-File -FilePath $outFile -Encoding UTF8
            Write-OK "Opgeslagen op USB: $outFile"
        }
    }
    catch {
        Write-Err "Kon laptopgegevens niet volledig ophalen: $($_.Exception.Message)"
    }
    Pause-Menu
}

# =============================================================================
# OPTIE 4 - BITLOCKERCHECK   [bron: Nick Hoogkamer]
# =============================================================================
function Invoke-BitlockerCheck {
    Show-Header
    $DriveLetter = "C:"

    # Logbestand op de USB-stick
    $LogFile = Join-Path $LogDir "BitLocker-AutoFix.log"

    function Log($t){ ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $t) | Out-File -FilePath $LogFile -Append }

    function Get-Status {
        try {
            $v = Get-BitLockerVolume -MountPoint $DriveLetter -ErrorAction Stop
            return [pscustomobject]@{
                Source     = 'Cmdlet'
                Percent    = [int]$v.EncryptionPercentage
                Protection = $v.ProtectionStatus.ToString()
                Conversion = $v.VolumeStatus.ToString()
                HasTPM     = ($v.KeyProtector | Where-Object { $_.KeyProtectorType -match 'Tpm' }) -ne $null
            }
        }
        catch {
            $raw = manage-bde -status $DriveLetter
            $pct = 0
            $m = ($raw | Select-String -Pattern "Percentage\s+Encrypted\s*:\s*([0-9]+([.,][0-9]+)?)%")
            if ($m) { $pct = [int][math]::Round([double]($m.Matches[0].Groups[1].Value.Replace(',', '.')),0) }
            $prot = 'Unknown'; $m = ($raw | Select-String -Pattern "Protection\s+Status\s*:\s*(.+)")
            if ($m) { $prot = $m.Matches[0].Groups[1].Value.Trim() }
            $conv = 'Unknown'; $m = ($raw | Select-String -Pattern "Conversion\s+Status\s*:\s*(.+)")
            if ($m) { $conv = $m.Matches[0].Groups[1].Value.Trim() }
            $hasTpm = (($raw | Select-String -Pattern "Key Protectors:") -ne $null) -and (($raw | Select-String -Pattern "TPM") -ne $null)
            return [pscustomobject]@{ Source='manage-bde'; Percent=$pct; Protection=$prot; Conversion=$conv; HasTPM=$hasTpm }
        }
    }
    function Is-FullyEncrypted($status) { return ($status.Percent -ge 100) -or ($status.Conversion -match 'Encrypted') }

    Write-Section "Controleer BitLocker status voor $DriveLetter"
    Log "Start controle $DriveLetter"
    $st = Get-Status
    Write-Info ("Encryptiepercentage: {0}%" -f $st.Percent)
    Write-Info ("Protectie-status: {0}"   -f $st.Protection)
    Write-Info ("Conversie-status: {0}"   -f $st.Conversion)
    Log "Status: pct=$($st.Percent) prot=$($st.Protection) conv='$($st.Conversion)' src=$($st.Source)"

    Write-Section "Controleer encryptiestatus"
    if (Is-FullyEncrypted $st) {
        Write-OK "BitLocker is volledig versleuteld."
    } else {
        Write-Warn "BitLocker is nog niet volledig versleuteld (nu $($st.Percent)%)."
        if ($st.Percent -ge 90 -and $st.Percent -lt 100) {
            Write-Warn "Lijkt vast te zitten rond $($st.Percent)% -> pauzeer en hervat."
            Log "Pause/resume vanwege $($st.Percent)%"
            manage-bde -pause  $DriveLetter | Out-Null
            Start-Sleep -Seconds 5
            manage-bde -resume $DriveLetter | Out-Null
            Write-OK "Encryptie hervat."
        }
        elseif ($st.Percent -eq 0 -and ($st.Conversion -notmatch 'Encrypted')) {
            Write-Warn "Encryptie lijkt niet actief. Start encryptie (UsedSpaceOnly)."
            Log "Start manage-bde -on UsedSpaceOnly"
            manage-bde -on $DriveLetter -UsedSpaceOnly | Out-Null
            Write-OK "Encryptieproces gestart."
        }
        else { Write-Info "Encryptie is bezig: $($st.Percent)% voltooid." }
    }

    Write-Section "Controleer TPM protector"
    if (-not $st.HasTPM) {
        Write-Warn "Geen TPM protector gevonden - toevoegen..."
        manage-bde -protectors -add $DriveLetter -tpm | Out-Null
        Write-OK "TPM protector toegevoegd."; Log "TPM protector toegevoegd"
    } else { Write-OK "TPM protector aanwezig." }

    Write-Section "Controleer protectie status"
    if ($st.Protection -match 'Off') {
        Write-Warn "Protectie is uitgeschakeld. Inschakelen..."
        manage-bde -protectors -enable $DriveLetter | Out-Null
        Write-OK "Protectie ingeschakeld."; Log "Protectie ingeschakeld"
    } else { Write-OK "Protectie actief." }

    Write-Section "Samenvatting"
    $end = Get-Status
    Write-Host ""
    Write-Host "================== BITLOCKER SAMENVATTING ==================" -ForegroundColor Cyan
    Write-Host ("  Schijf:              {0}"  -f $DriveLetter)   -ForegroundColor White
    Write-Host ("  Encryptiepercentage: {0}%" -f $end.Percent)  -ForegroundColor Yellow
    Write-Host ("  Protectie-status:    {0}"  -f $end.Protection)-ForegroundColor Yellow
    Write-Host ("  Conversie-status:    {0}"  -f $end.Conversion)-ForegroundColor Yellow
    Write-Host ("  TPM protector:       {0}"  -f ($(if ($end.HasTPM) {"Aanwezig"} else {"Ontbreekt"}))) -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    if ((Is-FullyEncrypted $end) -and $end.Protection -notmatch "Off") {
        Write-OK "BitLocker controle voltooid zonder problemen."
    } else {
        Write-Warn "BitLocker heeft een of meer waarschuwingen - zie details hierboven."
    }
    Write-Host "`nLogbestand (USB): $LogFile" -ForegroundColor Cyan
    Log "Klaar: pct=$($end.Percent) prot=$($end.Protection) conv='$($end.Conversion)' TPM=$($end.HasTPM)"
    Pause-Menu
}

# =============================================================================
# OPTIE 5 - ENROLLMENT-/INTUNE-STATUS
# =============================================================================
function Show-EnrollmentStatus {
    Show-Header
    Write-Section "Enrollment-/Intune-status"
    try {
        $raw = dsregcmd /status

        function Field($name) {
            $m = $raw | Select-String -Pattern ("^\s*{0}\s*:\s*(.+)$" -f [regex]::Escape($name))
            if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
            return "Onbekend"
        }

        $azureAd = Field "AzureAdJoined"
        $domain  = Field "DomainJoined"
        $tenant  = Field "TenantName"
        $mdm     = Field "MDMUrl"
        $devId   = Field "DeviceId"

        function Stat($label, $value, $goodPattern) {
            $color = if ($value -match $goodPattern) { "Green" } elseif ($value -eq "Onbekend") { "DarkGray" } else { "Yellow" }
            Write-Host ("  {0,-22}" -f $label) -ForegroundColor White -NoNewline
            Write-Host (": {0}" -f $value) -ForegroundColor $color
        }

        Write-Host ""
        Stat "Azure AD joined"   $azureAd "YES"
        Stat "Domein joined"     $domain  "YES|NO"
        Stat "Tenant"            $tenant  "."
        Stat "Intune (MDM)"      ($(if ($mdm -ne 'Onbekend' -and $mdm) { "Beheerd ($mdm)" } else { "Niet beheerd" })) "Beheerd"
        Stat "Device ID"         $devId   "."

        Write-Host ""
        if ($azureAd -match "YES" -and $mdm -ne "Onbekend") {
            Write-OK "Toestel is Azure AD joined en Intune-beheerd."
        } else {
            Write-Warn "Toestel is mogelijk nog niet volledig ingeschreven - zie details hierboven."
        }

        Write-Host ""
        $full = Read-Host "Volledige dsregcmd-output tonen? (J/n)"
        if ($full -notmatch '^[Nn]') {
            Write-Host ""
            $raw | Out-Host
        }
    }
    catch {
        Write-Err "Kon enrollment-status niet ophalen: $($_.Exception.Message)"
    }
    Pause-Menu
}

# =============================================================================
# AUTO-UPDATE BIJ OPSTARTEN
# =============================================================================
if (-not $SkipUpdate) {
    $updateResult = Invoke-AutoUpdate
} else {
    $updateResult = @{ Updated = $false; Message = $null }
    Write-Info "Update-check overgeslagen (zojuist bijgewerkt)."
}

if ($updateResult.Updated) {
    Show-Header
    Write-Host ""
    Write-OK "Bijgewerkt naar v$($updateResult.NewVersion)!"

    if ($updateResult.Changelog) {
        Write-Host ""
        Write-Host "   Wat is nieuw:" -ForegroundColor Cyan
        $updateResult.Changelog -split "`n" | ForEach-Object {
            Write-Host "   $_" -ForegroundColor White
        }
    }

    Write-Host ""
    Write-Host "   Script wordt herstart met de nieuwe versie..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    & $PSCommandPath -SkipUpdate
    exit
}
elseif ($updateResult.Message) {
    Write-Warn $updateResult.Message
    Start-Sleep -Seconds 2
}

# =============================================================================
# HOOFDLUS
# =============================================================================
do {
    Show-Menu
    $choice = Read-Host "   Maak uw keuze"
    switch ($choice) {
        '1' { Invoke-Enrollment }
        '2' { Invoke-DriverUpdates }
        '3' { Show-SystemInfo }
        '4' { Invoke-BitlockerCheck }
        '5' { Show-EnrollmentStatus }
        '9' { Invoke-Rollback }
        '0' {
            Show-Header
            Write-Host ""
            Write-Host "   Tot ziens! Toolkit wordt afgesloten." -ForegroundColor Cyan
            Write-Host ""
            Start-Sleep -Milliseconds 800
        }
        default {
            Write-Warn "Ongeldige keuze: '$choice'. Kies 0-5 of 9."
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne '0')
