#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-Baseline - Application graphique d'initialisation et de durcissement
    d'un poste client Windows 11.

.DESCRIPTION
    Fichier UNIQUE, autonome, lancable via :
        irm https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1 | iex

    Architecture (calquee sur le pattern WinUtil de Chris Titus) :
      * XAML integre en here-string, charge par [Windows.Markup.XamlReader]
      * hashtable synchronisee $sync partagee entre le thread UI et les runspaces
      * toutes les actions longues executees dans un RunspacePool -> UI jamais gelee
      * journal temps reel alimente par une file concurrente drainee par un DispatcherTimer

    Les fonctions d'action sont PURES (aucune dependance a la GUI) et donc
    reutilisables en ligne de commande via -NoGUI.

.PARAMETER NoGUI
    Execute sans interface graphique (deploiement Intune / GPO / SCCM).
    Alias : -CLI. Mode strictement non interactif.

.PARAMETER Preset
    Prereglage a appliquer en mode -NoGUI.
    CIS-L1, CIS-L2, ANSSI-Minimal, ANSSI-Intermediaire, ANSSI-Eleve, ANSSI-Renforce

.PARAMETER Actions
    Liste d'identifiants d'actions a appliquer (mode -NoGUI). Cumulable avec -Preset.

.PARAMETER ListActions
    Affiche le catalogue complet des actions (identifiant, categorie, risque) et quitte.

.EXAMPLE
    irm https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1 | iex

