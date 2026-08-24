@echo off
REM =====================================================================
REM  LANCEUR LOCAL - Init-WindowsClient11.ps1
REM ---------------------------------------------------------------------
REM  A QUOI SERT ENCORE CE LANCEUR ?
REM
REM  La methode principale est desormais le "Quick Launch" (une ligne) :
REM     irm https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1 ^| iex
REM  ...qui ne necessite NI fichier local, NI lanceur.
REM
REM  Ce .cmd reste utile dans trois cas :
REM    1. Poste SANS acces Internet (VLAN d'admin ferme, reseau pas encore
REM       configure - c'est justement l'etape [1/4] du script).
REM    2. Deploiement depuis une cle USB ou un partage.
REM    3. Version modifiee / de test, non encore publiee sur GitHub.
REM ---------------------------------------------------------------------
REM  Windows 11 client est en ExecutionPolicy "Restricted" par defaut :
REM  un double-clic sur un .ps1 est donc bloque (la fenetre se referme).
REM
REM  Ce lanceur execute le script PowerShell en contournant la strategie
REM  d'execution UNIQUEMENT pour cette execution (aucune modification
REM  permanente du poste). "-ExecutionPolicy Bypass" leve aussi le blocage
REM  des fichiers telecharges (Mark of the Web).
REM
REM  Le script PowerShell gere ensuite lui-meme l'elevation (UAC / droits
REM  administrateur), donc il suffit de DOUBLE-CLIQUER sur ce fichier .cmd.
REM
REM  IMPORTANT : gardez ce .cmd DANS LE MEME DOSSIER que le .ps1.
REM  (%~dp0 = dossier de ce lanceur, quel que soit son emplacement.)
REM =====================================================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Init-WindowsClient11.ps1"

REM Si l'elevation echoue ou si une erreur precoce survient, le script PS
REM affiche deja un message et attend une touche. On ajoute tout de meme un
REM filet de securite ici au cas ou PowerShell ne se lancerait pas du tout.
if errorlevel 1 (
    echo.
    echo [Lanceur] PowerShell a renvoye une erreur. Voir le message ci-dessus.
    pause
)
