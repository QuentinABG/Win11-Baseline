#Requires -Version 5.1
# =====================================================================
# SCRIPT D'INITIALISATION / DURCISSEMENT POSTE CLIENT WINDOWS 11
# (MODE 100% INTERACTIF)
# ---------------------------------------------------------------------
# Sections proposees (chacune optionnelle) :
#   1 - Configuration IP complete (carte, IP/CIDR, passerelle, DNS)
#   2 - Renommage du poste + jonction a un domaine Active Directory
#       (identifiants saisis dans la console OU via une fenetre popup)
#   3 - Mappage de lecteur(s) reseau : decouverte des partages PUBLIES dans
#       l'AD (objets 'volume', via System.DirectoryServices - sans RSAT) ou
#       saisie manuelle d'un chemin UNC, puis mapping persistant.
#   4 - Durcissement (Hardening) de Windows 11 :
#         * Referentiel CIS Benchmark  -> niveaux L1 / L2
#         * Referentiel ANSSI BP-028   -> niveaux Minimal / Intermediaire /
#           Eleve / Renforce
#       Selection par numero, avec description de chaque niveau.
# ---------------------------------------------------------------------
# STYLE : memes helpers de saisie stricte, memes couleurs et memes
#         recapitulatifs (Show-StepSummary) que le script Windows Server.
# ---------------------------------------------------------------------
# REPRISE APRES REDEMARRAGE (comme le script serveur) :
#   L'avancement est sauvegarde dans %ProgramData%\Init-WindowsClient11\state.json.
#   Au demarrage, si un etat est present, le script propose de REPRENDRE en
#   sautant les etapes deja realisees. Lorsqu'un redemarrage est declenche par
#   le script (ex: apres jonction au domaine), une tache planifiee "a l'ouverture
#   de session" relance automatiquement le script pour poursuivre. En fin de
#   parcours complet, l'etat et la tache sont supprimes.
# ---------------------------------------------------------------------
# AVERTISSEMENT IMPORTANT :
#   Le module de durcissement applique un SOUS-ENSEMBLE representatif et
#   raisonnablement sur de mesures inspirees de CIS et ANSSI BP-028.
#   Il NE constitue PAS une implementation exhaustive ni une certification
#   de conformite. Testez TOUJOURS sur un poste pilote avant tout deploiement
#   de masse ; en production, privilegiez GPO / Microsoft Intune.
# ---------------------------------------------------------------------
# NB : pas de "#Requires -RunAsAdministrator" -> le script s'auto-eleve plus bas.
# =====================================================================

# =====================================================================
#                       FONCTIONS UTILITAIRES
# =====================================================================

# --- Lecture stricte d'une reponse Oui/Non ---
function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question)
    while ($true) {
        $r = Read-Host $Question
        if ($r -match '^[OoNn]$') {
            return ($r -eq 'O' -or $r -eq 'o')
        }
        Write-Host "  -> Reponse invalide. Merci de repondre uniquement par 'O' (Oui) ou 'N' (Non)." -ForegroundColor Red
    }
}

# --- Lecture stricte d'un entier positif ---
function Read-IntStrict {
    param([Parameter(Mandatory)][string]$Question)
    while ($true) {
        $val = Read-Host $Question
        $result = 0
        if ([int]::TryParse($val, [ref]$result) -and $result -ge 0) {
            return $result
        }
        Write-Host "  -> Valeur invalide. Merci de saisir un nombre entier positif." -ForegroundColor Red
    }
}

# --- Lecture stricte d'une chaine non vide ---
function Read-NonEmpty {
    param([Parameter(Mandatory)][string]$Question)
    while ($true) {
        $val = Read-Host $Question
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
        Write-Host "  -> Saisie vide non autorisee, merci de reessayer." -ForegroundColor Red
    }
}

# --- Lecture stricte d'un nom NetBIOS de poste (1-15 car., alphanum + tiret, pas tout numerique) ---
function Read-ComputerName {
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string]$Current
    )
    while ($true) {
        $name = Read-Host "$Question (ou Entree pour conserver '$Current')"
        if ([string]::IsNullOrWhiteSpace($name)) { return $Current }
        $name = $name.Trim()
        if ($name.Length -gt 15) {
            Write-Host "  -> Nom trop long (15 caracteres NetBIOS maximum)." -ForegroundColor Red
            continue
        }
        if ($name -notmatch '^[A-Za-z0-9-]+$') {
            Write-Host "  -> Caracteres invalides. Utilisez uniquement lettres, chiffres et tirets." -ForegroundColor Red
            continue
        }
        if ($name -match '^\d+$') {
            Write-Host "  -> Un nom entierement numerique n'est pas autorise." -ForegroundColor Red
            continue
        }
        return $name
    }
}

# --- Affiche un recapitulatif standardise a la fin de chaque etape ---
function Show-StepSummary {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines
    )
    Write-Host "`n----------- RECAPITULATIF ETAPE : $Title -----------" -ForegroundColor Green
    if ($Lines -and $Lines.Count -gt 0) {
        foreach ($l in $Lines) { Write-Host "  - $l" }
    } else {
        Write-Host "  (aucune action realisee durant cette etape)" -ForegroundColor DarkGray
    }
    Write-Host "-----------------------------------------------------------`n" -ForegroundColor Green
}

# --- Recupere les identifiants pour la jonction au domaine (console OU popup) ---
function Get-JoinCredential {
    Write-Host "Comment souhaitez-vous fournir les identifiants du domaine ?" -ForegroundColor Cyan
    Write-Host "  [1] Saisie directe dans la console PowerShell"
    Write-Host "  [2] Fenetre popup Windows (Get-Credential)"
    while ($true) {
        $m = Read-Host "  -> Votre choix (1/2)"
        switch ($m.Trim()) {
            '1' {
                $u = Read-NonEmpty "  Nom d'utilisateur (ex: DOMAINE\\Administrateur ou admin@domaine.local)"
                $p = Read-Host "  Mot de passe" -AsSecureString
                return (New-Object System.Management.Automation.PSCredential($u, $p))
            }
            '2' {
                return (Get-Credential -Message "Identifiants d'un compte autorise a joindre le domaine")
            }
            default { Write-Host "  -> Choix invalide (tapez 1 ou 2)." -ForegroundColor Red }
        }
    }
}

# =====================================================================
#   SAUVEGARDE D'ETAT + REPRISE APRES REDEMARRAGE (comme le script serveur)
# =====================================================================
# L'etat des etapes deja realisees est enregistre dans un fichier JSON.
# Au demarrage, si un etat est present, le script propose de REPRENDRE (en
# sautant les etapes deja faites). Lors d'un redemarrage declenche par le
# script, une tache planifiee "a l'ouverture de session" relance le script
# pour reprendre automatiquement. En fin de parcours, l'etat est efface et
# la tache supprimee.
$script:StateDir       = Join-Path $env:ProgramData 'Init-WindowsClient11'
$script:StateFile      = Join-Path $script:StateDir 'state.json'
$script:ResumeTaskName = 'Init-WindowsClient11-Resume'