.EXAMPLE
    # Mode non interactif (les parametres exigent la forme scriptblock) :
    &([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -NoGUI -Preset ANSSI-Eleve

.NOTES
    Version : 2.0.0
    Licence : MIT
    AVERTISSEMENT : sous-ensemble representatif de mesures inspirees de CIS et
    ANSSI BP-028. Ni exhaustif, ni une certification de conformite. Testez sur
    un poste pilote ; en production privilegiez GPO / Microsoft Intune.
#>

[CmdletBinding()]
param(
    [Alias('CLI')]
    [switch]$NoGUI,

    [ValidateSet('CIS-L1','CIS-L2','ANSSI-Minimal','ANSSI-Intermediaire','ANSSI-Eleve','ANSSI-Renforce')]
    [string]$Preset,

    [string[]]$Actions,

    [switch]$ListActions
)

# =====================================================================
# CONFIG
# =====================================================================

# --- URL brute du script sur GitHub ----------------------------------
# Sert a se relancer en administrateur quand on tourne "en memoire"
# (irm | iex). SEULE ligne a adapter en cas de fork.
$script:RawUrl  = 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'
$script:Version = '2.0.0'

# --- TLS 1.2 explicite (PS 5.1 peut encore negocier TLS 1.0/1.1) ------
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# --- Mode de langage (AppLocker / WDAC) -------------------------------
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "Ce poste restreint PowerShell (LanguageMode = $($ExecutionContext.SessionState.LanguageMode))." -ForegroundColor Red
    Write-Host "Win11-Baseline ne peut pas s'executer dans ce mode. Voyez l'administrateur du parc." -ForegroundColor Red
    return
}

# --- Detection : fichier sur disque ou execution en memoire ? ---------
# Doit rester au niveau SCRIPT (sinon $MyInvocation designerait la fonction).
$script:SelfPath = $null
if     ($PSCommandPath)               { $script:SelfPath = $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $script:SelfPath = $MyInvocation.MyCommand.Path }
$script:IsInMemory = [string]::IsNullOrWhiteSpace($script:SelfPath)

# --- Hashtable SYNCHRONISEE partagee UI <-> runspaces -----------------
# C'est le pilier du pattern WinUtil : un unique objet thread-safe qui
# transporte l'etat, les references de controles WPF, la file de logs et
# les resultats. Toute valeur ecrite ici depuis un runspace est
# immediatement visible du thread UI (et inversement).
$sync = [Hashtable]::Synchronized(@{})
$sync.Version       = $script:Version
$sync.RawUrl        = $script:RawUrl
$sync.Running       = $false          # une execution est-elle en cours ?
$sync.Cancelled     = $false
$sync.Done          = $false          # execution terminee, la GUI doit conclure
$sync.NeedReboot    = $false
$sync.Progress      = 0
$sync.ProgressTotal = 0
$sync.CurrentLabel  = ''
$sync.Results       = [System.Collections.Generic.List[PSObject]]::new()
$sync.LogQueue      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$sync.FormData      = @{}
$sync.Checkboxes    = @{}
$sync.ADShares      = [System.Collections.Generic.List[PSObject]]::new()

# --- Journalisation ---------------------------------------------------
$sync.LogDir  = Join-Path $env:LOCALAPPDATA 'Win11-Baseline\logs'
$sync.LogFile = Join-Path $sync.LogDir ("{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
try {
    if (-not (Test-Path $sync.LogDir)) { New-Item -ItemType Directory -Path $sync.LogDir -Force | Out-Null }
} catch { }

# =====================================================================
# FONCTIONS - Socle technique (journal, registre, elevation)
# ---------------------------------------------------------------------
# Toutes les fonctions sont prefixees W11B : c'est ce prefixe qui sert
# de filtre pour les injecter dans l'InitialSessionState des runspaces.
# =====================================================================

function Write-W11BLog {
    <#
    .SYNOPSIS
        Ecrit une ligne dans le fichier de log ET dans la file consommee par l'UI.
    .DESCRIPTION
        Appelable depuis n'importe quel thread : le fichier est ecrit
        directement, l'UI est alimentee via une ConcurrentQueue drainee par un
        DispatcherTimer. On NE touche JAMAIS un controle WPF depuis un runspace.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','RUN','OK','WARN','ERR','STEP')]
        [string]$Level = 'INFO'
    )
    $line = "[{0}] [{1,-4}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { [System.IO.File]::AppendAllText($sync.LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8) } catch { }
    if ($sync.LogQueue) { $sync.LogQueue.Enqueue($line) }
    if ($sync.ConsoleEcho) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'ERR'   { 'Red' }
            'WARN'  { 'Yellow' }
            'STEP'  { 'Cyan' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Test-W11BAdmin {
    <# .SYNOPSIS Le processus courant est-il eleve ? #>
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-W11BRelaunchCommand {
    <#
    .SYNOPSIS
        Construit la commande capable de RELANCER ce script.
    .DESCRIPTION
        En execution memoire (irm | iex) aucun fichier .ps1 n'existe : on ne
        peut pas relancer avec -File. On re-joue donc la meme commande de
        telechargement, ce qui preserve le fonctionnement "une ligne" jusque
        dans le processus eleve. Les parametres eventuels sont propages.
    #>
    param([string]$ExtraArgs = '')
    if ($script:IsInMemory) {
        return "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; &([ScriptBlock]::Create((irm '$($script:RawUrl)'))) $ExtraArgs"
    } else {
        return "& { & '$($script:SelfPath)' $ExtraArgs }"
    }
}

function Set-W11BRegistry {
    <# .SYNOPSIS Ecrit une valeur de registre en creant le chemin au besoin. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','ExpandString','QWord','MultiString','Binary')]
        [string]$Type = 'DWord'
    )
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-W11BRegistry {
    <# .SYNOPSIS Supprime une valeur de registre (retour au defaut Windows). #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# FONCTIONS - ACTIONS DE DURCISSEMENT (pures, sans dependance GUI)
# ---------------------------------------------------------------------
# Une fonction = une action selectionnable. Chacune leve une exception en
# cas d'echec (le wrapper Invoke-W11BAction la capture et la journalise).
# Les fonctions Undo-* remettent la valeur par defaut de Windows.
# =====================================================================

# --- Point de restauration (a executer AVANT tout le reste) -----------
function Invoke-W11BRestorePoint {
    Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
    # Windows limite a 1 point / 24 h : on desactive temporairement le verrou.
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
                     -Name 'SystemRestorePointCreationFrequency' -Value 0
    Checkpoint-Computer -Description "Win11-Baseline $($sync.Version)" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
}

# ---------------------------------------------------------------------
# CATEGORIE : SOCLE (CIS L1 / ANSSI Minimal)
# ---------------------------------------------------------------------

function Invoke-W11BFirewall {
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -ErrorAction Stop
}
function Undo-W11BFirewall {
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled NotConfigured -ErrorAction Stop
}

function Invoke-W11BSmb1Off {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
}
function Undo-W11BSmb1Off {
    Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction Stop
}

function Invoke-W11BUac {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-W11BRegistry -Path $p -Name 'EnableLUA'                 -Value 1
    Set-W11BRegistry -Path $p -Name 'ConsentPromptBehaviorAdmin' -Value 2
    Set-W11BRegistry -Path $p -Name 'PromptOnSecureDesktop'      -Value 1
    Set-W11BRegistry -Path $p -Name 'EnableInstallerDetection'   -Value 1
}
function Undo-W11BUac {
    # Valeurs par defaut de Windows 11 (UAC reste actif : on ne le desactive jamais)
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-W11BRegistry -Path $p -Name 'ConsentPromptBehaviorAdmin' -Value 5
    Set-W11BRegistry -Path $p -Name 'PromptOnSecureDesktop'      -Value 1
}

function Invoke-W11BAutoRunOff {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    Set-W11BRegistry -Path $p -Name 'NoDriveTypeAutoRun' -Value 255
    Set-W11BRegistry -Path $p -Name 'NoAutorun'          -Value 1
}
function Undo-W11BAutoRunOff {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    Remove-W11BRegistry -Path $p -Name 'NoDriveTypeAutoRun'
    Remove-W11BRegistry -Path $p -Name 'NoAutorun'
}

function Invoke-W11BGuestOff {
    $guest = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' }
    if ($guest) { Disable-LocalUser -Name $guest.Name -ErrorAction Stop }
    else { throw "Compte Invite (SID -501) introuvable sur ce poste." }
}
function Undo-W11BGuestOff {
    $guest = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' }
    if ($guest) { Enable-LocalUser -Name $guest.Name -ErrorAction Stop }
}

function Invoke-W11BPasswordPolicy {
    $out1 = cmd /c "net accounts /minpwlen:14 /maxpwage:365 /minpwage:1 /uniquepw:24" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out1 -join ' ') }
    $out2 = cmd /c "net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15" 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out2 -join ' ') }
}
function Undo-W11BPasswordPolicy {
    cmd /c "net accounts /minpwlen:0 /maxpwage:42 /minpwage:0 /uniquepw:0" | Out-Null
    cmd /c "net accounts /lockoutthreshold:10 /lockoutduration:10 /lockoutwindow:10" | Out-Null
}

function Invoke-W11BDefenderBase {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
    Set-MpPreference -PUAProtection Enabled            -ErrorAction SilentlyContinue
    Set-MpPreference -MAPSReporting Advanced           -ErrorAction SilentlyContinue
    Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
}
function Undo-W11BDefenderBase {
    Set-MpPreference -PUAProtection Disabled -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# CATEGORIE : INTERMEDIAIRE (CIS L1 etendu / ANSSI Intermediaire)
# ---------------------------------------------------------------------

function Invoke-W11BSmbSigning {
    Set-SmbServerConfiguration -RequireSecuritySignature $true -Force -ErrorAction Stop
    Set-SmbClientConfiguration -RequireSecuritySignature $true -Force -ErrorAction Stop
}
function Undo-W11BSmbSigning {
    Set-SmbServerConfiguration -RequireSecuritySignature $false -Force -ErrorAction Stop
    Set-SmbClientConfiguration -RequireSecuritySignature $false -Force -ErrorAction Stop
}

function Invoke-W11BNtlmHardening {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Set-W11BRegistry -Path $lsa -Name 'LmCompatibilityLevel' -Value 5
    Set-W11BRegistry -Path $lsa -Name 'NoLMHash'             -Value 1
}
function Undo-W11BNtlmHardening {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Set-W11BRegistry -Path $lsa -Name 'LmCompatibilityLevel' -Value 3
}

function Invoke-W11BAnonymousRestrict {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Set-W11BRegistry -Path $lsa -Name 'RestrictAnonymous'         -Value 1
    Set-W11BRegistry -Path $lsa -Name 'RestrictAnonymousSAM'      -Value 1
    Set-W11BRegistry -Path $lsa -Name 'EveryoneIncludesAnonymous' -Value 0
}
function Undo-W11BAnonymousRestrict {
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    Set-W11BRegistry -Path $lsa -Name 'RestrictAnonymous' -Value 0
}

function Invoke-W11BLlmnrOff {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' `
                     -Name 'EnableMulticast' -Value 0
}
function Undo-W11BLlmnrOff {
    Remove-W11BRegistry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast'
}

function Invoke-W11BScriptBlockLogging {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' `
                     -Name 'EnableScriptBlockLogging' -Value 1
}
function Undo-W11BScriptBlockLogging {
    Remove-W11BRegistry -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' `
                        -Name 'EnableScriptBlockLogging'
}

function Invoke-W11BAuditBase {
    # GUID plutot que le libelle : les noms de categories auditpol sont LOCALISES
    # (le script d'origine echouait sur un Windows non francais).
    $categories = @(
        '{69979849-797A-11D9-BED3-505054503030}',  # Ouverture/Fermeture de session
        '{69979850-797A-11D9-BED3-505054503030}',  # Connexion de compte
        '{6997984E-797A-11D9-BED3-505054503030}'   # Gestion des comptes
    )
    foreach ($c in $categories) {
        $out = & auditpol.exe /set /category:$c /success:enable /failure:enable 2>&1
        if ($LASTEXITCODE -ne 0) { throw "auditpol $c : $($out -join ' ')" }
    }
}
function Undo-W11BAuditBase {
    foreach ($c in @('{69979849-797A-11D9-BED3-505054503030}',
                     '{69979850-797A-11D9-BED3-505054503030}',
                     '{6997984E-797A-11D9-BED3-505054503030}')) {
        & auditpol.exe /set /category:$c /success:disable /failure:disable | Out-Null
    }
}

function Invoke-W11BScreenLock {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                     -Name 'InactivityTimeoutSecs' -Value 900
}
function Undo-W11BScreenLock {
    Remove-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                        -Name 'InactivityTimeoutSecs'
}

# ---------------------------------------------------------------------
# CATEGORIE : ELEVE (CIS L2 / ANSSI Eleve)
# ---------------------------------------------------------------------

function Invoke-W11BWdigestOff {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                     -Name 'UseLogonCredential' -Value 0
}
function Undo-W11BWdigestOff {
    Remove-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
                        -Name 'UseLogonCredential'
}

function Invoke-W11BLsassPpl {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 1
    $sync.NeedReboot = $true
}
function Undo-W11BLsassPpl {
    Remove-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
    $sync.NeedReboot = $true
}

function Invoke-W11BAudit4688 {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
                     -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1
    # {0CCE922B-...} = sous-categorie "Creation du processus" (GUID non localise)
    $out = & auditpol.exe /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:enable /failure:enable 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
}
function Undo-W11BAudit4688 {
    Remove-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
                        -Name 'ProcessCreationIncludeCmdLine_Enabled'
    & auditpol.exe /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:disable /failure:disable | Out-Null
}

function Invoke-W11BPsTranscription {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'
    Set-W11BRegistry -Path $p -Name 'EnableTranscripting' -Value 1
    Set-W11BRegistry -Path $p -Name 'OutputDirectory' -Value 'C:\PS-Transcripts' -Type String
}
function Undo-W11BPsTranscription {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'
    Remove-W11BRegistry -Path $p -Name 'EnableTranscripting'
    Remove-W11BRegistry -Path $p -Name 'OutputDirectory'
}

function Invoke-W11BRdpNla {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                     -Name 'UserAuthentication' -Value 1
}
function Undo-W11BRdpNla {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
                     -Name 'UserAuthentication' -Value 0
}

function Invoke-W11BRemoteAssistOff {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' `
                     -Name 'fAllowToGetHelp' -Value 0
}
function Undo-W11BRemoteAssistOff {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' `
                     -Name 'fAllowToGetHelp' -Value 1
}

function Invoke-W11BControlledFolderAccess {
    Set-MpPreference -EnableControlledFolderAccess Enabled -ErrorAction Stop
}
function Undo-W11BControlledFolderAccess {
    Set-MpPreference -EnableControlledFolderAccess Disabled -ErrorAction Stop
}

function Invoke-W11BLdapSigning {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LDAP' `
                     -Name 'LDAPClientIntegrity' -Value 2
}
function Undo-W11BLdapSigning {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LDAP' `
                     -Name 'LDAPClientIntegrity' -Value 1
}

function Invoke-W11BCachedLogons {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
                     -Name 'CachedLogonsCount' -Value '4' -Type String
}
function Undo-W11BCachedLogons {
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
                     -Name 'CachedLogonsCount' -Value '10' -Type String
}

# ---------------------------------------------------------------------
# CATEGORIE : RENFORCE (ANSSI Renforce)
# ---------------------------------------------------------------------

function Get-W11BAsrRuleIds {
    <# .SYNOPSIS Identifiants des regles ASR appliquees par la baseline. #>
    @(
        'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550',  # Contenu executable depuis messagerie/webmail
        'D4F940AB-401B-4EFC-AADC-AD5F3C50688A',  # Office ne cree pas de processus enfant
        '3B576869-A4EC-4529-8536-B80A7769E899',  # Office ne cree pas de contenu executable
        '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2',  # Vol d'identifiants depuis LSASS
        'E6DB77E5-3DF2-4CF1-B95A-636979351E5B',  # Persistance via abonnement WMI
        'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4'   # Processus non fiables depuis USB
    )
}
function Invoke-W11BAsrRules {
    foreach ($id in (Get-W11BAsrRuleIds)) {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $id `
                         -AttackSurfaceReductionRules_Actions Enabled -ErrorAction Stop
    }
}
function Undo-W11BAsrRules {
    foreach ($id in (Get-W11BAsrRuleIds)) {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $id `
                         -AttackSurfaceReductionRules_Actions Disabled -ErrorAction SilentlyContinue
    }
}

function Invoke-W11BVbsCredentialGuard {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 1
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'RequirePlatformSecurityFeatures'   -Value 1
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 1
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LsaCfgFlags' -Value 1
    $sync.NeedReboot = $true
}
function Undo-W11BVbsCredentialGuard {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity' -Value 0
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled' -Value 0
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LsaCfgFlags' -Value 0
    $sync.NeedReboot = $true
}

function Invoke-W11BClearPageFile {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
                     -Name 'ClearPageFileAtShutdown' -Value 1
}
function Undo-W11BClearPageFile {
    Set-W11BRegistry -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' `
                     -Name 'ClearPageFileAtShutdown' -Value 0
}

function Invoke-W11BPowerShellV2Off {
    $f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
    if ($f.State -eq 'Enabled') {
        Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction Stop | Out-Null
        $sync.NeedReboot = $true
    }
}
function Undo-W11BPowerShellV2Off {
    Enable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction Stop | Out-Null
    $sync.NeedReboot = $true
}

function Invoke-W11BExecutionPolicy {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
}
function Undo-W11BExecutionPolicy {
    Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope LocalMachine -Force -ErrorAction Stop
}

function Invoke-W11BLegalBanner {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Set-W11BRegistry -Path $p -Name 'legalnoticecaption' -Value 'AVERTISSEMENT LEGAL' -Type String
    Set-W11BRegistry -Path $p -Name 'legalnoticetext' `
        -Value 'Acces reserve au personnel autorise. Toute action non autorisee sera enregistree et poursuivie.' -Type String
}
function Undo-W11BLegalBanner {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    Remove-W11BRegistry -Path $p -Name 'legalnoticecaption'
    Remove-W11BRegistry -Path $p -Name 'legalnoticetext'
}

# =====================================================================
# FONCTIONS - ACTIONS "FORMULAIRE" (parametrees par la GUI ou la CLI)
# =====================================================================

function Set-W11BIPConfiguration {
    <#
    .SYNOPSIS
        Applique un adressage statique ou repasse la carte en DHCP.
    .PARAMETER InterfaceAlias
        Nom de la carte reseau (ex: Ethernet).
    .PARAMETER Mode
        Static ou DHCP.
    #>
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [Parameter(Mandatory)][ValidateSet('Static','DHCP')][string]$Mode,
        [string]$IPAddress,
        [int]$PrefixLength,
        [string]$Gateway,
        [string]$Dns
    )

    Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute     -InterfaceAlias $InterfaceAlias -Confirm:$false -ErrorAction SilentlyContinue

    if ($Mode -eq 'DHCP') {
        Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Enabled -ErrorAction Stop
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ResetServerAddresses -ErrorAction Stop
        return "Carte '$InterfaceAlias' repassee en DHCP"
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) { throw "Adresse IP invalide : '$IPAddress'" }
    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32)                    { throw "Masque CIDR invalide : '/$PrefixLength' (0-32 attendu)" }

    Set-NetIPInterface -InterfaceAlias $InterfaceAlias -Dhcp Disabled -ErrorAction SilentlyContinue
    if ($Gateway) {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
    } else {
        New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $IPAddress -PrefixLength $PrefixLength -ErrorAction Stop | Out-Null
    }
    if ($Dns) {
        $servers = @($Dns -split '[,; ]+' | Where-Object { $_ })
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $servers -ErrorAction Stop
    }
    return "IP statique $IPAddress/$PrefixLength appliquee sur '$InterfaceAlias'"
}

function Set-W11BComputerName {
    <# .SYNOPSIS Renomme le poste (sans jonction de domaine). Redemarrage requis. #>
    param([Parameter(Mandatory)][string]$NewName)

    if ($NewName.Length -gt 15)          { throw "Nom trop long (15 caracteres NetBIOS maximum)." }
    if ($NewName -notmatch '^[A-Za-z0-9-]+$') { throw "Caracteres invalides (lettres, chiffres et tirets uniquement)." }
    if ($NewName -match '^\d+$')         { throw "Un nom entierement numerique n'est pas autorise." }
    if ($NewName -eq $env:COMPUTERNAME)  { return "Nom inchange ('$NewName')" }

    Rename-Computer -NewName $NewName -Force -ErrorAction Stop
    $sync.NeedReboot = $true
    return "Poste renomme '$env:COMPUTERNAME' -> '$NewName' (redemarrage requis)"
}

function Join-W11BDomain {
    <#
    .SYNOPSIS
        Joint le poste a un domaine Active Directory, avec renommage optionnel
        dans la meme operation (Add-Computer -NewName).
    #>
    param(
        [Parameter(Mandatory)][string]$DomainName,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [string]$NewName
    )
    if ($NewName -and $NewName -ne $env:COMPUTERNAME) {
        Add-Computer -DomainName $DomainName -Credential $Credential -NewName $NewName -Force -ErrorAction Stop
        $msg = "Poste renomme '$NewName' ET joint au domaine '$DomainName'"
    } else {
        Add-Computer -DomainName $DomainName -Credential $Credential -Force -ErrorAction Stop
        $msg = "Poste joint au domaine '$DomainName'"
    }
    $sync.NeedReboot = $true
    return "$msg (redemarrage requis)"
}

function Get-W11BADPublishedShares {
    <#
    .SYNOPSIS
        Decouvre les partages PUBLIES dans l'Active Directory (objets 'volume').
    .DESCRIPTION
        Utilise System.DirectoryServices (natif .NET) : RSAT n'est pas requis.
        Renvoie un tableau { Name ; UNC ; Description }, vide si echec.
        ATTENTION : appel LDAP potentiellement lent -> a executer en runspace.
    #>
    $results = @()
    try {
        $rootDSE   = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $defaultNC = $rootDSE.Properties["defaultNamingContext"].Value
        if ([string]::IsNullOrWhiteSpace($defaultNC)) { return @() }

        $searchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$defaultNC")
        $searcher   = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
        $searcher.Filter   = "(objectClass=volume)"
        $searcher.PageSize = 200
        [void]$searcher.PropertiesToLoad.Add("uNCName")
        [void]$searcher.PropertiesToLoad.Add("name")
        [void]$searcher.PropertiesToLoad.Add("description")

        $found = $searcher.FindAll()
        foreach ($f in $found) {
            $unc = $null; $nm = $null; $desc = $null
            if ($f.Properties["uncname"].Count     -gt 0) { $unc  = [string]$f.Properties["uncname"][0] }
            if ($f.Properties["name"].Count        -gt 0) { $nm   = [string]$f.Properties["name"][0] }
            if ($f.Properties["description"].Count -gt 0) { $desc = [string]$f.Properties["description"][0] }
            if (-not [string]::IsNullOrWhiteSpace($unc)) {
                $results += [PSCustomObject]@{ Name = $nm; UNC = $unc; Description = $desc }
            }
        }
        $found.Dispose()
    } catch {
        return @()
    }
    return $results
}

function New-W11BNetworkDrive {
    <# .SYNOPSIS Mappe un lecteur reseau PERSISTANT vers un chemin UNC. #>
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]$')][string]$Letter,
        [Parameter(Mandatory)][string]$UncPath,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$Replace
    )
    if ($UncPath -notmatch '^\\\\[^\\]+\\.+') { throw "Chemin UNC invalide (format attendu : \\serveur\partage)" }
    $Letter = $Letter.ToUpper()

    $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($used -contains $Letter) {
        if (-not $Replace) { throw "La lettre $Letter est deja utilisee (cochez 'remplacer' pour l'ecraser)." }
        Remove-PSDrive -Name $Letter -Force -ErrorAction SilentlyContinue
        & cmd.exe /c "net use ${Letter}: /delete /y" 2>&1 | Out-Null
    }

    $params = @{ Name = $Letter; PSProvider = 'FileSystem'; Root = $UncPath; Persist = $true; Scope = 'Global'; ErrorAction = 'Stop' }
    if ($Credential) { $params['Credential'] = $Credential }
    New-PSDrive @params | Out-Null
    return "Lecteur ${Letter}: -> $UncPath (persistant)"
}

function Invoke-W11BLinkedConnections {
    <#
    .SYNOPSIS
        EnableLinkedConnections : rend les lecteurs mappes visibles entre le
        jeton standard et le jeton eleve (UAC). Redemarrage requis.
    #>
    Set-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                     -Name 'EnableLinkedConnections' -Value 1
    $sync.NeedReboot = $true
}
function Undo-W11BLinkedConnections {
    Remove-W11BRegistry -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                        -Name 'EnableLinkedConnections'
    $sync.NeedReboot = $true
}

# =====================================================================
# FONCTIONS - MOTEUR D'EXECUTION (commun GUI et CLI)
# =====================================================================

function Invoke-W11BAction {
    <#
    .SYNOPSIS
        Execute UNE action du catalogue en gerant erreurs, statut et journal.
    .DESCRIPTION
        Le catalogue ne stocke QUE des NOMS de fonctions (chaines), jamais des
        scriptblocks : un scriptblock reste lie a la session qui l'a cree et
        traverse mal les runspaces. Les fonctions, elles, sont injectees dans
        l'InitialSessionState du pool (voir Initialize-W11BRunspacePool).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Action,
        [hashtable]$Arguments,
        [switch]$Undo
    )

    $fn = if ($Undo) { $Action.Undo } else { $Action.Apply }
    if (-not $fn) {
        Write-W11BLog -Level 'WARN' -Message "$($Action.Name) : aucune annulation disponible"
        return [PSCustomObject]@{ Id = $Action.Id; Status = 'Skipped'; Message = 'Pas d''annulation définie' }
    }

    $verbe = if ($Undo) { 'Annulation' } else { 'Application' }
    Write-W11BLog -Level 'RUN' -Message "$verbe : $($Action.Name)"
    try {
        $out = if ($Arguments -and $Arguments.Count -gt 0) { & $fn @Arguments } else { & $fn }
        $detail = if ($out) { ($out | Select-Object -Last 1) } else { $Action.Name }
        Write-W11BLog -Level 'OK' -Message $detail
        return [PSCustomObject]@{ Id = $Action.Id; Status = 'OK'; Message = "$detail" }
    } catch {
        Write-W11BLog -Level 'ERR' -Message "$($Action.Name) -> $($_.Exception.Message)"
        return [PSCustomObject]@{ Id = $Action.Id; Status = 'Error'; Message = $_.Exception.Message }
    }
}

function Get-W11BAction {
    <# .SYNOPSIS Retourne l'entree de catalogue correspondant a un identifiant. #>
    param([Parameter(Mandatory)][string]$Id)
    return ($sync.Catalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

function Invoke-W11BSelection {
    <#
    .SYNOPSIS
        Coeur de l'execution : deroule la liste d'identifiants selectionnes.
    .DESCRIPTION
        Ne touche AUCUN controle WPF : la progression et le journal transitent
        exclusivement par $sync (hashtable synchronisee) et par la file de logs.
        C'est cette fonction que le runspace execute, et que la CLI appelle
        directement.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Ids,
        [switch]$Undo
    )

    $sync.Running       = $true
    $sync.Done          = $false
    $sync.Progress      = 0
    $sync.ProgressTotal = $Ids.Count
    $sync.Results.Clear()

    $verbe = if ($Undo) { 'ANNULATION' } else { 'APPLICATION' }
    Write-W11BLog -Level 'STEP' -Message "=== $verbe de $($Ids.Count) action(s) - $env:COMPUTERNAME / $env:USERNAME ==="

    # Le point de restauration doit toujours passer en premier.
    $ordered = @($Ids | Where-Object { $_ -eq 'SYS-RestorePoint' }) + @($Ids | Where-Object { $_ -ne 'SYS-RestorePoint' })

    foreach ($id in $ordered) {
        if ($sync.Cancelled) { Write-W11BLog -Level 'WARN' -Message 'Exécution interrompue par l''utilisateur.'; break }

        $action = Get-W11BAction -Id $id
        if (-not $action) {
            Write-W11BLog -Level 'ERR' -Message "Action inconnue : $id"
            $sync.Results.Add([PSCustomObject]@{ Id = $id; Status = 'Error'; Message = 'Identifiant inconnu' })
            $sync.Progress++
            continue
        }

        $sync.CurrentLabel = $action.Name
        $actionArgs = $null
        if ($action.Kind -eq 'Form') { $actionArgs = $sync.FormData[$action.Id] }

        $sync.Results.Add((Invoke-W11BAction -Action $action -Arguments $actionArgs -Undo:$Undo))
        $sync.Progress++
    }

    $ok  = @($sync.Results | Where-Object { $_.Status -eq 'OK' }).Count
    $ko  = @($sync.Results | Where-Object { $_.Status -eq 'Error' }).Count
    $sk  = @($sync.Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    Write-W11BLog -Level 'STEP' -Message "=== TERMINÉ : $ok réussie(s), $ko échec(s), $sk ignorée(s) ==="
    if ($sync.NeedReboot) { Write-W11BLog -Level 'WARN' -Message 'Un REDÉMARRAGE est nécessaire pour appliquer certains changements.' }
    Write-W11BLog -Level 'INFO' -Message "Journal complet : $($sync.LogFile)"

    $sync.CurrentLabel = 'Terminé'
    $sync.Running      = $false
    $sync.Done         = $true
}

# =====================================================================
# CATALOGUE DES ACTIONS
# ---------------------------------------------------------------------
# Source unique de verite : l'interface est GENEREE a partir de ce
# tableau (comme les fichiers config/*.json de WinUtil). Ajouter une
# action = ajouter une entree ici + la fonction correspondante.
#
#   Id       identifiant stable (utilisable avec -Actions en CLI)
#   Category Socle | Intermediaire | Eleve | Renforce | Systeme
#   Kind     Toggle (interrupteur simple) | Form (formulaire dedie)
#   Risk     Faible | Sensible | Eleve  -> badge visuel dans la GUI
#   Reboot   l'action exige un redemarrage
#   Apply    nom de la fonction d'application
#   Undo     nom de la fonction d'annulation ($null si non reversible)
# =====================================================================

$sync.Catalog = @(

    # ---------- SOCLE ------------------------------------------------
    @{ Id='SEC-Firewall';        Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Pare-feu Windows activé (Domaine / Privé / Public)'
       Tip='Activé le pare-feu sur les trois profils réseau. Mesure de base CIS L1 et ANSSI Minimal.'
       Apply='Invoke-W11BFirewall'; Undo='Undo-W11BFirewall' }

    @{ Id='SEC-SMB1Off';         Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Protocole SMBv1 (obsolète) désactivé côté serveur'
       Tip='SMBv1 est le vecteur de WannaCry/NotPetya. Peut casser l''accès à de très vieux NAS ou imprimantes réseau.'
       Apply='Invoke-W11BSmb1Off'; Undo='Undo-W11BSmb1Off' }

    @{ Id='SEC-UAC';             Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='UAC actif (EnableLUA, invite sur bureau sécurisé)'
       Tip='Force le contrôle de compte utilisateur, l''invite de consentement administrateur et le bureau sécurisé.'
       Apply='Invoke-W11BUac'; Undo='Undo-W11BUac' }

    @{ Id='SEC-AutoRun';         Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Exécution automatique (AutoRun / AutoPlay) désactivée'
       Tip='Bloque l''exécution automatique depuis les supports amovibles (clés USB piégées).'
       Apply='Invoke-W11BAutoRunOff'; Undo='Undo-W11BAutoRunOff' }

    @{ Id='SEC-Guest';           Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Compte Invité (Guest, SID -501) désactivé'
       Tip='Désactivé le compte Invite quel que soit son nom (identification par SID).'
       Apply='Invoke-W11BGuestOff'; Undo='Undo-W11BGuestOff' }

    @{ Id='SEC-PwdPolicy';       Category='Socle'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Politique de mots de passe (>= 14 car., historique, verrouillage)'
       Tip='ATTENTION : s''applique aux COMPTES LOCAUX. Les utilisateurs dont le mot de passe fait moins de 14 caractères devront le changer au prochain changement. Sans effet sur les comptes de domaine (gérés par GPO).'
       Apply='Invoke-W11BPasswordPolicy'; Undo='Undo-W11BPasswordPolicy' }

    @{ Id='SEC-Defender';        Category='Socle'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Windows Defender : temps réel + cloud + anti-PUA'
       Tip='Réactive la protection temps réel, la protection cloud (MAPS) et le blocage des applications potentiellement indésirables.'
       Apply='Invoke-W11BDefenderBase'; Undo='Undo-W11BDefenderBase' }

    # ---------- INTERMEDIAIRE ---------------------------------------
    @{ Id='SEC-SmbSigning';      Category='Intermediaire'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Signature SMB obligatoire (serveur et client)'
       Tip='Bloque les attaques de relais SMB. ATTENTION : peut empêcher l''accès à des partages anciens ne supportant pas la signature.'
       Apply='Invoke-W11BSmbSigning'; Undo='Undo-W11BSmbSigning' }

    @{ Id='SEC-Ntlm';            Category='Intermediaire'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='NTLM durci : refus LM / NTLMv1, pas de hash LM'
       Tip='LmCompatibilityLevel = 5 (NTLMv2 uniquement). ATTENTION : coupe l''authentification vers des serveurs ou NAS anciens limités à NTLMv1.'
       Apply='Invoke-W11BNtlmHardening'; Undo='Undo-W11BNtlmHardening' }

    @{ Id='SEC-Anonymous';       Category='Intermediaire'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Accès anonyme restreint (RestrictAnonymous / SAM)'
       Tip='Empêche l''enumeration anonyme des comptes et des partages.'
       Apply='Invoke-W11BAnonymousRestrict'; Undo='Undo-W11BAnonymousRestrict' }

    @{ Id='SEC-LLMNR';           Category='Intermediaire'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Résolution LLMNR désactivée (anti-spoofing réseau)'
       Tip='Neutralise les attaques de type Responder. Sans impact si le DNS du réseau est correctement configuré.'
       Apply='Invoke-W11BLlmnrOff'; Undo='Undo-W11BLlmnrOff' }

    @{ Id='SEC-ScriptLog';       Category='Intermediaire'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Journalisation des blocs de scripts PowerShell'
       Tip='Enregistre le code PowerShell exécute dans le journal Microsoft-Windows-PowerShell/Operational (event 4104).'
       Apply='Invoke-W11BScriptBlockLogging'; Undo='Undo-W11BScriptBlockLogging' }

    @{ Id='SEC-AuditBase';       Category='Intermediaire'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Audit : connexions, ouverture de session, gestion des comptes'
       Tip='Activé la stratégie d''audit avancée (succès et échecs) via les GUID de catégories, donc indépendamment de la langue de Windows.'
       Apply='Invoke-W11BAuditBase'; Undo='Undo-W11BAuditBase' }

    @{ Id='SEC-ScreenLock';      Category='Intermediaire'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='Verrouillage écran sur inactivité (900 s)'
       Tip='Verrouille automatiquement la session après 15 minutes d''inactivité.'
       Apply='Invoke-W11BScreenLock'; Undo='Undo-W11BScreenLock' }

    # ---------- ELEVE -----------------------------------------------
    @{ Id='SEC-WDigest';         Category='Eleve'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='WDigest : mise en cache des identifiants en clair désactivée'
       Tip='Empêche l''extraction de mots de passe en clair depuis la mémoire (Mimikatz).'
       Apply='Invoke-W11BWdigestOff'; Undo='Undo-W11BWdigestOff' }

    @{ Id='SEC-LsassPPL';        Category='Eleve'; Kind='Toggle'; Risk='Sensible'; Reboot=$true
       Name='Protection LSASS en processus protégé (RunAsPPL)'
       Tip='Empêche l''injection dans LSASS. ATTENTION : peut empêcher le chargement de pilotes ou d''antivirus tiers non signes correctement. Redémarrage requis.'
       Apply='Invoke-W11BLsassPpl'; Undo='Undo-W11BLsassPpl' }

    @{ Id='SEC-Audit4688';       Category='Eleve'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Audit avancé : création de processus + ligne de commande (4688)'
       Tip='Très utile en investigation. ATTENTION : volume de journaux important, et la ligne de commande peut contenir des secrets passes en argument.'
       Apply='Invoke-W11BAudit4688'; Undo='Undo-W11BAudit4688' }

    @{ Id='SEC-Transcription';   Category='Eleve'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Transcription PowerShell activée (C:\PS-Transcripts)'
       Tip='Enregistre toutes les sessions PowerShell sur disque. Surveillez la place occupée et protégez le dossier en ACL.'
       Apply='Invoke-W11BPsTranscription'; Undo='Undo-W11BPsTranscription' }

    @{ Id='SEC-RdpNla';          Category='Eleve'; Kind='Toggle'; Risk='Faible';   Reboot=$false
       Name='RDP : authentification NLA obligatoire'
       Tip='Exige une authentification avant l''ouverture de la session graphique distante.'
       Apply='Invoke-W11BRdpNla'; Undo='Undo-W11BRdpNla' }

    @{ Id='SEC-RemoteAssist';    Category='Eleve'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Assistance à distance désactivée'
       Tip='ATTENTION : si votre support interne utilise l''Assistance rapide / Assistance à distance Windows, cette mesure la coupe.'
       Apply='Invoke-W11BRemoteAssistOff'; Undo='Undo-W11BRemoteAssistOff' }

    @{ Id='SEC-CFA';             Category='Eleve'; Kind='Toggle'; Risk='Eleve';    Reboot=$false
       Name='Accès protégé aux dossiers (anti-ransomware)'
       Tip='RISQUE FONCTIONNEL ÉLEVÉ : bloque l''ecriture dans Documents/Images/... par toute application non approuvée. Attendez-vous à devoir autoriser manuellement des logiciels métier.'
       Apply='Invoke-W11BControlledFolderAccess'; Undo='Undo-W11BControlledFolderAccess' }

    @{ Id='SEC-LdapSigning';     Category='Eleve'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Signature LDAP cliente obligatoire'
       Tip='Exige la signature des requêtes LDAP. ATTENTION : peut casser des applications métier interrogeant l''AD en LDAP simple non chiffré.'
       Apply='Invoke-W11BLdapSigning'; Undo='Undo-W11BLdapSigning' }

    @{ Id='SEC-CachedLogons';    Category='Eleve'; Kind='Toggle'; Risk='Eleve';    Reboot=$false
       Name='Ouvertures de session mises en cache limitées à 4'
       Tip='RISQUE : sur un portable hors du réseau d''entreprise, un utilisateur dont le cache a été évincé ne pourra plus ouvrir de session. Déconseillé sur les postes nomades partages.'
       Apply='Invoke-W11BCachedLogons'; Undo='Undo-W11BCachedLogons' }

    # ---------- RENFORCE --------------------------------------------
    @{ Id='SEC-ASR';             Category='Renforce'; Kind='Toggle'; Risk='Eleve'; Reboot=$false
       Name='Règles ASR (Attack Surface Reduction) activées'
       Tip='RISQUE FONCTIONNEL ÉLEVÉ : bloque notamment les macros Office creant des processus enfants et les exécutables lancés depuis USB. Passez d''abord en mode Audit sur un poste pilote.'
       Apply='Invoke-W11BAsrRules'; Undo='Undo-W11BAsrRules' }

    @{ Id='SEC-VBS';             Category='Renforce'; Kind='Toggle'; Risk='Eleve'; Reboot=$true
       Name='Sécurité basée sur la virtualisation (VBS) + Credential Guard'
       Tip='RISQUE ÉLEVÉ : exige un matériel compatible (UEFI, TPM, virtualisation) et rend impossible l''usage d''hyperviseurs tiers (VMware/VirtualBox anciens). Peut empêcher le démarrage sur du matériel non conforme. Redémarrage requis.'
       Apply='Invoke-W11BVbsCredentialGuard'; Undo='Undo-W11BVbsCredentialGuard' }

    @{ Id='SEC-ClearPageFile';   Category='Renforce'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Effacement du fichier d''échange à l''arrêt'
       Tip='ATTENTION : allonge très sensiblement la durée d''extinction du poste (plusieurs minutes selon la taille du pagefile).'
       Apply='Invoke-W11BClearPageFile'; Undo='Undo-W11BClearPageFile' }

    @{ Id='SEC-PSv2';            Category='Renforce'; Kind='Toggle'; Risk='Sensible'; Reboot=$true
       Name='PowerShell v2 (obsolète) désactivé'
       Tip='Supprime le moteur v2, qui contourne la journalisation moderne. ATTENTION : de rares outils anciens exigent -Version 2. Redémarrage requis.'
       Apply='Invoke-W11BPowerShellV2Off'; Undo='Undo-W11BPowerShellV2Off' }

    @{ Id='SEC-ExecPolicy';      Category='Renforce'; Kind='Toggle'; Risk='Faible'; Reboot=$false
       Name='Politique d''exécution PowerShell : RemoteSigned (machine)'
       Tip='Autorisé les scripts locaux, exige une signature pour les scripts téléchargés.'
       Apply='Invoke-W11BExecutionPolicy'; Undo='Undo-W11BExecutionPolicy' }

    @{ Id='SEC-LegalBanner';     Category='Renforce'; Kind='Toggle'; Risk='Sensible'; Reboot=$false
       Name='Bannière légale à l''ouverture de session'
       Tip='ATTENTION : ajoute un écran de consentement à valider AVANT chaque ouverture de session. Adaptez le texte à votre charte informatique.'
       Apply='Invoke-W11BLegalBanner'; Undo='Undo-W11BLegalBanner' }

    # ---------- SYSTEME / RESEAU (formulaires) -----------------------
    @{ Id='SYS-RestorePoint';    Category='Systeme'; Kind='Toggle'; Risk='Faible'; Reboot=$false
       Name='Créer un point de restauration avant application'
       Tip='Fortement recommandé. Permet de revenir à l''état antérieur via la Restauration du système si une mesure casse un usage.'
       Apply='Invoke-W11BRestorePoint'; Undo=$null }

    @{ Id='NET-IPConfig';        Category='Systeme'; Kind='Form';   Risk='Sensible'; Reboot=$false
       Name='Configuration IP de la carte réseau'
       Tip='ATTENTION : une IP statique erronée coupe immédiatement le réseau du poste (et une session RDP en cours).'
       Apply='Set-W11BIPConfiguration'; Undo=$null }

    @{ Id='SYS-Rename';          Category='Systeme'; Kind='Form';   Risk='Sensible'; Reboot=$true
       Name='Renommer le poste'
       Tip='Nom NetBIOS : 15 caractères maximum, lettres/chiffres/tirets. Redémarrage requis.'
       Apply='Set-W11BComputerName'; Undo=$null }

    @{ Id='SYS-DomainJoin';      Category='Systeme'; Kind='Form';   Risk='Eleve';    Reboot=$true
       Name='Joindre un domaine Active Directory'
       Tip='RISQUE ÉLEVÉ : opération difficilement réversible sans intervention sur l''AD. Le renommage éventuel est fait dans la même opération. Redémarrage requis.'
       Apply='Join-W11BDomain'; Undo=$null }

    @{ Id='NET-MapDrive';        Category='Systeme'; Kind='Form';   Risk='Faible';   Reboot=$false
       Name='Mapper un lecteur réseau (persistant)'
       Tip='Découverte des partages publiés dans l''AD (sans RSAT) ou saisie manuelle d''un chemin UNC.'
       Apply='New-W11BNetworkDrive'; Undo=$null }

    @{ Id='NET-LinkedConn';      Category='Systeme'; Kind='Toggle'; Risk='Sensible'; Reboot=$true
       Name='EnableLinkedConnections (lecteurs visibles en session standard)'
       Tip='Rend les lecteurs mappés visibles entre le jeton standard et le jeton élevé (UAC). Légèrement permissif du point de vue sécurité. Redémarrage requis.'
       Apply='Invoke-W11BLinkedConnections'; Undo='Undo-W11BLinkedConnections' }
)

# --- Prereglages (cumulatifs, identiques aux niveaux du script v1) ----
$sync.Presets = [ordered]@{
    'ANSSI-Minimal'       = @('Socle')
    'ANSSI-Intermediaire' = @('Socle','Intermediaire')
    'ANSSI-Eleve'         = @('Socle','Intermediaire','Eleve')
    'ANSSI-Renforce'      = @('Socle','Intermediaire','Eleve','Renforce')
    'CIS-L1'              = @('Socle','Intermediaire')
    'CIS-L2'              = @('Socle','Intermediaire','Eleve')
}

function Get-W11BPresetIds {
    <# .SYNOPSIS Identifiants d'actions couverts par un prereglage. #>
    param([Parameter(Mandatory)][string]$Name)
    $cats = $sync.Presets[$Name]
    if (-not $cats) { throw "Prereglage inconnu : $Name" }
    return @($sync.Catalog | Where-Object { $cats -contains $_.Category } | ForEach-Object { $_.Id })
}

# =====================================================================
# FONCTIONS - RUNSPACES
# ---------------------------------------------------------------------
# Pattern WinUtil : un RunspacePool dont l'InitialSessionState contient
# (a) la variable $sync, (b) toutes les fonctions W11B*. Le thread UI ne
# fait ainsi JAMAIS de travail long ; il se contente de lire $sync.
# =====================================================================

function Initialize-W11BRunspacePool {
    <# .SYNOPSIS Cree (ou reutilise) le pool de runspaces partage. #>
    if ($sync.RunspacePool -and
        $sync.RunspacePool.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.RunspacePool
    }
    if ($sync.RunspacePool) { Close-W11BRunspacePool }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # (a) la hashtable synchronisee
    $iss.Variables.Add(
        (New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null))

    # (b) toutes les fonctions du script (filtrees sur le prefixe W11B)
    foreach ($f in (Get-ChildItem function:\ | Where-Object { $_.Name -match 'W11B' })) {
        $iss.Commands.Add(
            (New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry `
                -ArgumentList $f.Name, (Get-Content "function:\$($f.Name)")))
    }

    $sync.RunspacePool = [runspacefactory]::CreateRunspacePool(1, 2, $iss, $Host)
    $sync.RunspacePool.ApartmentState = 'MTA'
    $sync.RunspacePool.Open()
    return $sync.RunspacePool
}

function Close-W11BRunspacePool {
    <# .SYNOPSIS Ferme et libere le pool (evite les fuites de runspaces). #>
    if (-not $sync.RunspacePool) { return }
    try {
        $state = $sync.RunspacePool.RunspacePoolStateInfo.State
        if ($state -notin @([System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
                            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
                            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken)) {
            $sync.RunspacePool.Close()
        }
    } catch {
    } finally {
        try { $sync.RunspacePool.Dispose() } catch { }
        $sync.RunspacePool = $null
    }
}

function Start-W11BRunspace {
    <#
    .SYNOPSIS
        Lance un scriptblock dans le pool, sans bloquer le thread appelant.
    .DESCRIPTION
        La PowerShell instance est disposee automatiquement a la fin via
        RegisterWaitForSingleObject : sans cela, chaque execution laisserait
        un runspace et sa memoire derriere elle (fuite classique de ce pattern).
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [hashtable]$Parameters
    )

    # Le nettoyage doit se faire sur un thread du pool systeme, ou aucun
    # runspace PowerShell n'existe : un scriptblock converti en delegue y
    # echouerait ("There is no Runspace available"). On passe donc par une
    # petite classe C#, comme le fait WinUtil.
    if (-not ('W11BRunspaceCleanup' -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class W11BCleanupState
{
    public PowerShell Shell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class W11BRunspaceCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var s = state as W11BCleanupState;
        if (s == null || s.Shell == null || s.Handle == null) { return; }
        try { s.Shell.EndInvoke(s.Handle); }
        catch { }
        finally { s.Shell.Dispose(); }
    }
}
"@
    }

    Initialize-W11BRunspacePool | Out-Null

    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock)
    if ($Parameters) { foreach ($k in $Parameters.Keys) { [void]$ps.AddParameter($k, $Parameters[$k]) } }
    $ps.RunspacePool = $sync.RunspacePool

    $handle = $ps.BeginInvoke()

    # Nettoyage asynchrone : EndInvoke + Dispose des que le handle est signale.
    # Sans cela, chaque execution laisserait derriere elle une instance
    # PowerShell et sa memoire (fuite classique de ce pattern).
    $state = New-Object W11BCleanupState
    $state.Shell  = $ps
    $state.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject(
        $handle.AsyncWaitHandle, [W11BRunspaceCleanup]::Callback, $state, -1, $true) | Out-Null

    return $handle
}