# --- Lit l'etat sauvegarde (ou $null s'il n'existe pas / illisible) ---
function Get-InitState {
    if (Test-Path $script:StateFile) {
        try { return (Get-Content -Raw -Path $script:StateFile -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

# --- Enregistre l'etat courant sur disque ---
function Save-InitState {
    param([Parameter(Mandatory)]$State)
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
        $State.Updated = (Get-Date).ToString('s')
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StateFile -Encoding UTF8
    } catch {
        Write-Host "  -> (Etat non enregistre : $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

# --- Cree un objet d'etat vierge ---
function New-InitState {
    param([string]$ScriptPath)
    return [PSCustomObject]@{
        IPDone        = $false
        DomainDone    = $false
        DriveDone     = $false
        HardeningDone = $false
        ScriptPath    = $ScriptPath
        Updated       = (Get-Date).ToString('s')
    }
}

# --- Programme la reprise automatique du script a la prochaine ouverture de session ---
function Register-ResumeTask {
    param([Parameter(Mandatory)][string]$ScriptPath)
    try {
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                        -RunLevel Highest -LogonType Interactive
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $script:ResumeTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# --- Supprime la tache de reprise (si presente) ---
function Unregister-ResumeTask {
    try { Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
}

# --- Efface l'etat + supprime la tache de reprise (fin de parcours) ---
function Clear-InitState {
    try { if (Test-Path $script:StateFile) { Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue } } catch {}
    Unregister-ResumeTask
}

# --- Ecrit une valeur de registre "politique locale" (cree le chemin au besoin) ---
function Set-HardeningRegistry {
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

# --- Decouvre les partages PUBLIES dans l'Active Directory (objets 'volume') ---
# Utilise System.DirectoryServices (natif .NET) : aucun besoin de RSAT / module AD.
# Ne remonte QUE les partages explicitement publies dans l'annuaire (attribut uNCName).
# Renvoie un tableau d'objets { Name ; UNC ; Description }. Tableau vide si echec/aucun.
function Get-ADPublishedShares {
    $results = @()
    try {
        $rootDSE = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $defaultNC = $rootDSE.Properties["defaultNamingContext"].Value
        if ([string]::IsNullOrWhiteSpace($defaultNC)) { return @() }

        $searchRoot = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$defaultNC")
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($searchRoot)
        $searcher.Filter = "(objectClass=volume)"   # partages publies dans l'AD
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
        return @()   # pas de domaine actif, pas de connectivite AD, jonction non encore effective...
    }
    return $results
}

# --- Mappe un/plusieurs lecteur(s) reseau (partages publies AD ou UNC manuel) ---
function Invoke-NetworkDrive {
    $recap = @()

    # Etat du domaine
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { $cs = $null }
    $partOfDomain = if ($cs) { [bool]$cs.PartOfDomain } else { $false }

    if ($partOfDomain) {
        Write-Host "Poste membre du domaine : $($cs.Domain)" -ForegroundColor Green
    } else {
        Write-Host "Ce poste n'est PAS (encore) membre d'un domaine actif." -ForegroundColor DarkYellow
        Write-Host "Si vous venez de le joindre a l'etape precedente, la jonction ne sera effective" -ForegroundColor DarkYellow
        Write-Host "qu'APRES REDEMARRAGE : la decouverte AD echouera d'ici la. Vous pouvez toutefois" -ForegroundColor DarkYellow
        Write-Host "mapper un lecteur via un chemin UNC manuel." -ForegroundColor DarkYellow
    }

    $another = $true
    while ($another) {
        Write-Host "`nSource du partage a mapper :" -ForegroundColor Cyan
        Write-Host "  [1] Decouverte auto des partages PUBLIES dans l'Active Directory"
        Write-Host "  [2] Saisie manuelle d'un chemin UNC (\\serveur\partage)"
        Write-Host "  [0] Terminer (ne plus mapper de lecteur)"
        $src = (Read-Host "  -> Votre choix").Trim()

        $unc = $null
        $label = $null

        if ($src -eq '0') {
            break
        }
        elseif ($src -eq '1') {
            Write-Host "Recherche des partages publies dans l'AD..." -ForegroundColor Gray
            $shares = @(Get-ADPublishedShares)
            if ($shares.Count -eq 0) {
                Write-Host "Aucun partage publie trouve (ou decouverte AD impossible pour l'instant)." -ForegroundColor DarkYellow
                if (Read-YesNo "Saisir un chemin UNC manuellement a la place ? (O/N)") {
                    $unc = Read-NonEmpty "Chemin UNC (\\serveur\partage)"
                } else { continue }
            } else {
                Write-Host "Partages publies dans l'AD :" -ForegroundColor Cyan
                for ($i = 0; $i -lt $shares.Count; $i++) {
                    Write-Host ("  [{0}] " -f $i) -NoNewline
                    Write-Host $shares[$i].Name -ForegroundColor White -NoNewline
                    Write-Host "  ->  $($shares[$i].UNC)" -ForegroundColor Gray
                    if (-not [string]::IsNullOrWhiteSpace($shares[$i].Description)) {
                        Write-Host "        $($shares[$i].Description)" -ForegroundColor DarkGray
                    }
                }
                $pick = (Read-Host "  -> Numero du partage a mapper").Trim()
                if ($pick -match '^\d+$' -and [int]$pick -ge 0 -and [int]$pick -lt $shares.Count) {
                    $unc   = $shares[[int]$pick].UNC
                    $label = $shares[[int]$pick].Name
                } else {
                    Write-Host "  -> Choix invalide." -ForegroundColor Red
                    continue
                }
            }
        }
        elseif ($src -eq '2') {
            $unc = Read-NonEmpty "Chemin UNC (\\serveur\partage)"
        }
        else {
            Write-Host "  -> Choix invalide (0, 1 ou 2)." -ForegroundColor Red
            continue
        }

        # Validation UNC basique : \\serveur\partage
        if ($unc -notmatch '^\\\\[^\\]+\\.+') {
            Write-Host "  -> Chemin UNC invalide (format attendu : \\serveur\partage)." -ForegroundColor Red
            $recap += "Lecteur reseau : chemin UNC invalide ($unc)"
            continue
        }

        # Choix de la lettre de lecteur (libre, sinon proposition de remplacement)
        $usedLetters = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $letter = $null
        while ($true) {
            $l = (Read-Host "Lettre de lecteur a utiliser (ex: Z)").Trim().ToUpper()
            if ($l -notmatch '^[A-Z]$') { Write-Host "  -> Saisissez une seule lettre (A-Z)." -ForegroundColor Red; continue }
            if ($usedLetters -contains $l) {
                if (Read-YesNo "La lettre $l est deja utilisee. La remplacer ? (O/N)") {
                    try { Remove-PSDrive -Name $l -Force -ErrorAction SilentlyContinue } catch {}
                    try { & cmd.exe /c "net use ${l}: /delete /y" | Out-Null } catch {}
                    $letter = $l; break
                } else { continue }
            } else { $letter = $l; break }
        }

        # Identifiants optionnels (sinon : contexte de l'utilisateur courant du domaine)
        $cred = $null
        if (Read-YesNo "Utiliser des identifiants specifiques pour ce partage ? (O/N)") {
            $cred = Get-JoinCredential   # reutilise le helper (console ou popup, mot de passe securise)
        }

        # Mapping PERSISTANT (reconnecte a chaque ouverture de session)
        try {
            $params = @{ Name = $letter; PSProvider = 'FileSystem'; Root = $unc; Persist = $true; ErrorAction = 'Stop' }
            if ($cred) { $params['Credential'] = $cred }
            New-PSDrive @params | Out-Null
            Write-Host "  -> Lecteur ${letter}: cree et connecte a $unc (persistant)." -ForegroundColor Green
            $line = "Lecteur ${letter}: -> $unc (persistant)"
            if (-not [string]::IsNullOrWhiteSpace($label)) { $line += " [$label]" }
            $recap += $line
        } catch {
            Write-Host "  -> Erreur de mapping : $($_.Exception.Message)" -ForegroundColor Red
            $recap += "ERREUR mapping ${letter}: -> $unc ($($_.Exception.Message))"
        }

        $another = Read-YesNo "Mapper un autre lecteur reseau ? (O/N)"
    }

    # --- Visibilite du lecteur en session standard (contexte admin / UAC) ---
    if ($recap.Count -gt 0 -and ($recap -match '^Lecteur ')) {
        Write-Host "`nNote : ce script s'execute en administrateur. A cause des 'connexions liees'" -ForegroundColor DarkYellow
        Write-Host "(UAC), le lecteur peut ne pas apparaitre immediatement dans l'Explorateur de la" -ForegroundColor DarkYellow
        Write-Host "session standard ; etant persistant, il se reconnectera a la prochaine ouverture" -ForegroundColor DarkYellow
        Write-Host "de session. Pour une visibilite immediate entre les deux jetons, on peut activer" -ForegroundColor DarkYellow
        Write-Host "EnableLinkedConnections (necessite un redemarrage)." -ForegroundColor DarkYellow
        if (Read-YesNo "Activer EnableLinkedConnections maintenant ? (O/N)") {
            try {
                Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLinkedConnections" -Value 1
                $script:NeedReboot = $true
                Write-Host "  -> EnableLinkedConnections active (effectif apres redemarrage)." -ForegroundColor Green
                $recap += "EnableLinkedConnections active (redemarrage requis)"
            } catch {
                Write-Host "  -> Erreur : $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host "Rappel : pour un parc, le mapping de lecteurs se deploie idealement cote serveur" -ForegroundColor DarkGray
        Write-Host "via GPO (Preferences de strategie de groupe), plutot que poste par poste." -ForegroundColor DarkGray
    }

    if ($recap.Count -eq 0) { $recap += "Aucun lecteur reseau mappe" }
    return $recap
}

# --- Execute un controle de durcissement en gerant erreurs + statut + recap ---
function Invoke-HardeningControl {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    try {
        & $Action
        Write-Host "   [+] $Label" -ForegroundColor Green
        return "OK   : $Label"
    } catch {
        Write-Host "   [!] $Label -> $($_.Exception.Message)" -ForegroundColor Red
        return "ERR  : $Label ($($_.Exception.Message))"
    }
}

# =====================================================================
#        BLOCS DE DURCISSEMENT (cumulatifs par niveau)
# =====================================================================
# Chaque fonction renvoie un tableau de lignes de recapitulatif.
# Les niveaux superieurs appellent d'abord le niveau inferieur (cumul).
# $script:NeedReboot est mis a $true par les controles qui l'exigent.

# --- Socle commun de base (utilise par CIS L1 et ANSSI Minimal) ---
function Invoke-HardeningBaseline {
    $r = @()

    $r += Invoke-HardeningControl "Pare-feu Windows active (profils Domaine/Prive/Public)" {
        Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -ErrorAction Stop
    }
    $r += Invoke-HardeningControl "Protocole SMBv1 (obsolete) desactive cote serveur" {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
    }
    $r += Invoke-HardeningControl "UAC actif (EnableLUA, invite sur bureau securise)" {
        $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-HardeningRegistry -Path $p -Name "EnableLUA" -Value 1
        Set-HardeningRegistry -Path $p -Name "ConsentPromptBehaviorAdmin" -Value 2
        Set-HardeningRegistry -Path $p -Name "PromptOnSecureDesktop" -Value 1
        Set-HardeningRegistry -Path $p -Name "EnableInstallerDetection" -Value 1
    }
    $r += Invoke-HardeningControl "Execution automatique (AutoRun/AutoPlay) desactivee" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutorun" -Value 1
    }
    $r += Invoke-HardeningControl "Compte Invite (Guest, SID -501) desactive" {
        $guest = Get-LocalUser -ErrorAction Stop | Where-Object { $_.SID.Value -like '*-501' }
        if ($guest) { Disable-LocalUser -Name $guest.Name -ErrorAction Stop }
    }
    $r += Invoke-HardeningControl "Politique de mots de passe (longueur >= 14, historique, expiration)" {
        cmd /c "net accounts /minpwlen:14 /maxpwage:365 /minpwage:1 /uniquepw:24" | Out-Null
        cmd /c "net accounts /lockoutthreshold:10 /lockoutduration:15 /lockoutwindow:15" | Out-Null
    }
    $r += Invoke-HardeningControl "Windows Defender : protection temps reel + cloud + anti-PUA" {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue
        Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
        Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
    }

    return $r
}

# --- Renforcement "intermediaire" commun (CIS L1 etendu / ANSSI Intermediaire) ---
function Invoke-HardeningIntermediate {
    $r = @()

    $r += Invoke-HardeningControl "Signature SMB obligatoire (serveur et client)" {
        Set-SmbServerConfiguration -RequireSecuritySignature $true -Force -ErrorAction Stop
        Set-SmbClientConfiguration -RequireSecuritySignature $true -Force -ErrorAction Stop
    }
    $r += Invoke-HardeningControl "NTLM durci : refus LM/NTLMv1, pas de hash LM" {
        $lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        Set-HardeningRegistry -Path $lsa -Name "LmCompatibilityLevel" -Value 5
        Set-HardeningRegistry -Path $lsa -Name "NoLMHash" -Value 1
    }
    $r += Invoke-HardeningControl "Acces anonyme restreint (RestrictAnonymous / SAM)" {
        $lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        Set-HardeningRegistry -Path $lsa -Name "RestrictAnonymous" -Value 1
        Set-HardeningRegistry -Path $lsa -Name "RestrictAnonymousSAM" -Value 1
        Set-HardeningRegistry -Path $lsa -Name "EveryoneIncludesAnonymous" -Value 0
    }
    $r += Invoke-HardeningControl "Resolution LLMNR desactivee (anti-spoofing reseau)" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0
    }
    $r += Invoke-HardeningControl "Journalisation des blocs de scripts PowerShell" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1
    }
    $r += Invoke-HardeningControl "Audit : connexions, ouverture de session, gestion des comptes" {
        auditpol /set /category:"Ouverture/Fermeture de session" /success:enable /failure:enable | Out-Null
        auditpol /set /category:"Connexion de compte" /success:enable /failure:enable | Out-Null
        auditpol /set /category:"Gestion des comptes" /success:enable /failure:enable | Out-Null
    }
    $r += Invoke-HardeningControl "Verrouillage ecran sur inactivite (900 s)" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "InactivityTimeoutSecs" -Value 900
    }

    return $r
}

# --- Renforcement "eleve" commun (CIS L2 / ANSSI Eleve) ---
function Invoke-HardeningAdvanced {
    $r = @()

    $r += Invoke-HardeningControl "WDigest : mise en cache des identifiants en clair desactivee" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name "UseLogonCredential" -Value 0
    }
    $r += Invoke-HardeningControl "Protection LSASS en processus protege (RunAsPPL)" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -Value 1
        $script:NeedReboot = $true
    }
    $r += Invoke-HardeningControl "Audit avance : creation de processus + ligne de commande (Event 4688)" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" -Name "ProcessCreationIncludeCmdLine_Enabled" -Value 1
        auditpol /set /subcategory:"Creation du processus" /success:enable /failure:enable | Out-Null
    }
    $r += Invoke-HardeningControl "Transcription PowerShell activee" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -Name "EnableTranscripting" -Value 1
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription" -Name "OutputDirectory" -Value "C:\PS-Transcripts" -Type String
    }
    $r += Invoke-HardeningControl "RDP : authentification NLA obligatoire" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1
    }
    $r += Invoke-HardeningControl "Assistance a distance desactivee" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name "fAllowToGetHelp" -Value 0
    }
    $r += Invoke-HardeningControl "Acces protege aux dossiers (Controlled Folder Access - anti-ransomware)" {
        Set-MpPreference -EnableControlledFolderAccess Enabled -ErrorAction Stop
    }
    $r += Invoke-HardeningControl "Signature LDAP cliente obligatoire" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LDAP" -Name "LDAPClientIntegrity" -Value 2
    }
    $r += Invoke-HardeningControl "Nombre d'ouvertures de session mises en cache limite (4)" {
        Set-HardeningRegistry -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "CachedLogonsCount" -Value 4 -Type String
    }

    return $r
}