# =====================================================================
# XAML - Interface WPF (here-string litteral : aucun fichier externe)
# ---------------------------------------------------------------------
# Charge par [Windows.Markup.XamlReader]::Load(). Contraintes PowerShell :
#   * pas d'attribut x:Class, pas de code-behind
#   * pas de Click="..." dans le XAML (on lie avec Add_Click cote script)
#   * les listes d'actions ne sont PAS ecrites ici : elles sont GENEREES
#     depuis $sync.Catalog (voir Add-W11BActionRow)
# =====================================================================

$inputXAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Win11-Baseline"
    Height="750" Width="1100" MinHeight="620" MinWidth="960"
    WindowStartupLocation="CenterScreen"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True"
    TextOptions.TextFormattingMode="Display"
    FontFamily="Segoe UI" FontSize="13"
    Background="#16171A">

  <Window.Resources>

    <!-- ============ PALETTE (dark theme facon WinUtil) ============ -->
    <SolidColorBrush x:Key="BgWindow"    Color="#16171A"/>
    <SolidColorBrush x:Key="BgSidebar"   Color="#1B1C1F"/>
    <SolidColorBrush x:Key="BgPanel"     Color="#1E2024"/>
    <SolidColorBrush x:Key="BgCard"      Color="#24262B"/>
    <SolidColorBrush x:Key="BgHover"     Color="#2A2D33"/>
    <SolidColorBrush x:Key="Accent"      Color="#3B82F6"/>
    <SolidColorBrush x:Key="AccentHover" Color="#60A5FA"/>
    <SolidColorBrush x:Key="Fg"          Color="#E7E9EE"/>
    <SolidColorBrush x:Key="FgMuted"     Color="#9AA0AA"/>
    <SolidColorBrush x:Key="BorderCol"   Color="#31343B"/>
    <SolidColorBrush x:Key="OkCol"       Color="#22C55E"/>
    <SolidColorBrush x:Key="WarnCol"     Color="#F59E0B"/>
    <SolidColorBrush x:Key="DangerCol"   Color="#EF4444"/>

    <!-- ============ Barres de defilement sombres ============ -->
    <Style TargetType="{x:Type Thumb}" x:Key="ScrollThumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Thumb}">
            <Border CornerRadius="4" Background="#3E424B" Margin="3,0"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Info-bulles ============ -->
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#101114"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderCol}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="MaxWidth" Value="440"/>
      <Setter Property="ContentTemplate">
        <Setter.Value>
          <DataTemplate>
            <TextBlock Text="{Binding}" TextWrapping="Wrap" Foreground="#E7E9EE"/>
          </DataTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Textes ============ -->
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource FgMuted}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="21"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>

    <!-- ============ Boutons ============ -->
    <Style TargetType="Button" x:Key="BtnBase">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Background" Value="#2C2F36"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderCol}"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="6"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#383C45"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#22252B"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.4"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button" x:Key="BtnAccent" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Padding" Value="26,11"/>
    </Style>

    <Style TargetType="Button" x:Key="BtnSmall" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <!-- ============ Interrupteur (toggle switch) ============ -->
    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid Grid.Column="0" Width="42" Height="22" VerticalAlignment="Center">
                <Border x:Name="Track" CornerRadius="11" Background="#3A3E46"
                        BorderBrush="#4A4F59" BorderThickness="1"/>
                <Border x:Name="Knob" Width="16" Height="16" CornerRadius="8" Background="#B7BCC6"
                        HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0,0,0"/>
              </Grid>
              <ContentPresenter Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#3B82F6"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="#3B82F6"/>
                <Setter TargetName="Knob"  Property="Background" Value="#FFFFFF"/>
                <Setter TargetName="Knob"  Property="Margin" Value="23,0,0,0"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#60A5FA"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Champs de saisie ============ -->
    <Style TargetType="TextBox" x:Key="Field">
      <Setter Property="Background" Value="#15171A"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderCol}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Style.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="PasswordBox" x:Key="FieldPwd">
      <Setter Property="Background" Value="#15171A"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderCol}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Style.Triggers>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- ============ ComboBox sombre ============ -->
    <Style x:Key="CmbToggle" TargetType="ToggleButton">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border Background="#15171A" BorderBrush="#31343B" BorderThickness="1" CornerRadius="3">
              <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"
                    Data="M 0 0 L 4 4 L 8 0 Z" Fill="#9AA0AA"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox" x:Key="Cmb">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Style="{StaticResource CmbToggle}" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter Margin="10,0,28,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}"
                                TextElement.Foreground="{TemplateBinding Foreground}"
                                IsHitTestVisible="False"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#1E2024" BorderBrush="#31343B" BorderThickness="1"
                        MinWidth="{TemplateBinding ActualWidth}" MaxHeight="260">
                  <ScrollViewer><StackPanel IsItemsHost="True"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A2D33"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ RadioButton ============ -->
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,18,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Grid Width="16" Height="16" VerticalAlignment="Center">
                <Ellipse x:Name="Outer" Stroke="#5A606B" StrokeThickness="1.5" Fill="#15171A"/>
                <Ellipse x:Name="Dot" Width="8" Height="8" Fill="Transparent"/>
              </Grid>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Outer" Property="Stroke" Value="#3B82F6"/>
                <Setter TargetName="Dot" Property="Fill" Value="#3B82F6"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Barre de progression arrondie ============ -->
    <Style TargetType="ProgressBar" x:Key="Bar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="4" Background="#2A2D33" BorderBrush="#31343B" BorderThickness="1">
              <Grid ClipToBounds="True">
                <Rectangle x:Name="PART_Track"/>
                <Rectangle x:Name="PART_Indicator" HorizontalAlignment="Left" RadiusX="4" RadiusY="4"
                           Fill="{TemplateBinding Foreground}"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Navigation laterale (TabControl) ============ -->
    <Style x:Key="SideTab" TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" BorderThickness="3,0,0,0"
                    BorderBrush="Transparent" Padding="15,11" Margin="0,1"
                    TextElement.Foreground="#B9BEC7">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#232529"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A2D33"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Bd" Property="TextElement.Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="238"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Background="{StaticResource BgSidebar}"
                      BorderBrush="{StaticResource BorderCol}" BorderThickness="0,0,1,0">
                <StackPanel IsItemsHost="True" Margin="0,10"/>
              </Border>
              <ContentPresenter Grid.Column="1" ContentSource="SelectedContent"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ============ Cartes / sections de formulaire ============ -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BgCard}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderCol}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>

  </Window.Resources>

  <!-- =================== MISE EN PAGE =================== -->
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>   <!-- 0 : en-tete -->
      <RowDefinition Height="*"/>      <!-- 1 : navigation+contenu -->
      <RowDefinition Height="Auto"/>   <!-- 2 : progression -->
      <RowDefinition Height="190"/>    <!-- 3 : journal -->
      <RowDefinition Height="Auto"/>   <!-- 4 : pied de page -->
    </Grid.RowDefinitions>

    <!-- 0 : EN-TETE -->
    <Border Grid.Row="0" Background="{StaticResource BgPanel}"
            BorderBrush="{StaticResource BorderCol}" BorderThickness="0,0,0,1" Padding="22,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="Bienvenue sur Win11-Baseline" Style="{StaticResource H1}"/>
            <Border Background="#2A2D33" CornerRadius="4" Padding="7,2" Margin="12,4,0,0" VerticalAlignment="Center">
              <TextBlock x:Name="LblVersion" Text="v0.0.0" Foreground="#9AA0AA" FontSize="12"/>
            </Border>
          </StackPanel>
          <TextBlock x:Name="LblHost" Style="{StaticResource Muted}" Margin="0,4,0,0"
                     Text="Poste : ...   |   Utilisateur : ..."/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="BdgAdmin" Background="#14331F" BorderBrush="#22C55E" BorderThickness="1"
                  CornerRadius="14" Padding="12,5">
            <TextBlock x:Name="LblAdmin" Text="Administrateur" Foreground="#22C55E" FontWeight="SemiBold" FontSize="12"/>
          </Border>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 1 : NAVIGATION LATERALE + CONTENU -->
    <TabControl Grid.Row="1" x:Name="Nav">

      <!-- ========== Onglet : Systeme et reseau (formulaires) ========== -->
      <TabItem Style="{StaticResource SideTab}" Header="Système et réseau">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="{StaticResource BgWindow}">
          <StackPanel Margin="22">

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Sauvegarde préalable" Style="{StaticResource H2}"/>
                <CheckBox x:Name="ChkRestorePoint" Style="{StaticResource ToggleSwitch}" Margin="0,8,0,0"
                          Content="Créer un point de restauration avant application"/>
                <TextBlock Style="{StaticResource Muted}" Margin="54,6,0,0" FontSize="12"
                           Text="Recommandé : permet de revenir en arrière via la Restauration du système si une mesure casse un usage."/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Configuration IP" Style="{StaticResource H2}"/>
                <CheckBox x:Name="ChkIP" Style="{StaticResource ToggleSwitch}" Margin="0,8,0,12"
                          Content="Configurer l'adressage IP de ce poste"/>
                <Grid x:Name="GrpIP" IsEnabled="False" Margin="54,0,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Carte réseau" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <ComboBox  Grid.Row="0" Grid.Column="1" x:Name="CmbAdapter" Style="{StaticResource Cmb}" Margin="0,0,0,8"/>
                  <TextBlock Grid.Row="1" Grid.Column="0" Text="Mode" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,8">
                    <RadioButton x:Name="RbStatic" GroupName="IpMode" Content="Statique" IsChecked="True"/>
                    <RadioButton x:Name="RbDhcp"   GroupName="IpMode" Content="Automatique (DHCP)"/>
                  </StackPanel>
                  <TextBlock Grid.Row="2" Grid.Column="0" Text="Adresse IP" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="2" Grid.Column="1" x:Name="TxtIP" Style="{StaticResource Field}" Margin="0,0,0,8"/>
                  <TextBlock Grid.Row="3" Grid.Column="0" Text="Masque (CIDR)" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="3" Grid.Column="1" x:Name="TxtPrefix" Style="{StaticResource Field}" Text="24" Margin="0,0,0,8"/>
                  <TextBlock Grid.Row="4" Grid.Column="0" Text="Passerelle" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="4" Grid.Column="1" x:Name="TxtGateway" Style="{StaticResource Field}" Margin="0,0,0,8"/>
                  <TextBlock Grid.Row="5" Grid.Column="0" Text="DNS" VerticalAlignment="Center"/>
                  <TextBox   Grid.Row="5" Grid.Column="1" x:Name="TxtDns" Style="{StaticResource Field}"
                             ToolTip="Plusieurs serveurs : séparez-les par une virgule."/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Identité du poste" Style="{StaticResource H2}"/>
                <CheckBox x:Name="ChkRename" Style="{StaticResource ToggleSwitch}" Margin="0,8,0,10"
                          Content="Renommer le poste"/>
                <Grid x:Name="GrpRename" IsEnabled="False" Margin="54,0,0,14">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Nouveau nom" VerticalAlignment="Center"/>
                  <TextBox Grid.Column="1" x:Name="TxtNewName" Style="{StaticResource Field}"
                           ToolTip="15 caractères maximum, lettres / chiffres / tirets."/>
                </Grid>

                <CheckBox x:Name="ChkJoin" Style="{StaticResource ToggleSwitch}" Margin="0,0,0,10"
                          Content="Joindre un domaine Active Directory"/>
                <Grid x:Name="GrpJoin" IsEnabled="False" Margin="54,0,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Domaine" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="0" Grid.Column="1" x:Name="TxtDomain" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="Exemple : monentreprise.local"/>
                  <TextBlock Grid.Row="1" Text="Compte autorisé" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TxtJoinUser" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="DOMAINE\Administrateur ou admin@domaine.local"/>
                  <TextBlock Grid.Row="2" Text="Mot de passe" VerticalAlignment="Center"/>
                  <PasswordBox Grid.Row="2" Grid.Column="1" x:Name="PwdJoin" Style="{StaticResource FieldPwd}"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Lecteur réseau" Style="{StaticResource H2}"/>
                <CheckBox x:Name="ChkDrive" Style="{StaticResource ToggleSwitch}" Margin="0,8,0,12"
                          Content="Mapper un lecteur réseau (persistant)"/>
                <Grid x:Name="GrpDrive" IsEnabled="False" Margin="54,0,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Partages publiés" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <Grid Grid.Row="0" Grid.Column="1" Margin="0,0,0,8">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <ComboBox x:Name="CmbShares" Style="{StaticResource Cmb}"/>
                    <Button Grid.Column="1" x:Name="BtnDiscoverAD" Style="{StaticResource BtnSmall}" Margin="8,0,0,0"
                            Content="Rechercher dans l'AD"
                            ToolTip="Interroge l'annuaire (objets volume) sans RSAT. Nécessite que le poste soit déjà membre du domaine."/>
                  </Grid>
                  <TextBlock Grid.Row="1" Text="Chemin UNC" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <TextBox   Grid.Row="1" Grid.Column="1" x:Name="TxtUnc" Style="{StaticResource Field}" Margin="0,0,0,8"
                             ToolTip="\\serveur\partage"/>
                  <TextBlock Grid.Row="2" Text="Lettre" VerticalAlignment="Center" Margin="0,0,0,8"/>
                  <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,8">
                    <ComboBox x:Name="CmbLetter" Style="{StaticResource Cmb}" Width="80"/>
                    <CheckBox x:Name="ChkReplace" Style="{StaticResource ToggleSwitch}" Margin="20,0,0,0"
                              Content="Remplacer si déjà utilisée"/>
                  </StackPanel>
                  <CheckBox Grid.Row="3" Grid.ColumnSpan="2" x:Name="ChkDriveCred" Style="{StaticResource ToggleSwitch}"
                            Margin="0,0,0,10" Content="Utiliser des identifiants spécifiques"/>
                  <Grid Grid.Row="4" Grid.ColumnSpan="2" x:Name="GrpDriveCred" IsEnabled="False">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="150"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Utilisateur" VerticalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBox   Grid.Row="0" Grid.Column="1" x:Name="TxtDriveUser" Style="{StaticResource Field}" Margin="0,0,0,8"/>
                    <TextBlock Grid.Row="1" Text="Mot de passe" VerticalAlignment="Center"/>
                    <PasswordBox Grid.Row="1" Grid.Column="1" x:Name="PwdDrive" Style="{StaticResource FieldPwd}"/>
                  </Grid>
                </Grid>

                <CheckBox x:Name="ChkLinked" Style="{StaticResource ToggleSwitch}" Margin="0,16,0,0"
                          Content="EnableLinkedConnections (lecteurs visibles en session standard)"/>
              </StackPanel>
            </Border>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ========== Onglets de securite (contenu genere) ========== -->
      <TabItem Style="{StaticResource SideTab}" Header="Sécurité — Socle">
        <Grid Background="{StaticResource BgWindow}">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Padding="22,16,22,10" Background="{StaticResource BgWindow}">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Socle de sécurité" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" FontSize="12"
                           Text="Mesures à faible impact fonctionnel. Base de CIS Level 1 et d'ANSSI Minimal."/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnAllSocle"  Style="{StaticResource BtnSmall}" Content="Tout sélectionner"/>
                <Button x:Name="BtnNoneSocle" Style="{StaticResource BtnSmall}" Content="Tout désélectionner" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelSocle" Margin="22,0,22,22"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Style="{StaticResource SideTab}" Header="Sécurité — Intermédiaire">
        <Grid Background="{StaticResource BgWindow}">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Padding="22,16,22,10">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Renforcement intermédiaire" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" FontSize="12"
                           Text="Réseau d'entreprise standard. CIS L1 étendu / ANSSI Intermédiaire."/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnAllInter"  Style="{StaticResource BtnSmall}" Content="Tout sélectionner"/>
                <Button x:Name="BtnNoneInter" Style="{StaticResource BtnSmall}" Content="Tout désélectionner" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelIntermediaire" Margin="22,0,22,22"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Style="{StaticResource SideTab}" Header="Sécurité — Élevé">
        <Grid Background="{StaticResource BgWindow}">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Padding="22,16,22,10">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Renforcement élevé" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" FontSize="12"
                           Text="Données sensibles. CIS Level 2 / ANSSI Élevé. Vérifiez les mesures marquées."/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnAllEleve"  Style="{StaticResource BtnSmall}" Content="Tout sélectionner"/>
                <Button x:Name="BtnNoneEleve" Style="{StaticResource BtnSmall}" Content="Tout désélectionner" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelEleve" Margin="22,0,22,22"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <TabItem Style="{StaticResource SideTab}" Header="Sécurité — Renforcé">
        <Grid Background="{StaticResource BgWindow}">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border Grid.Row="0" Padding="22,16,22,10">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Renforcement maximal" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" FontSize="12"
                           Text="ANSSI Renforcé. Mesures les plus strictes : testez impérativement sur un poste pilote."/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnAllRenforce"  Style="{StaticResource BtnSmall}" Content="Tout sélectionner"/>
                <Button x:Name="BtnNoneRenforce" Style="{StaticResource BtnSmall}" Content="Tout désélectionner" Margin="8,0,0,0"/>
              </StackPanel>
            </Grid>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelRenforce" Margin="22,0,22,22"/>
          </ScrollViewer>
        </Grid>
      </TabItem>

      <!-- ========== Onglet : prereglages ========== -->
      <TabItem Style="{StaticResource SideTab}" Header="Préréglages">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Background="{StaticResource BgWindow}">
          <StackPanel Margin="22">
            <TextBlock Text="Préréglages par référentiel" Style="{StaticResource H2}"/>
            <TextBlock Style="{StaticResource Muted}" Margin="0,0,0,16" FontSize="12"
                       Text="Un clic coche les mesures du niveau choisi (les niveaux sont cumulatifs). Vous pouvez ensuite ajuster chaque mesure onglet par onglet avant d'appliquer."/>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="CIS Benchmark" Style="{StaticResource H2}"/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Button x:Name="BtnPresetCIS1" Style="{StaticResource BtnBase}" Content="Level 1 — Sécurité de base"
                          ToolTip="Socle + Intermédiaire : paramètres sûrs à faible impact fonctionnel."/>
                  <Button x:Name="BtnPresetCIS2" Style="{StaticResource BtnBase}" Content="Level 2 — Défense en profondeur" Margin="10,0,0,0"
                          ToolTip="L1 + mesures élevées : réservé aux environnements sensibles."/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="ANSSI BP-028" Style="{StaticResource H2}"/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Button x:Name="BtnPresetAnssi1" Style="{StaticResource BtnBase}" Content="Minimal"
                          ToolTip="Postes exposés à Internet avec données peu sensibles."/>
                  <Button x:Name="BtnPresetAnssi2" Style="{StaticResource BtnBase}" Content="Intermédiaire" Margin="10,0,0,0"
                          ToolTip="Postes en réseau d'entreprise standard."/>
                  <Button x:Name="BtnPresetAnssi3" Style="{StaticResource BtnBase}" Content="Élevé" Margin="10,0,0,0"
                          ToolTip="Données sensibles : RH, finance, R&amp;D."/>
                  <Button x:Name="BtnPresetAnssi4" Style="{StaticResource BtnBase}" Content="Renforcé" Margin="10,0,0,0"
                          ToolTip="OIV, défense. Mesures les plus strictes."/>
                </StackPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Déploiement automatisé" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,8,0,0" FontSize="12"
                           Text="Pour Intune / GPO / SCCM, le même fichier s'exécute sans interface :"/>
                <Border Background="#101114" BorderBrush="{StaticResource BorderCol}" BorderThickness="1"
                        CornerRadius="4" Padding="12,10" Margin="0,10,0,0">
                  <TextBlock x:Name="LblCliHint" FontFamily="Consolas" FontSize="12" Foreground="#9AA0AA"/>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Avertissement" Style="{StaticResource H2}" Foreground="#F59E0B"/>
                <TextBlock Style="{StaticResource Muted}" Margin="0,8,0,0" FontSize="12"
                           Text="Win11-Baseline applique un sous-ensemble représentatif de mesures inspirées de CIS et d'ANSSI BP-028. Ce n'est ni une implémentation exhaustive, ni une certification de conformité. Testez sur un poste pilote ; en production, privilégiez GPO ou Microsoft Intune."/>
              </StackPanel>
            </Border>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

    </TabControl>

    <!-- 2 : PROGRESSION -->
    <Border Grid.Row="2" Background="{StaticResource BgPanel}"
            BorderBrush="{StaticResource BorderCol}" BorderThickness="0,1,0,0" Padding="22,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Margin="0,0,20,0">
          <TextBlock x:Name="LblStep" Style="{StaticResource Muted}" FontSize="12" Text="En attente"/>
          <ProgressBar x:Name="Bar" Style="{StaticResource Bar}" Margin="0,6,0,0" Minimum="0" Maximum="100" Value="0"/>
        </StackPanel>
        <TextBlock Grid.Column="1" x:Name="LblCount" VerticalAlignment="Center"
                   Style="{StaticResource Muted}" FontSize="12" Text="0 / 0"/>
      </Grid>
    </Border>

    <!-- 3 : JOURNAL TEMPS REEL -->
    <Border Grid.Row="3" Background="#0F1013" BorderBrush="{StaticResource BorderCol}" BorderThickness="0,1,0,1">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="22,8,22,4">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="Journal" Foreground="#9AA0AA" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal">
            <Button x:Name="BtnOpenLog"  Style="{StaticResource BtnSmall}" Content="Ouvrir le fichier de log"/>
            <Button x:Name="BtnClearLog" Style="{StaticResource BtnSmall}" Content="Effacer" Margin="8,0,0,0"/>
          </StackPanel>
        </Grid>
        <TextBox Grid.Row="1" x:Name="LogBox" Margin="22,0,14,10"
                 Background="Transparent" Foreground="#C9CEd6" BorderThickness="0"
                 FontFamily="Consolas" FontSize="12"
                 IsReadOnly="True" IsReadOnlyCaretVisible="False"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="NoWrap"/>
      </Grid>
    </Border>

    <!-- 4 : PIED DE PAGE -->
    <Border Grid.Row="4" Background="{StaticResource BgPanel}" Padding="22,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="LblSelected" VerticalAlignment="Center"
                   Style="{StaticResource Muted}" Text="0 action sélectionnée"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnUndo" Style="{StaticResource BtnBase}" Content="Annuler la sélection"
                  ToolTip="Remet les mesures cochées à leur valeur par défaut Windows, lorsqu'une annulation est définie."/>
          <Button x:Name="BtnApply" Style="{StaticResource BtnAccent}" Content="Appliquer la baseline" Margin="12,0,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

  </Grid>
</Window>
'@

# =====================================================================
# GUI - Construction de l'interface
# ---------------------------------------------------------------------
# Regle absolue de ce pattern : TOUT ce qui suit s'execute sur le thread
# UI. Aucune commande longue ici ; elles partent en runspace (section
# LOGIQUE plus bas).
# =====================================================================

function New-W11BUIBadge {
    <# .SYNOPSIS Petite pastille coloree (risque, redemarrage). #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Foreground,
        [Parameter(Mandatory)][string]$Background,
        [Parameter(Mandatory)][string]$BorderColor
    )
    $conv = [System.Windows.Media.BrushConverter]::new()
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = $Text
    $tb.FontSize   = 11
    $tb.FontWeight = 'SemiBold'
    $tb.Foreground = $conv.ConvertFromString($Foreground)

    $b = New-Object System.Windows.Controls.Border
    $b.Background      = $conv.ConvertFromString($Background)
    $b.BorderBrush     = $conv.ConvertFromString($BorderColor)
    $b.BorderThickness = New-Object System.Windows.Thickness(1)
    $b.CornerRadius    = New-Object System.Windows.CornerRadius(10)
    $b.Padding         = New-Object System.Windows.Thickness(9,2,9,2)
    $b.Margin          = New-Object System.Windows.Thickness(8,0,0,0)
    $b.VerticalAlignment = 'Center'
    $b.Child           = $tb
    return $b
}