# --- Surcouche "renforce" (specifique ANSSI Renforce, mesures les plus strictes) ---
function Invoke-HardeningReinforced {
    $r = @()

    $r += Invoke-HardeningControl "Regles ASR (Attack Surface Reduction) activees" {
        $asrIds = @(
            'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550', # Contenu executable depuis messagerie/webmail
            'D4F940AB-401B-4EFC-AADC-AD5F3C50688A', # Office ne cree pas de processus enfant
            '3B576869-A4EC-4529-8536-B80A7769E899', # Office ne cree pas de contenu executable
            '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2', # Vol d'identifiants depuis LSASS
            'E6DB77E5-3DF2-4CF1-B95A-636979351E5B', # Persistance via abonnement WMI
            'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4'  # Processus non fiables depuis USB
        )
        foreach ($id in $asrIds) {
            Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions Enabled -ErrorAction SilentlyContinue
        }
    }
    $r += Invoke-HardeningControl "Securite basee sur la virtualisation (VBS) + Credential Guard" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "EnableVirtualizationBasedSecurity" -Value 1
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard" -Name "RequirePlatformSecurityFeatures" -Value 1
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -Value 1
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LsaCfgFlags" -Value 1
        $script:NeedReboot = $true
    }
    $r += Invoke-HardeningControl "Effacement du fichier d'echange a l'arret" {
        Set-HardeningRegistry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "ClearPageFileAtShutdown" -Value 1
    }
    $r += Invoke-HardeningControl "PowerShell v2 (obsolete) desactive" {
        $f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
        if ($f.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction Stop | Out-Null
            $script:NeedReboot = $true
        }
    }
    $r += Invoke-HardeningControl "Politique d'execution PowerShell : RemoteSigned (machine)" {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
    }
    $r += Invoke-HardeningControl "Banniere legale a l'ouverture de session" {
        $p = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
        Set-HardeningRegistry -Path $p -Name "legalnoticecaption" -Value "AVERTISSEMENT LEGAL" -Type String
        Set-HardeningRegistry -Path $p -Name "legalnoticetext" -Value "Acces reserve au personnel autorise. Toute action non autorisee sera enregistree et poursuivie." -Type String
    }

    return $r
}