function Register-W11BUIToggle {
    <#
    .SYNOPSIS
        Associe un CheckBox a un identifiant du catalogue et branche la mise a
        jour du compteur de selection.
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Controls.CheckBox]$CheckBox,
        [Parameter(Mandatory)][string]$Id
    )
    $CheckBox.Tag = $Id
    $sync.Checkboxes[$Id] = $CheckBox
    $CheckBox.Add_Checked({   Update-W11BUISelectionCount })
    $CheckBox.Add_Unchecked({ Update-W11BUISelectionCount })
}

function Add-W11BUIActionRow {
    <#
    .SYNOPSIS
        Genere UNE ligne d'action (interrupteur + libelle + pastilles) et
        l'ajoute au panneau de sa categorie.
    .DESCRIPTION
        L'interface est produite a partir de $sync.Catalog : ajouter une
        mesure au catalogue suffit a la faire apparaitre dans la fenetre.
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Panel]$Panel,
        [Parameter(Mandatory)][hashtable]$Action
    )

    $card = New-Object System.Windows.Controls.Border
    $card.Background      = $sync.Form.FindResource('BgCard')
    $card.BorderBrush     = $sync.Form.FindResource('BorderCol')
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius    = New-Object System.Windows.CornerRadius(6)
    $card.Padding         = New-Object System.Windows.Thickness(14,11,14,11)
    $card.Margin          = New-Object System.Windows.Thickness(0,0,0,8)

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style   = $sync.Form.FindResource('ToggleSwitch')
    $cb.Content = $Action.Name
    $cb.ToolTip = $Action.Tip
    [System.Windows.Controls.Grid]::SetColumn($cb, 0)
    $grid.Children.Add($cb) | Out-Null

    $badges = New-Object System.Windows.Controls.StackPanel
    $badges.Orientation       = 'Horizontal'
    $badges.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($badges, 1)

    switch ($Action.Risk) {
        'Sensible' { $badges.Children.Add((New-W11BUIBadge -Text 'Sensible' -Foreground '#F59E0B' -Background '#33260C' -BorderColor '#F59E0B')) | Out-Null }
        'Eleve'    { $badges.Children.Add((New-W11BUIBadge -Text 'Risque eleve' -Foreground '#EF4444' -Background '#3A1616' -BorderColor '#EF4444')) | Out-Null }
    }
    if ($Action.Reboot) {
        $badges.Children.Add((New-W11BUIBadge -Text 'Redemarrage' -Foreground '#9AA0AA' -Background '#26282D' -BorderColor '#3E424B')) | Out-Null
    }
    $grid.Children.Add($badges) | Out-Null

    $card.Child = $grid
    $Panel.Children.Add($card) | Out-Null

    Register-W11BUIToggle -CheckBox $cb -Id $Action.Id
}

function Update-W11BUISelectionCount {
    <# .SYNOPSIS Rafraichit le compteur du pied de page. #>
    $n = @($sync.Checkboxes.Values | Where-Object { $_.IsChecked }).Count
    $mot = if ($n -gt 1) { 'actions sélectionnées' } else { 'action sélectionnée' }
    $sync.LblSelected.Text = "$n $mot"
}

function Get-W11BUISelectedIds {
    <# .SYNOPSIS Identifiants coches, dans l'ordre du catalogue. #>
    return @($sync.Catalog | Where-Object {
        $cb = $sync.Checkboxes[$_.Id]
        $cb -and $cb.IsChecked
    } | ForEach-Object { $_.Id })
}

function Set-W11BUICategory {
    <# .SYNOPSIS Coche ou decoche toutes les actions d'une categorie. #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][bool]$Value
    )
    foreach ($a in ($sync.Catalog | Where-Object { $_.Category -eq $Category })) {
        $cb = $sync.Checkboxes[$a.Id]
        if ($cb) { $cb.IsChecked = $Value }
    }
    Update-W11BUISelectionCount
}

function Set-W11BUIPreset {
    <# .SYNOPSIS Applique un prereglage : decoche tout, puis coche le niveau. #>
    param([Parameter(Mandatory)][string]$Name)
    foreach ($a in ($sync.Catalog | Where-Object { $_.Category -ne 'Systeme' })) {
        $cb = $sync.Checkboxes[$a.Id]
        if ($cb) { $cb.IsChecked = $false }
    }
    foreach ($id in (Get-W11BPresetIds -Name $Name)) {
        $cb = $sync.Checkboxes[$id]
        if ($cb) { $cb.IsChecked = $true }
    }
    # Le point de restauration est fortement recommande avec un prereglage.
    if ($sync.Checkboxes['SYS-RestorePoint']) { $sync.Checkboxes['SYS-RestorePoint'].IsChecked = $true }
    Update-W11BUISelectionCount
    Write-W11BLog -Level 'INFO' -Message "Préréglage '$Name' chargé : $((Get-W11BPresetIds -Name $Name).Count) mesure(s) cochée(s)."
}

# =====================================================================
# LOGIQUE - Collecte des formulaires, lancement, suivi, cloture
# =====================================================================