# --- Assemblage par referentiel/niveau (cumulatif) ---
function Invoke-CISLevel1  { return (Invoke-HardeningBaseline) + (Invoke-HardeningIntermediate) }
function Invoke-CISLevel2  { return (Invoke-CISLevel1) + (Invoke-HardeningAdvanced) }

function Invoke-ANSSIMinimal       { return (Invoke-HardeningBaseline) }
function Invoke-ANSSIIntermediaire { return (Invoke-ANSSIMinimal) + (Invoke-HardeningIntermediate) }
function Invoke-ANSSIEleve         { return (Invoke-ANSSIIntermediaire) + (Invoke-HardeningAdvanced) }
function Invoke-ANSSIRenforce      { return (Invoke-ANSSIEleve) + (Invoke-HardeningReinforced) }

# --- Menu CIS ---
function Invoke-HardeningCIS {
    while ($true) {
        Write-Host "`n=== CIS Benchmark - Choix du niveau ===" -ForegroundColor Cyan
        Write-Host "  [1] " -NoNewline
        Write-Host "Level 1 (L1) - Securite de base  -  Parametres surs a faible impact fonctionnel, recommandes sur la majorite des postes" -ForegroundColor Green
        Write-Host "      Inclut : pare-feu, UAC, SMBv1 off, NTLM durci, LLMNR off, politique de" -ForegroundColor White
        Write-Host "      mots de passe, audit de base, verrouillage ecran." -ForegroundColor White
        Write-Host "  [2] " -NoNewline
        Write-Host "Level 2 (L2) - Defense en profondeur  -  Peut restreindre certains usages : reserve aux environnements sensibles" -ForegroundColor Red
        Write-Host "      Cumule L1 + WDigest off, LSASS protege, RDP NLA, assistance distante off," -ForegroundColor White
        Write-Host "      Controlled Folder Access, transcription PowerShell, signature LDAP, audit 4688." -ForegroundColor White
        Write-Host "  [0] " -NoNewline
        Write-Host "Retour au choix du referentiel (CIS / ANSSI)" -ForegroundColor DarkGray

        $lvl = (Read-Host "`n  -> Votre choix").Trim()
        if ($lvl -eq '1') {
            if (Read-YesNo "Appliquer CIS Level 1 sur ce poste ? (O/N)") {
                Write-Host "`n--- Application de CIS Level 1 ---" -ForegroundColor Yellow
                return @("Referentiel : CIS Benchmark - Level 1") + (Invoke-CISLevel1)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '2') {
            if (Read-YesNo "Appliquer CIS Level 2 (cumule L1 + L2) sur ce poste ? (O/N)") {
                Write-Host "`n--- Application de CIS Level 2 (L1 + L2) ---" -ForegroundColor Yellow
                return @("Referentiel : CIS Benchmark - Level 2 (cumule L1)") + (Invoke-CISLevel2)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '0') {
            return '__RETOUR_REFERENTIEL__'   # signal : revenir au choix CIS/ANSSI
        }
        else {
            Write-Host "  -> Choix invalide (0, 1 ou 2)." -ForegroundColor Red
        }
    }
}

# --- Menu ANSSI BP-028 ---
function Invoke-HardeningANSSI {
    while ($true) {
        Write-Host "`n=== ANSSI BP-028 - Choix du niveau ===" -ForegroundColor Cyan
        Write-Host "  [1] " -NoNewline
        Write-Host "Minimal  -  postes exposes a Internet avec donnees peu sensibles" -ForegroundColor Green
        Write-Host "      Socle indispensable : pare-feu, UAC, SMBv1 off, AutoRun off," -ForegroundColor White
        Write-Host "      compte Invite off, antivirus actif, politique de mots de passe." -ForegroundColor White
        Write-Host "  [2] " -NoNewline
        Write-Host "Intermediaire  -  postes en reseau d'entreprise standard" -ForegroundColor Cyan
        Write-Host "      Minimal + signature SMB, NTLM durci, LLMNR off, restriction" -ForegroundColor White
        Write-Host "      anonyme, journalisation PowerShell, audit, verrouillage ecran." -ForegroundColor White
        Write-Host "  [3] " -NoNewline
        Write-Host "Eleve  -  donnees sensibles (RH, finance, R&D)" -ForegroundColor Yellow
        Write-Host "      Intermediaire + WDigest off, LSASS protege, RDP NLA, assistance" -ForegroundColor White
        Write-Host "      distante off, Controlled Folder Access, signature LDAP, audit 4688." -ForegroundColor White
        Write-Host "  [4] " -NoNewline
        Write-Host "Renforce  -  OIV (Operateurs d'Importance Vitale), defense" -ForegroundColor Red
        Write-Host "      Eleve + regles ASR, VBS/Credential Guard, effacement pagefile," -ForegroundColor White
        Write-Host "      PowerShell v2 off, banniere legale. Mesures les plus strictes." -ForegroundColor White
        Write-Host "  [0] " -NoNewline
        Write-Host "Retour au choix du referentiel (CIS / ANSSI)" -ForegroundColor DarkGray

        $lvl = (Read-Host "`n  -> Votre choix").Trim()
        if ($lvl -eq '1') {
            if (Read-YesNo "Appliquer ANSSI - niveau Minimal ? (O/N)") {
                Write-Host "`n--- Application ANSSI BP-028 : Minimal ---" -ForegroundColor Yellow
                return @("Referentiel : ANSSI BP-028 - Minimal") + (Invoke-ANSSIMinimal)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '2') {
            if (Read-YesNo "Appliquer ANSSI - niveau Intermediaire ? (O/N)") {
                Write-Host "`n--- Application ANSSI BP-028 : Intermediaire ---" -ForegroundColor Yellow
                return @("Referentiel : ANSSI BP-028 - Intermediaire (cumule Minimal)") + (Invoke-ANSSIIntermediaire)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '3') {
            if (Read-YesNo "Appliquer ANSSI - niveau Eleve ? (O/N)") {
                Write-Host "`n--- Application ANSSI BP-028 : Eleve ---" -ForegroundColor Yellow
                return @("Referentiel : ANSSI BP-028 - Eleve (cumule Minimal+Intermediaire)") + (Invoke-ANSSIEleve)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '4') {
            if (Read-YesNo "Appliquer ANSSI - niveau Renforce (le plus strict) ? (O/N)") {
                Write-Host "`n--- Application ANSSI BP-028 : Renforce ---" -ForegroundColor Yellow
                return @("Referentiel : ANSSI BP-028 - Renforce (cumule tous les niveaux)") + (Invoke-ANSSIRenforce)
            }
            Write-Host "  -> Annule : retour au menu des niveaux." -ForegroundColor DarkGray
        }
        elseif ($lvl -eq '0') {
            return '__RETOUR_REFERENTIEL__'   # signal : revenir au choix CIS/ANSSI
        }
        else {
            Write-Host "  -> Choix invalide (0 a 4)." -ForegroundColor Red
        }
    }
}

# --- Point d'entree du module de durcissement (choix du referentiel) ---
function Invoke-Hardening {
    Write-Host "`n--- Durcissement (Hardening) de Windows 11 ---" -ForegroundColor Yellow
    Write-Host "AVERTISSEMENT : sous-ensemble representatif de mesures inspirees de CIS/ANSSI." -ForegroundColor DarkYellow
    Write-Host "Ce module N'EST PAS une implementation exhaustive ni une certification de" -ForegroundColor DarkYellow
    Write-Host "conformite. Testez sur un poste pilote ; en production, privilegiez GPO/Intune." -ForegroundColor DarkYellow

    Write-Host "`nChoisissez le referentiel de securite :" -ForegroundColor Cyan
    Write-Host "  [1] " -NoNewline
    Write-Host "CIS Benchmark" -ForegroundColor Green -NoNewline
    Write-Host " (Center for Internet Security - niveaux L1 / L2)" -ForegroundColor Gray
    Write-Host "  [2] " -NoNewline
    Write-Host "ANSSI BP-028" -ForegroundColor Cyan -NoNewline
    Write-Host " (referentiel francais - Minimal / Intermediaire / Eleve / Renforce)" -ForegroundColor Gray
    Write-Host "  [0] " -NoNewline
    Write-Host "Annuler (ne rien appliquer)" -ForegroundColor DarkGray

    while ($true) {
        $fw = (Read-Host "  -> Votre choix").Trim()
        if ($fw -eq '1') {
            $res = Invoke-HardeningCIS
            # Si le sous-menu a renvoye la sentinelle de retour, on re-affiche le
            # choix du referentiel (l'utilisateur peut alors basculer sur ANSSI).
            if (-not (($res -is [string]) -and ($res -eq '__RETOUR_REFERENTIEL__'))) { return $res }
        }
        elseif ($fw -eq '2') {
            $res = Invoke-HardeningANSSI
            if (-not (($res -is [string]) -and ($res -eq '__RETOUR_REFERENTIEL__'))) { return $res }
        }
        elseif ($fw -eq '0') {
            return @("Durcissement : annule (aucune mesure appliquee)")
        }
        else {
            Write-Host "  -> Choix invalide (0, 1 ou 2)." -ForegroundColor Red
        }
        # Rappel du menu de referentiel apres un retour depuis un sous-menu
        Write-Host "`nChoisissez le referentiel de securite :" -ForegroundColor Cyan
        Write-Host "  [1] " -NoNewline
        Write-Host "CIS Benchmark" -ForegroundColor Green -NoNewline
        Write-Host " (Center for Internet Security - niveaux L1 / L2)" -ForegroundColor Gray
        Write-Host "  [2] " -NoNewline
        Write-Host "ANSSI BP-028" -ForegroundColor Cyan -NoNewline
        Write-Host " (referentiel francais - Minimal / Intermediaire / Eleve / Renforce)" -ForegroundColor Gray
        Write-Host "  [0] " -NoNewline
        Write-Host "Annuler (ne rien appliquer)" -ForegroundColor DarkGray
    }
}

# =====================================================================
# 1. AUTO-ELEVATION (relance le script en Admin si necessaire)
# =====================================================================
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole   = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $myPrincipal.IsInRole($adminRole)) {

    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Host "Ce script doit etre lance depuis un fichier .ps1 enregistre sur le disque." -ForegroundColor Red
        Write-Host "Faites un clic droit sur le fichier -> 'Executer avec PowerShell'," -ForegroundColor Yellow
        Write-Host "ou ouvrez PowerShell EN ADMINISTRATEUR puis lancez : .\Init-WindowsClient11.ps1" -ForegroundColor Yellow
        Read-Host "`nAppuyez sur Entree pour fermer"
        exit 1
    }

    Write-Host "Droits administrateur requis : demande d'elevation (UAC)..." -ForegroundColor Yellow
    Write-Host "Une invite de controle de compte (UAC) va s'afficher : cliquez sur 'Oui'." -ForegroundColor Yellow
    Write-Host "La suite s'ouvrira dans une NOUVELLE fenetre PowerShell (celle-ci se fermera)." -ForegroundColor Yellow

    try {
        # -NoExit : la fenetre elevee RESTE ouverte meme en cas d'erreur precoce,
        #           afin de pouvoir lire le message au lieu d'une fermeture immediate.
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") `
            -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Host "`n[ECHEC] Impossible d'obtenir les droits administrateur." -ForegroundColor Red
        Write-Host "Causes probables :" -ForegroundColor Red
        Write-Host "  - l'invite UAC a ete refusee (bouton 'Non' / Annuler), ou" -ForegroundColor Red
        Write-Host "  - votre compte local N'EST PAS administrateur de ce poste." -ForegroundColor Red
        Write-Host "`nSolution : ouvrez une session (ou faites-vous elever) avec un compte" -ForegroundColor Yellow
        Write-Host "administrateur local, puis relancez ce script." -ForegroundColor Yellow
        Read-Host "`nAppuyez sur Entree pour fermer"
        exit 1
    }

    # L'instance elevee prend le relais dans la nouvelle fenetre : on laisse le temps
    # de lire le message ci-dessus, puis on ferme cette fenetre non privilegiee.
    Start-Sleep -Seconds 1
    exit 0
}

# Chemin du present script (contexte administrateur) : utilise plus bas pour
# faciliter, en option, les futurs lancements directs du .ps1.
$scriptSelfPath = $MyInvocation.MyCommand.Path

# Confort visuel + journalisation
if ($Host.Name -eq "ConsoleHost") {
    try { $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(120, 35) } catch {}
}
$logPath = "$env:TEMP\Init-WindowsClient11.log"
try { Start-Transcript -Path $logPath -Append -ErrorAction Stop | Out-Null } catch {}

# Variable globale : un seul redemarrage propose a la fin si necessaire
$script:NeedReboot = $false
$script:DomainJoinPending = $false

try {

    Clear-Host
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "     INITIALISATION POSTE CLIENT WINDOWS 11         " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan
    Write-Host "Poste : $env:COMPUTERNAME  |  Utilisateur : $env:USERNAME" -ForegroundColor Gray

    # -----------------------------------------------------------------
    # --- [0/3] CONFORT : faciliter les prochains lancements du .ps1 ---
    # -----------------------------------------------------------------
    # Windows 11 client est en ExecutionPolicy "Restricted" par defaut, ce qui
    # empeche le double-clic sur un .ps1. Ce reglage ne peut PAS etre fait par le
    # script AVANT son propre lancement (le script serait deja bloque) : c'est
    # pourquoi le premier lancement passe par le lanceur .cmd (ou -ExecutionPolicy
    # Bypass). En revanche, maintenant que le script tourne (et en admin), il peut
    # proposer de regler durablement la strategie MACHINE sur 'RemoteSigned'
    # (posture standard, identique a Windows Server) pour que les PROCHAINS
    # lancements directs du .ps1 fonctionnent sans lanceur ni commande.
    $lmPolicy = Get-ExecutionPolicy -Scope LocalMachine
    if ($lmPolicy -in @('Restricted', 'Undefined', 'AllSigned')) {
        Write-Host "`nStrategie d'execution actuelle du poste (machine) : $lmPolicy" -ForegroundColor Yellow
        Write-Host "Elle empeche le lancement direct (double-clic) des scripts .ps1." -ForegroundColor Yellow
        if (Read-YesNo "Autoriser durablement les scripts locaux signes/locaux (RemoteSigned) pour ne plus utiliser le lanceur ? (O/N)") {
            try {
                Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
                # On debloque ce script (Mark of the Web) pour qu'il ne soit pas bloque en RemoteSigned
                if ($scriptSelfPath) { Unblock-File -Path $scriptSelfPath -ErrorAction SilentlyContinue }
                Write-Host "  -> Strategie machine reglee sur 'RemoteSigned'." -ForegroundColor Green
                Write-Host "  -> Les prochains lancements directs du .ps1 (double-clic) fonctionneront." -ForegroundColor Green
            } catch {
                Write-Host "  -> Impossible de modifier la strategie : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "     (Une strategie imposee par GPO peut etre en cause.) Continuez avec le lanceur .cmd." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "  -> Strategie inchangee : continuez a utiliser le lanceur .cmd." -ForegroundColor DarkGray
        }
    }

    # -----------------------------------------------------------------
    # --- REPRISE : detection d'une session precedente (post-reboot) ---
    # -----------------------------------------------------------------
    $existingState = Get-InitState
    if ($existingState) {
        Write-Host "`nUne session precedente a ete detectee (sauvegarde du $($existingState.Updated))." -ForegroundColor Cyan
        $doneList = @()
        if ($existingState.IPDone)        { $doneList += "IP" }
        if ($existingState.DomainDone)    { $doneList += "Nom/Domaine" }
        if ($existingState.DriveDone)     { $doneList += "Lecteur reseau" }
        if ($existingState.HardeningDone) { $doneList += "Durcissement" }
        if ($doneList.Count -gt 0) { Write-Host "Etapes deja realisees : $($doneList -join ', ')" -ForegroundColor Gray }
        Write-Host "  [1] Reprendre la ou le script s'etait arrete (ignorer les etapes deja faites)"
        Write-Host "  [2] Tout recommencer depuis le debut"
        while ($true) {
            $rs = (Read-Host "  -> Votre choix (1/2)").Trim()
            if ($rs -eq '1') { $state = $existingState; Write-Host "Reprise de la session precedente." -ForegroundColor Green; break }
            elseif ($rs -eq '2') { Clear-InitState; $state = New-InitState -ScriptPath $scriptSelfPath; Write-Host "Nouveau depart : etat precedent efface." -ForegroundColor DarkGray; break }
            else { Write-Host "  -> Choix invalide (1 ou 2)." -ForegroundColor Red }
        }
    } else {
        $state = New-InitState -ScriptPath $scriptSelfPath
        Unregister-ResumeTask   # nettoie une eventuelle tache de reprise orpheline
    }
    $state.ScriptPath = $scriptSelfPath
    Save-InitState $state

    # -----------------------------------------------------------------
    # --- [1/4] CONFIGURATION IP COMPLETE ---
    # -----------------------------------------------------------------
    Write-Host "`n--- [1/4] Configuration IP ---" -ForegroundColor Yellow
    $recapIP = @()
    if ($state.IPDone) {
        Write-Host "Etape deja realisee lors d'une session precedente -> ignoree." -ForegroundColor DarkGray
        $recapIP += "Etape ignoree (deja faite precedemment)"
    }
    elseif (Read-YesNo "Voulez-vous configurer l'adressage IP de ce poste ? (O/N)") {
        $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })
        if ($adapters.Count -eq 0) {
            Write-Host "Aucune carte reseau active detectee. Configuration IP ignoree." -ForegroundColor Red
            $recapIP += "Aucune carte reseau active : etape ignoree"
        } else {
            Write-Host "Cartes reseau actives detectees :" -ForegroundColor Cyan
            for ($i = 0; $i -lt $adapters.Count; $i++) {
                Write-Host "  [$i] $($adapters[$i].Name) ($($adapters[$i].InterfaceDescription))"
            }
            $choice = Read-Host "  -> Numero de la carte a configurer (ex: 0)"
            if ($choice -match "^\d+$" -and [int]$choice -ge 0 -and [int]$choice -lt $adapters.Count) {
                $adapterName = $adapters[[int]$choice].Name
                Write-Host "Carte '$adapterName' selectionnee." -ForegroundColor Green

                $mode = Read-Host "  -> Adressage [1] Statique  [2] Automatique (DHCP)"
                if ($mode.Trim() -eq '2') {
                    try {
                        Remove-NetIPAddress -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                        Remove-NetRoute -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                        Set-NetIPInterface -InterfaceAlias $adapterName -Dhcp Enabled -ErrorAction Stop
                        Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses -ErrorAction Stop
                        Write-Host "Carte '$adapterName' repassee en DHCP." -ForegroundColor Green
                        $recapIP += "Carte '$adapterName' configuree en DHCP (automatique)"
                    } catch {
                        Write-Host "  -> Erreur : $($_.Exception.Message)" -ForegroundColor Red
                        $recapIP += "ERREUR passage DHCP sur '$adapterName'"
                    }
                } else {
                    $ip   = Read-NonEmpty "Adresse IP statique (ex: 192.168.1.50)"
                    $mask = Read-NonEmpty "Masque en notation CIDR (ex: 24)"
                    $gw   = Read-Host "Passerelle (ex: 192.168.1.254) - Entree si aucune"
                    $dns  = Read-Host "DNS (ex: 192.168.1.1) - Entree si aucun"

                    $parsedIp = $null
                    $ipValide = [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIp)
                    $maskInt = 0
                    $maskValide = [int]::TryParse($mask, [ref]$maskInt) -and $maskInt -ge 0 -and $maskInt -le 32

                    if (-not $ipValide -or -not $maskValide) {
                        Write-Host "Adresse IP ou masque invalide (masque 0-32). Configuration ignoree." -ForegroundColor Red
                        $recapIP += "IP/masque invalide : etape ignoree"
                    } else {
                        try {
                            Remove-NetIPAddress -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                            Remove-NetRoute -InterfaceAlias $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                            Set-NetIPInterface -InterfaceAlias $adapterName -Dhcp Disabled -ErrorAction SilentlyContinue

                            if ($gw -ne '') {
                                New-NetIPAddress -InterfaceAlias $adapterName -IPAddress $ip -PrefixLength $maskInt -DefaultGateway $gw -ErrorAction Stop | Out-Null
                            } else {
                                New-NetIPAddress -InterfaceAlias $adapterName -IPAddress $ip -PrefixLength $maskInt -ErrorAction Stop | Out-Null
                            }
                            if ($dns -ne '') {
                                Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses $dns -ErrorAction Stop
                            }

                            Write-Host "`n----------- RESUME DE LA CONFIGURATION IP -----------" -ForegroundColor Green
                            Write-Host "  Carte reseau  : $adapterName"
                            Write-Host "  Adresse IP    : $ip"
                            Write-Host "  Masque (CIDR) : /$maskInt"
                            Write-Host "  Passerelle    : $(if ($gw -ne '') { $gw } else { '(non definie)' })"
                            Write-Host "  DNS           : $(if ($dns -ne '') { $dns } else { '(non defini)' })"
                            Write-Host "------------------------------------------------------`n" -ForegroundColor Green
                            $recapIP += "IP statique $ip/$maskInt appliquee sur '$adapterName'"
                            if ($gw -ne '')  { $recapIP += "Passerelle : $gw" }
                            if ($dns -ne '') { $recapIP += "DNS : $dns" }
                        } catch {
                            Write-Host "  -> Erreur de configuration IP : $($_.Exception.Message)" -ForegroundColor Red
                            $recapIP += "ERREUR de configuration IP (etape a relancer)"
                        }
                    }
                }
            } else {
                Write-Host "Choix de carte invalide. Configuration IP ignoree." -ForegroundColor Red
                $recapIP += "Choix de carte invalide : etape ignoree"
            }
        }
    } else {
        Write-Host "Etape ignoree : configuration IP non demandee." -ForegroundColor DarkGray
    }
    $state.IPDone = $true
    Save-InitState $state
    Show-StepSummary -Title "CONFIGURATION IP" -Lines $recapIP

    # -----------------------------------------------------------------
    # --- [2/4] RENOMMAGE + JONCTION AU DOMAINE ---
    # -----------------------------------------------------------------
    # NB : le redemarrage necessaire est DIFFERE a la fin du script, afin de
    #      ne pas interrompre l'etape de durcissement qui suit.
    Write-Host "`n--- [2/4] Nom du poste et jonction au domaine ---" -ForegroundColor Yellow
    $recapDomain = @()
    if ($state.DomainDone) {
        Write-Host "Etape deja realisee lors d'une session precedente -> ignoree." -ForegroundColor DarkGray
        $recapDomain += "Etape ignoree (deja faite precedemment)"
    }
    elseif (Read-YesNo "Voulez-vous renommer le poste et/ou le joindre a un domaine ? (O/N)") {
        $currentName = $env:COMPUTERNAME
        $newName = Read-ComputerName -Question "Nouveau nom du poste (max 15 car., ex: PC-COMPTA-01)" -Current $currentName
        $renamePending = ($newName -ne $currentName)

        if (Read-YesNo "Voulez-vous joindre ce poste a un domaine Active Directory ? (O/N)") {
            $domain = Read-NonEmpty "Nom du domaine a rejoindre (ex: monentreprise.local)"
            $cred = Get-JoinCredential
            try {
                if ($renamePending) {
                    Add-Computer -DomainName $domain -Credential $cred -NewName $newName -Force -ErrorAction Stop
                    Write-Host "Poste renomme en '$newName' ET joint au domaine '$domain'." -ForegroundColor Green
                    $recapDomain += "Poste renomme '$currentName' -> '$newName'"
                    $recapDomain += "Joint au domaine '$domain' (redemarrage requis)"
                } else {
                    Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction Stop
                    Write-Host "Poste joint au domaine '$domain'." -ForegroundColor Green
                    $recapDomain += "Joint au domaine '$domain' (redemarrage requis)"
                }
                $script:NeedReboot = $true
                $script:DomainJoinPending = $true
            } catch {
                Write-Host "  -> Erreur lors de la jonction au domaine : $($_.Exception.Message)" -ForegroundColor Red
                $recapDomain += "ERREUR jonction domaine '$domain' : $($_.Exception.Message)"
            }
        } else {
            if ($renamePending) {
                try {
                    Rename-Computer -NewName $newName -Force -ErrorAction Stop
                    Write-Host "Poste renomme en '$newName' (sans jonction domaine)." -ForegroundColor Green
                    $recapDomain += "Poste renomme '$currentName' -> '$newName' (redemarrage requis)"
                    $script:NeedReboot = $true
                } catch {
                    Write-Host "  -> Erreur lors du renommage : $($_.Exception.Message)" -ForegroundColor Red
                    $recapDomain += "ERREUR renommage : $($_.Exception.Message)"
                }
            } else {
                Write-Host "Nom conserve ('$currentName') et pas de jonction demandee." -ForegroundColor DarkGray
                $recapDomain += "Nom conserve ('$currentName'), aucune jonction"
            }
        }
    } else {
        Write-Host "Etape ignoree : nom/domaine non modifies." -ForegroundColor DarkGray
    }
    $state.DomainDone = $true
    Save-InitState $state
    Show-StepSummary -Title "NOM & DOMAINE" -Lines $recapDomain

    # -----------------------------------------------------------------
    # --- [3/4] LECTEUR(S) RESEAU (partages publies AD ou UNC manuel) ---
    # -----------------------------------------------------------------
    Write-Host "`n--- [3/4] Lecteur reseau ---" -ForegroundColor Yellow
    $recapDrive = @()

    # Si une jonction de domaine vient d'avoir lieu, elle n'est effective qu'apres
    # redemarrage : la DECOUVERTE AUTO des partages publies echouera d'ici la.
    # On propose donc, ICI, de redemarrer avant de continuer.
    if ($script:DomainJoinPending) {
        Write-Host "`nATTENTION : vous venez de joindre un domaine a l'etape [2/4]." -ForegroundColor Yellow
        Write-Host "Cette jonction ne devient effective qu'APRES REDEMARRAGE. Tant que le poste" -ForegroundColor Yellow
        Write-Host "n'a pas redemarre, la DECOUVERTE AUTOMATIQUE des partages publies dans l'AD" -ForegroundColor Yellow
        Write-Host "ne fonctionnera pas (seul le mappage par UNC manuel sera possible)." -ForegroundColor Yellow
        Write-Host "`nOptions :" -ForegroundColor Cyan
        Write-Host "  [1] Redemarrer MAINTENANT, puis relancer le script pour faire le lecteur"
        Write-Host "      reseau (avec decouverte AD) et le durcissement." -ForegroundColor Gray
        Write-Host "  [2] Continuer SANS redemarrer (decouverte AD indisponible ; UNC manuel OK ;"
        Write-Host "      le durcissement [4/4] reste applique dans cette session)." -ForegroundColor Gray

        while ($true) {
            $rc = (Read-Host "  -> Votre choix (1/2)").Trim()
            if ($rc -eq '1') {
                if (Read-YesNo "Confirmer le redemarrage maintenant ? (la reprise se fera automatiquement apres l'ouverture de session) (O/N)") {
                    Save-InitState $state
                    if (Register-ResumeTask -ScriptPath $scriptSelfPath) {
                        Write-Host "Reprise automatique programmee : le script se relancera apres l'ouverture de" -ForegroundColor Green
                        Write-Host "session et poursuivra directement au lecteur reseau puis au durcissement." -ForegroundColor Green
                    } else {
                        Write-Host "Reprise auto non programmee. Relancez le script manuellement apres redemarrage :" -ForegroundColor DarkYellow
                        Write-Host "il proposera de REPRENDRE la ou il s'est arrete." -ForegroundColor DarkYellow
                    }
                    Write-Host "Redemarrage en cours..." -ForegroundColor Yellow
                    try { Stop-Transcript | Out-Null } catch {}
                    Restart-Computer -Force
                    return
                }
                # non confirme : on repropose le choix
            }
            elseif ($rc -eq '2') {
                Write-Host "Poursuite sans redemarrer (decouverte AD limitee)." -ForegroundColor DarkGray
                break
            }
            else {
                Write-Host "  -> Choix invalide (1 ou 2)." -ForegroundColor Red
            }
        }
    }

    if ($state.DriveDone) {
        Write-Host "Etape deja realisee lors d'une session precedente -> ignoree." -ForegroundColor DarkGray
        $recapDrive += "Etape ignoree (deja faite precedemment)"
    }
    elseif (Read-YesNo "Voulez-vous mapper un lecteur reseau (partage du domaine) ? (O/N)") {
        $recapDrive = Invoke-NetworkDrive
    } else {
        Write-Host "Etape ignoree : aucun lecteur reseau mappe." -ForegroundColor DarkGray
        $recapDrive = @("Lecteur reseau non demande")
    }
    $state.DriveDone = $true
    Save-InitState $state
    Show-StepSummary -Title "LECTEUR RESEAU" -Lines $recapDrive

    # -----------------------------------------------------------------
    # --- [4/4] DURCISSEMENT (HARDENING) ---
    # -----------------------------------------------------------------
    Write-Host "`n--- [4/4] Durcissement de la securite ---" -ForegroundColor Yellow
    $recapHardening = @()
    if ($state.HardeningDone) {
        Write-Host "Etape deja realisee lors d'une session precedente -> ignoree." -ForegroundColor DarkGray
        $recapHardening += "Etape ignoree (deja faite precedemment)"
    }
    elseif (Read-YesNo "Voulez-vous appliquer un durcissement (CIS ou ANSSI) sur ce poste ? (O/N)") {
        $recapHardening = Invoke-Hardening
    } else {
        Write-Host "Etape ignoree : aucun durcissement applique." -ForegroundColor DarkGray
        $recapHardening = @("Durcissement non demande")
    }
    $state.HardeningDone = $true
    Save-InitState $state
    Show-StepSummary -Title "DURCISSEMENT (HARDENING)" -Lines $recapHardening

    # Toutes les etapes sont terminees : on efface l'etat et la tache de reprise.
    Clear-InitState
    Write-Host "Etat de progression efface (parcours complet)." -ForegroundColor DarkGray

    # -----------------------------------------------------------------
    # --- FIN : REDEMARRAGE EVENTUEL (unique, differe) ---
    # -----------------------------------------------------------------
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host " INITIALISATION DU POSTE CLIENT TERMINEE             " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    if ($script:NeedReboot) {
        Write-Host "Un REDEMARRAGE est necessaire pour appliquer certains changements" -ForegroundColor Red
        Write-Host "(nom du poste, jonction au domaine, protections type VBS/LSASS...)." -ForegroundColor Red
        if (Read-YesNo "Voulez-vous redemarrer maintenant ? (O/N)") {
            Write-Host "Redemarrage en cours..." -ForegroundColor Yellow
            try { Stop-Transcript | Out-Null } catch {}
            Restart-Computer -Force
        } else {
            Write-Host "Pensez a redemarrer le poste des que possible." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Aucun redemarrage requis." -ForegroundColor Green
    }

    Read-Host "`nAppuyez sur Entree pour quitter"

} catch {
    Write-Host "`n====================================================" -ForegroundColor Red
    Write-Host " UNE ERREUR A INTERROMPU LE SCRIPT" -ForegroundColor Red
    Write-Host "====================================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nLigne : $($_.InvocationInfo.ScriptLineNumber)  |  Commande : $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkYellow
    Write-Host "`nDetail complet enregistre dans : $logPath" -ForegroundColor Yellow
    Read-Host "`nAppuyez sur Entree pour fermer"
} finally {
    try { Stop-Transcript | Out-Null } catch {}
}