function Get-W11BUIFormData {
    <#
    .SYNOPSIS
        Lit les champs de saisie SUR LE THREAD UI et les depose dans
        $sync.FormData sous forme de donnees simples.
    .DESCRIPTION
        Point important du pattern : un runspace ne doit jamais lire un
        controle WPF (exception cross-thread). On fige donc les valeurs ici,
        avant de lancer l'execution. Retourne $null si une validation echoue.
    #>
    $data = @{}

    # --- Configuration IP --------------------------------------------
    if ($sync.Checkboxes['NET-IPConfig'].IsChecked) {
        $adapter = $sync.CmbAdapter.SelectedItem
        if (-not $adapter) { return @{ Error = "Sélectionnez une carte réseau." } }
        $mode = if ($sync.RbDhcp.IsChecked) { 'DHCP' } else { 'Static' }
        $entry = @{ InterfaceAlias = [string]$adapter; Mode = $mode }
        if ($mode -eq 'Static') {
            if (-not $sync.TxtIP.Text.Trim())     { return @{ Error = "Adresse IP manquante." } }
            if (-not $sync.TxtPrefix.Text.Trim()) { return @{ Error = "Masque CIDR manquant." } }
            $prefix = 0
            if (-not [int]::TryParse($sync.TxtPrefix.Text.Trim(), [ref]$prefix)) { return @{ Error = "Masque CIDR invalide." } }
            $entry.IPAddress    = $sync.TxtIP.Text.Trim()
            $entry.PrefixLength = $prefix
            $entry.Gateway      = $sync.TxtGateway.Text.Trim()
            $entry.Dns          = $sync.TxtDns.Text.Trim()
        }
        $data['NET-IPConfig'] = $entry
    }

    # --- Renommage ----------------------------------------------------
    if ($sync.Checkboxes['SYS-Rename'].IsChecked) {
        $n = $sync.TxtNewName.Text.Trim()
        if (-not $n) { return @{ Error = "Nouveau nom du poste manquant." } }
        $data['SYS-Rename'] = @{ NewName = $n }
    }

    # --- Jonction au domaine -----------------------------------------
    if ($sync.Checkboxes['SYS-DomainJoin'].IsChecked) {
        $dom  = $sync.TxtDomain.Text.Trim()
        $user = $sync.TxtJoinUser.Text.Trim()
        if (-not $dom)  { return @{ Error = "Nom du domaine manquant." } }
        if (-not $user) { return @{ Error = "Compte autorisé à joindre le domaine manquant." } }
        if ($sync.PwdJoin.SecurePassword.Length -eq 0) { return @{ Error = "Mot de passe du compte de jonction manquant." } }
        $entry = @{
            DomainName = $dom
            Credential = New-Object System.Management.Automation.PSCredential($user, $sync.PwdJoin.SecurePassword)
        }
        # Renommage + jonction : Add-Computer -NewName fait les deux en une fois.
        if ($sync.Checkboxes['SYS-Rename'].IsChecked) { $entry.NewName = $sync.TxtNewName.Text.Trim() }
        $data['SYS-DomainJoin'] = $entry
    }

    # --- Lecteur reseau -----------------------------------------------
    if ($sync.Checkboxes['NET-MapDrive'].IsChecked) {
        $unc = $sync.TxtUnc.Text.Trim()
        if (-not $unc) { return @{ Error = "Chemin UNC du partage manquant." } }
        if (-not $sync.CmbLetter.SelectedItem) { return @{ Error = "Lettre de lecteur manquante." } }
        $entry = @{
            Letter  = [string]$sync.CmbLetter.SelectedItem
            UncPath = $unc
            Replace = [bool]$sync.ChkReplace.IsChecked
        }
        if ($sync.ChkDriveCred.IsChecked) {
            $du = $sync.TxtDriveUser.Text.Trim()
            if (-not $du) { return @{ Error = "Utilisateur du partage manquant." } }
            $entry.Credential = New-Object System.Management.Automation.PSCredential($du, $sync.PwdDrive.SecurePassword)
        }
        $data['NET-MapDrive'] = $entry
    }

    return $data
}

function Start-W11BUIRun {
    <#
    .SYNOPSIS
        Prepare puis lance l'execution des actions cochees dans un runspace.
    .PARAMETER Undo
        Execute les fonctions d'annulation au lieu des fonctions d'application.
    #>
    param([switch]$Undo)

    if ($sync.Running) { return }

    $ids = Get-W11BUISelectedIds
    if ($ids.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "Aucune action sélectionnée.`n`nCochez au moins une mesure, ou chargez un préréglage depuis l'onglet Préréglages.",
            'Win11-Baseline', 'OK', 'Warning') | Out-Null
        return
    }

    if ($Undo) {
        $reversibles = @($ids | ForEach-Object { Get-W11BAction -Id $_ } | Where-Object { $_.Undo })
        if ($reversibles.Count -eq 0) {
            [System.Windows.MessageBox]::Show(
                "Aucune des actions sélectionnées ne dispose d'une annulation automatique.`n`nLes actions de type formulaire (IP, renommage, jonction de domaine, mappage) doivent être annulées manuellement.",
                'Win11-Baseline', 'OK', 'Warning') | Out-Null
            return
        }
        $ids = @($reversibles | ForEach-Object { $_.Id })
    }

    # --- Donnees de formulaire (lues sur le thread UI) ----------------
    $sync.FormData = @{}
    if (-not $Undo) {
        $form = Get-W11BUIFormData
        if ($form.Error) {
            [System.Windows.MessageBox]::Show($form.Error, 'Win11-Baseline - saisie incomplète', 'OK', 'Warning') | Out-Null
            return
        }
        $sync.FormData = $form
        # Renommage + jonction dans la meme passe : la jonction porte deja le
        # nouveau nom, on retire donc l'action de renommage isolee.
        if ($sync.FormData['SYS-DomainJoin'] -and $sync.FormData['SYS-DomainJoin'].NewName) {
            $ids = @($ids | Where-Object { $_ -ne 'SYS-Rename' })
            Write-W11BLog -Level 'INFO' -Message "Renommage intégré à la jonction de domaine (Add-Computer -NewName)."
        }
    }

    # --- Confirmation des mesures a risque ----------------------------
    $verbe = if ($Undo) { 'ANNULER' } else { 'APPLIQUER' }
    $risky = @($ids | ForEach-Object { Get-W11BAction -Id $_ } | Where-Object { $_.Risk -eq 'Eleve' })
    $msg   = "$verbe $($ids.Count) action(s) sur ce poste ?"
    if ($risky.Count -gt 0) {
        $msg += "`n`nMesures à RISQUE FONCTIONNEL ÉLEVÉ sélectionnées :`n"
        $msg += ($risky | ForEach-Object { "  - $($_.Name)" }) -join "`n"
        $msg += "`n`nTestez sur un poste pilote avant tout déploiement."
    }
    if ([System.Windows.MessageBox]::Show($msg, 'Win11-Baseline - confirmation', 'YesNo', 'Warning') -ne 'Yes') { return }

    # --- Bascule de l'interface en mode "execution" -------------------
    $sync.Cancelled     = $false
    $sync.Done          = $false
    $sync.Running       = $true
    $sync.Progress      = 0
    $sync.ProgressTotal = $ids.Count

    $sync.BtnApply.IsEnabled = $false
    $sync.BtnUndo.IsEnabled  = $false
    $sync.Nav.IsEnabled      = $false
    $sync.Bar.Value          = 0
    $sync.LblStep.Text       = 'Démarrage...'
    $sync.LblCount.Text      = "0 / $($ids.Count)"

    Start-W11BRunspace -ScriptBlock {
        param($Ids, $Undo)
        try {
            Invoke-W11BSelection -Ids $Ids -Undo:$Undo
        } catch {
            Write-W11BLog -Level 'ERR' -Message "Interruption de l'exécution : $($_.Exception.Message)"
        } finally {
            # Garantit que l'interface est toujours rendue a l'utilisateur,
            # meme si le moteur s'est arrete sur une erreur imprevue.
            $sync.Running = $false
            $sync.Done    = $true
        }
    } -Parameters @{ Ids = $ids; Undo = [bool]$Undo } | Out-Null
}

function Complete-W11BUIRun {
    <# .SYNOPSIS Remet l'interface en etat et presente le resume final. #>
    $sync.Done = $false
    $sync.BtnApply.IsEnabled = $true
    $sync.BtnUndo.IsEnabled  = $true
    $sync.Nav.IsEnabled      = $true
    $sync.Bar.Value          = 100

    $ok = @($sync.Results | Where-Object { $_.Status -eq 'OK' }).Count
    $ko = @($sync.Results | Where-Object { $_.Status -eq 'Error' }).Count
    $sk = @($sync.Results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $sync.LblStep.Text = "Terminé : $ok réussie(s), $ko échec(s)"

    $resume = "Exécution terminée.`n`n  Réussies : $ok`n  Échecs   : $ko`n  Ignorées : $sk"
    if ($ko -gt 0) {
        $resume += "`n`nDétail des échecs :`n"
        $resume += (@($sync.Results | Where-Object { $_.Status -eq 'Error' } |
                      ForEach-Object { "  - $($_.Id) : $($_.Message)" }) -join "`n")
    }
    $resume += "`n`nOuvrir le fichier de journal ?`n$($sync.LogFile)"

    if ([System.Windows.MessageBox]::Show($resume, 'Win11-Baseline - résumé', 'YesNo', 'Information') -eq 'Yes') {
        try { Start-Process notepad.exe -ArgumentList "`"$($sync.LogFile)`"" } catch { }
    }

    if ($sync.NeedReboot) {
        $r = [System.Windows.MessageBox]::Show(
            "Un REDÉMARRAGE est nécessaire pour appliquer certains changements (nom du poste, jonction de domaine, LSASS PPL, VBS...).`n`nRedémarrer maintenant ?",
            'Win11-Baseline - redémarrage requis', 'YesNo', 'Warning')
        if ($r -eq 'Yes') {
            Write-W11BLog -Level 'WARN' -Message 'Redémarrage demandé par l''utilisateur.'
            Restart-Computer -Force
        }
    }
}

function Start-W11BGui {
    <#
    .SYNOPSIS
        Charge le XAML, cable l'interface et affiche la fenetre (bloquant).
    #>

    # --- Assemblies WPF ------------------------------------------------
    # PresentationFramework tire PresentationCore et WindowsBase. On charge
    # aussi System.Xaml, requis par XamlReader sur certaines installations.
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore      -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase           -ErrorAction Stop
    Add-Type -AssemblyName System.Xaml           -ErrorAction SilentlyContinue

    # --- Chargement du XAML -------------------------------------------
    [xml]$xamlDoc = $inputXAML
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    try {
        $sync.Form = [Windows.Markup.XamlReader]::Load($reader)
    } catch {
        Write-Host "Echec de l'analyse du XAML : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Rappel : aucun attribut Click= n'est autorise dans le XAML sous PowerShell." -ForegroundColor Yellow
        return $false
    }

    # --- Recuperation des controles nommes -----------------------------
    # On accepte Name= comme x:Name= (l'attribut x:Name est dans l'espace de
    # noms XAML, un simple //*[@Name] le manquerait).
    $xns = 'http://schemas.microsoft.com/winfx/2006/xaml'
    foreach ($node in $xamlDoc.SelectNodes('//*')) {
        $n = $node.GetAttribute('Name')
        if (-not $n) { $n = $node.GetAttribute('Name', $xns) }
        if ($n) { $sync[$n] = $sync.Form.FindName($n) }
    }

    # --- En-tete --------------------------------------------------------
    $sync.LblVersion.Text = "v$($sync.Version)"
    $mode = if ($script:IsInMemory) { 'en memoire (irm | iex)' } else { 'fichier local' }
    $sync.LblHost.Text = "Poste : $env:COMPUTERNAME   |   Utilisateur : $env:USERNAME   |   Execution : $mode"

    $isAdmin = Test-W11BAdmin
    $conv = [System.Windows.Media.BrushConverter]::new()
    if ($isAdmin) {
        $sync.LblAdmin.Text       = 'Administrateur'
        $sync.LblAdmin.Foreground = $conv.ConvertFromString('#22C55E')
        $sync.BdgAdmin.Background  = $conv.ConvertFromString('#14331F')
        $sync.BdgAdmin.BorderBrush = $conv.ConvertFromString('#22C55E')
    } else {
        $sync.LblAdmin.Text       = 'NON eleve - actions limitees'
        $sync.LblAdmin.Foreground = $conv.ConvertFromString('#EF4444')
        $sync.BdgAdmin.Background  = $conv.ConvertFromString('#3A1616')
        $sync.BdgAdmin.BorderBrush = $conv.ConvertFromString('#EF4444')
    }

    $sync.LblCliHint.Text = "&([scriptblock]::Create((irm '$($sync.RawUrl)'))) -NoGUI -Preset ANSSI-Eleve"

    # --- Generation des listes d'actions depuis le catalogue -----------
    $panels = @{
        'Socle'         = $sync.PanelSocle
        'Intermediaire' = $sync.PanelIntermediaire
        'Eleve'         = $sync.PanelEleve
        'Renforce'      = $sync.PanelRenforce
    }
    foreach ($a in $sync.Catalog) {
        if ($panels.ContainsKey($a.Category)) { Add-W11BUIActionRow -Panel $panels[$a.Category] -Action $a }
    }

    # --- Enregistrement des interrupteurs ecrits dans le XAML ----------
    $static = @{
        'SYS-RestorePoint' = $sync.ChkRestorePoint
        'NET-IPConfig'     = $sync.ChkIP
        'SYS-Rename'       = $sync.ChkRename
        'SYS-DomainJoin'   = $sync.ChkJoin
        'NET-MapDrive'     = $sync.ChkDrive
        'NET-LinkedConn'   = $sync.ChkLinked
    }
    foreach ($id in $static.Keys) {
        Register-W11BUIToggle -CheckBox $static[$id] -Id $id
        $act = Get-W11BAction -Id $id
        if ($act) { $static[$id].ToolTip = $act.Tip }
    }

    # --- Activation conditionnelle des formulaires ----------------------
    $sync.ChkIP.Add_Checked({          $sync.GrpIP.IsEnabled = $true })
    $sync.ChkIP.Add_Unchecked({        $sync.GrpIP.IsEnabled = $false })
    $sync.ChkRename.Add_Checked({      $sync.GrpRename.IsEnabled = $true })
    $sync.ChkRename.Add_Unchecked({    $sync.GrpRename.IsEnabled = $false })
    $sync.ChkJoin.Add_Checked({        $sync.GrpJoin.IsEnabled = $true })
    $sync.ChkJoin.Add_Unchecked({      $sync.GrpJoin.IsEnabled = $false })
    $sync.ChkDrive.Add_Checked({       $sync.GrpDrive.IsEnabled = $true })
    $sync.ChkDrive.Add_Unchecked({     $sync.GrpDrive.IsEnabled = $false })
    $sync.ChkDriveCred.Add_Checked({   $sync.GrpDriveCred.IsEnabled = $true })
    $sync.ChkDriveCred.Add_Unchecked({ $sync.GrpDriveCred.IsEnabled = $false })

    # --- Remplissage des listes deroulantes ------------------------------
    try {
        foreach ($ad in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $sync.CmbAdapter.Items.Add($ad.Name) | Out-Null
        }
        if ($sync.CmbAdapter.Items.Count -gt 0) { $sync.CmbAdapter.SelectedIndex = 0 }
    } catch { }

    $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $letters = @(90..69 | ForEach-Object { [string][char]$_ })      # Z ... E
    foreach ($l in $letters) { $sync.CmbLetter.Items.Add($l) | Out-Null }
    $free = @($letters | Where-Object { $used -notcontains $_ })
    $sync.CmbLetter.SelectedItem = if ($free.Count -gt 0) { $free[0] } else { 'Z' }

    # --- Boutons : selection par categorie -------------------------------
    $sync.BtnAllSocle.Add_Click({      Set-W11BUICategory -Category 'Socle'         -Value $true  })
    $sync.BtnNoneSocle.Add_Click({     Set-W11BUICategory -Category 'Socle'         -Value $false })
    $sync.BtnAllInter.Add_Click({      Set-W11BUICategory -Category 'Intermediaire' -Value $true  })
    $sync.BtnNoneInter.Add_Click({     Set-W11BUICategory -Category 'Intermediaire' -Value $false })
    $sync.BtnAllEleve.Add_Click({      Set-W11BUICategory -Category 'Eleve'         -Value $true  })
    $sync.BtnNoneEleve.Add_Click({     Set-W11BUICategory -Category 'Eleve'         -Value $false })
    $sync.BtnAllRenforce.Add_Click({   Set-W11BUICategory -Category 'Renforce'      -Value $true  })
    $sync.BtnNoneRenforce.Add_Click({  Set-W11BUICategory -Category 'Renforce'      -Value $false })

    # --- Boutons : prereglages -------------------------------------------
    $sync.BtnPresetCIS1.Add_Click({   Set-W11BUIPreset -Name 'CIS-L1' })
    $sync.BtnPresetCIS2.Add_Click({   Set-W11BUIPreset -Name 'CIS-L2' })
    $sync.BtnPresetAnssi1.Add_Click({ Set-W11BUIPreset -Name 'ANSSI-Minimal' })
    $sync.BtnPresetAnssi2.Add_Click({ Set-W11BUIPreset -Name 'ANSSI-Intermediaire' })
    $sync.BtnPresetAnssi3.Add_Click({ Set-W11BUIPreset -Name 'ANSSI-Eleve' })
    $sync.BtnPresetAnssi4.Add_Click({ Set-W11BUIPreset -Name 'ANSSI-Renforce' })

    # --- Boutons : journal -----------------------------------------------
    $sync.BtnOpenLog.Add_Click({
        try { Start-Process notepad.exe -ArgumentList "`"$($sync.LogFile)`"" }
        catch { [System.Windows.MessageBox]::Show("Impossible d'ouvrir le journal :`n$($sync.LogFile)", 'Win11-Baseline', 'OK', 'Warning') | Out-Null }
    })
    $sync.BtnClearLog.Add_Click({ $sync.LogBox.Clear() })

    # --- Bouton : decouverte des partages publies dans l'AD ---------------
    # Requete LDAP potentiellement lente -> runspace, jamais sur le thread UI.
    $sync.BtnDiscoverAD.Add_Click({
        if ($sync.Running) { return }
        $sync.BtnDiscoverAD.IsEnabled = $false
        $sync.ADShares.Clear()
        $sync.ADSharesReady = $false
        Write-W11BLog -Level 'INFO' -Message 'Recherche des partages publiés dans l''Active Directory...'
        Start-W11BRunspace -ScriptBlock {
            foreach ($s in @(Get-W11BADPublishedShares)) { $sync.ADShares.Add($s) }
            Write-W11BLog -Level 'INFO' -Message "$($sync.ADShares.Count) partage(s) publié(s) trouvé(s)."
            $sync.ADSharesReady = $true
        } | Out-Null
    })
    $sync.CmbShares.Add_SelectionChanged({
        $sel = $sync.CmbShares.SelectedItem
        if ($sel) { $sync.TxtUnc.Text = ([string]$sel -split '  ->  ')[-1] }
    })

    # --- Boutons : appliquer / annuler -------------------------------------
    $sync.BtnApply.Add_Click({ Start-W11BUIRun })
    $sync.BtnUndo.Add_Click({  Start-W11BUIRun -Undo })

    # --- Minuteur de rafraichissement (thread UI) --------------------------
    # Un seul point de contact entre l'execution et l'interface : on draine la
    # file de logs et on recopie l'etat de $sync. Cela evite les milliers de
    # Dispatcher.Invoke d'un affichage ligne par ligne, et tout risque de
    # blocage croise entre le runspace et le thread UI.
    $sync.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $sync.Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $sync.Timer.Add_Tick({
        $line = $null
        $n = 0
        while ($n -lt 200 -and $sync.LogQueue.TryDequeue([ref]$line)) {
            $sync.LogBox.AppendText($line + [Environment]::NewLine)
            $n++
        }
        if ($n -gt 0) { $sync.LogBox.ScrollToEnd() }

        if ($sync.Running -and $sync.ProgressTotal -gt 0) {
            $sync.Bar.Value     = [math]::Min(100, ($sync.Progress / $sync.ProgressTotal) * 100)
            $sync.LblCount.Text = "$($sync.Progress) / $($sync.ProgressTotal)  -  $($sync.ProgressTotal - $sync.Progress) restante(s)"
            $sync.LblStep.Text  = $sync.CurrentLabel
        }

        if ($sync.ADSharesReady) {
            $sync.ADSharesReady = $false
            $sync.CmbShares.Items.Clear()
            foreach ($s in $sync.ADShares) { $sync.CmbShares.Items.Add("$($s.Name)  ->  $($s.UNC)") | Out-Null }
            if ($sync.CmbShares.Items.Count -gt 0) { $sync.CmbShares.SelectedIndex = 0 }
            $sync.BtnDiscoverAD.IsEnabled = $true
        }

        if ($sync.Done) { Complete-W11BUIRun }
    })
    $sync.Timer.Start()

    # --- Fermeture : confirmation si une execution est en cours ------------
    $sync.Form.Add_Closing({
        if ($sync.Running) {
            $r = [System.Windows.MessageBox]::Show(
                "Une exécution est en cours.`n`nFermer maintenant peut laisser le poste dans un état partiellement configuré.`n`nFermer quand même ?",
                'Win11-Baseline', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $args[1].Cancel = $true; return }
            $sync.Cancelled = $true
        }
    })
    $sync.Form.Add_Closed({
        try { $sync.Timer.Stop() } catch { }
        Close-W11BRunspacePool
        [System.GC]::Collect()
    })

    Update-W11BUISelectionCount
    Write-W11BLog -Level 'INFO' -Message "Win11-Baseline v$($sync.Version) - $($sync.Catalog.Count) actions au catalogue."
    Write-W11BLog -Level 'INFO' -Message "Journal de cette session : $($sync.LogFile)"

    $sync.Form.ShowDialog() | Out-Null
    return $true
}

# =====================================================================
# LOGIQUE - POINT D'ENTREE
# =====================================================================

# --- Reconstruction des parametres pour une relance -------------------
$script:ArgList = @()
foreach ($p in $PSBoundParameters.GetEnumerator()) {
    $script:ArgList += if ($p.Value -is [switch] -and $p.Value)  { "-$($p.Key)" }
                       elseif ($p.Value -is [array])             { "-$($p.Key) $($p.Value -join ',')" }
                       elseif ($p.Value)                         { "-$($p.Key) '$($p.Value)'" }
}
$script:ArgString = ($script:ArgList -join ' ')

# --- Catalogue en clair (aucun droit requis) --------------------------
if ($ListActions) {
    $sync.Catalog |
        Select-Object @{n='Id';e={$_.Id}}, @{n='Categorie';e={$_.Category}},
                      @{n='Risque';e={$_.Risk}}, @{n='Redemarrage';e={$_.Reboot}},
                      @{n='Libelle';e={$_.Name}} |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "Prereglages disponibles : $($sync.Presets.Keys -join ', ')" -ForegroundColor Cyan
    return
}

# =====================================================================
# 1. AUTO-ELEVATION
# ---------------------------------------------------------------------
# Point cle du pattern irm | iex : on ne peut pas relancer avec -File
# puisqu'aucun fichier .ps1 n'existe. On relance donc avec -Command en
# rejouant la meme commande de telechargement. -STA est indispensable :
# WPF n'accepte que ce modele de thread.
# =====================================================================
if (-not (Test-W11BAdmin)) {
    Write-Host "Droits administrateur requis : demande d'elevation (UAC)..." -ForegroundColor Yellow
    Write-Host "Une invite de controle de compte va s'afficher : cliquez sur 'Oui'." -ForegroundColor Yellow

    $relaunch = "-NoProfile -ExecutionPolicy Bypass -STA -Command `"$(Get-W11BRelaunchCommand -ExtraArgs $script:ArgString)`""
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "`n[ECHEC] Impossible d'obtenir les droits administrateur." -ForegroundColor Red
        Write-Host "  - l'invite UAC a ete refusee, ou" -ForegroundColor Red
        Write-Host "  - votre compte n'est pas administrateur de ce poste." -ForegroundColor Red
        return
    }
    # 'return' et non 'exit' : en mode irm | iex le script tourne DANS la
    # console de l'utilisateur, qu'un 'exit' fermerait.
    Start-Sleep -Seconds 1
    return
}

# =====================================================================
# 2a. MODE SANS INTERFACE (-NoGUI / -CLI) : deploiement Intune / GPO
# =====================================================================
if ($NoGUI) {
    $sync.ConsoleEcho = $true
    Write-W11BLog -Level 'STEP' -Message "Win11-Baseline v$($sync.Version) - mode sans interface"

    $ids = @()
    if ($Preset)  { $ids += Get-W11BPresetIds -Name $Preset }
    if ($Actions) { $ids += $Actions }
    $ids = @($ids | Select-Object -Unique)

    if ($ids.Count -eq 0) {
        Write-Host "Rien a faire : precisez -Preset et/ou -Actions." -ForegroundColor Yellow
        Write-Host "Catalogue complet : -ListActions" -ForegroundColor Yellow
        return
    }

    $inconnus = @($ids | Where-Object { -not (Get-W11BAction -Id $_) })
    if ($inconnus.Count -gt 0) {
        Write-W11BLog -Level 'ERR' -Message "Identifiant(s) inconnu(s) : $($inconnus -join ', ')"
        exit 2
    }

    # Les actions de type formulaire exigent des saisies : elles sont hors
    # de portee d'un deploiement non interactif et sont donc ecartees.
    $forms = @($ids | ForEach-Object { Get-W11BAction -Id $_ } | Where-Object { $_.Kind -eq 'Form' })
    if ($forms.Count -gt 0) {
        Write-W11BLog -Level 'WARN' -Message "Ignorees (saisie requise, indisponible sans interface) : $(($forms | ForEach-Object { $_.Id }) -join ', ')"
        $ids = @($ids | Where-Object { $f = Get-W11BAction -Id $_; $f.Kind -ne 'Form' })
    }

    Invoke-W11BSelection -Ids $ids

    $ko = @($sync.Results | Where-Object { $_.Status -eq 'Error' }).Count
    if ($sync.NeedReboot) { Write-Host "REDEMARRAGE REQUIS." -ForegroundColor Yellow }
    exit ([int]($ko -gt 0))
}

# =====================================================================
# 2b. MODE GRAPHIQUE (defaut)
# ---------------------------------------------------------------------
# WPF impose un thread STA. En mode irm | iex depuis une console MTA
# (rare, mais possible via -MTA ou certains hotes), on se relance.
# =====================================================================
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "WPF requiert un thread STA : relance de la fenetre..." -ForegroundColor Yellow
    $cmd = "-NoProfile -ExecutionPolicy Bypass -STA -Command `"$(Get-W11BRelaunchCommand -ExtraArgs $script:ArgString)`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd
    return
}

try { $Host.UI.RawUI.WindowTitle = 'Win11-Baseline' } catch { }

try {
    if (-not (Start-W11BGui)) {
        Write-Host "L'interface graphique n'a pas pu demarrer." -ForegroundColor Red
        Write-Host "Repli possible : relancez avec -NoGUI -Preset <niveau>." -ForegroundColor Yellow
    }
} catch {
    Write-Host "`nErreur inattendue : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Ligne $($_.InvocationInfo.ScriptLineNumber) : $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkYellow
    Write-Host "Journal : $($sync.LogFile)" -ForegroundColor Yellow
} finally {
    Close-W11BRunspacePool
    [System.GC]::Collect()
}
