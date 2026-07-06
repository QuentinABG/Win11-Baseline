# Win11-Baseline

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Windows-11-0078D6?logo=windows&logoColor=white)
![License](https://img.shields.io/badge/Licence-MIT-green)
![Status](https://img.shields.io/badge/Statut-Actif-brightgreen)

**Script PowerShell 100 % interactif d'initialisation et de durcissement d'un poste client Windows 11.**
Configuration réseau, renommage et jonction au domaine, mappage de lecteurs réseau, puis durcissement de la sécurité selon les référentiels **CIS Benchmark** ou **ANSSI BP‑028** — avec reprise automatique après redémarrage.

> ⚠️ **Avertissement** : le module de durcissement applique un **sous‑ensemble représentatif** de mesures inspirées de CIS et de l'ANSSI. Il ne constitue **ni une implémentation exhaustive ni une certification de conformité**. Testez toujours sur un poste pilote avant tout déploiement ; en production, privilégiez GPO / Microsoft Intune.

---

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Utilisation](#utilisation)
- [Détail des étapes](#détail-des-étapes)
- [Niveaux de durcissement](#niveaux-de-durcissement)
- [Reprise après redémarrage](#reprise-après-redémarrage)
- [Structure du dépôt](#structure-du-dépôt)
- [Avertissements et limites](#avertissements-et-limites)
- [Contribuer](#contribuer)
- [Licence](#licence)

---

## Fonctionnalités

- **Auto‑élévation** : le script demande les droits administrateur (UAC) et se relance élevé si nécessaire.
- **`[1/4]` Configuration IP** : sélection de la carte, adressage statique (IP/CIDR/passerelle/DNS) ou retour en DHCP, avec validation.
- **`[2/4]` Nom & domaine** : renommage du poste (nom NetBIOS validé) et jonction à un domaine Active Directory. Identifiants saisis **dans la console** ou via une **fenêtre popup** (`Get-Credential`).
- **`[3/4]` Lecteur réseau** : **découverte automatique des partages publiés dans l'Active Directory** (objets `volume`, via `System.DirectoryServices` — **sans RSAT**) ou saisie manuelle d'un chemin UNC, puis mappage **persistant**.
- **`[4/4]` Durcissement** : choix entre **CIS Benchmark** (L1 / L2) et **ANSSI BP‑028** (Minimal / Intermédiaire / Élevé / Renforcé), avec description de chaque niveau et sélection par numéro.
- **Reprise après redémarrage** : l'avancement est sauvegardé ; une tâche planifiée relance le script après le reboot pour poursuivre là où il s'était arrêté.
- **Journalisation** : un transcript est enregistré dans `%TEMP%\Init-WindowsClient11.log`.
- **Récapitulatifs** clairs et colorés à la fin de chaque étape.

---

## Prérequis

- **Windows 11** (le script cible le client ; il utilise des cmdlets présentes par défaut).
- **Windows PowerShell 5.1** (inclus dans Windows 11).
- **Droits administrateur** sur le poste (le script s'auto‑élève).
- Aucune dépendance externe : la découverte AD utilise `System.DirectoryServices` (natif .NET), **RSAT n'est pas requis**.

---

## Installation

Clonez le dépôt (ou téléchargez l'archive ZIP depuis GitHub) :

```bash
git clone https://github.com/QuentinABG/Win11-Baseline.git
```

Gardez **les deux fichiers dans le même dossier** :

- `Init-WindowsClient11.ps1` — le script principal
- `Lancer-Init-WindowsClient11.cmd` — le lanceur

---

## Utilisation

Windows 11 est en stratégie d'exécution `Restricted` par défaut : un double‑clic direct sur un `.ps1` est bloqué. Le **lanceur `.cmd`** contourne ce point le temps d'une exécution, sans modification permanente du poste.

### Méthode recommandée

**Double‑cliquez sur `Lancer-Init-WindowsClient11.cmd`.** Acceptez l'invite UAC, puis répondez aux questions.

Au premier lancement, le script propose (facultatif) de régler durablement la stratégie machine sur `RemoteSigned`, ce qui permet ensuite le **double‑clic direct** sur le `.ps1`.

### Méthodes alternatives

Depuis une console PowerShell **ouverte en administrateur** :

```powershell
Set-Location "C:\chemin\vers\le\dossier"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Init-WindowsClient11.ps1"
```

Ou, pour autoriser durablement le double‑clic (une fois, pour l'utilisateur courant) :

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Détail des étapes

| Étape | Nom | Description |
|:-----:|-----|-------------|
| `1/4` | Configuration IP | Carte réseau, IP statique (IP/CIDR/passerelle/DNS) ou DHCP |
| `2/4` | Nom & domaine | Renommage NetBIOS + jonction AD (identifiants console ou popup) |
| `3/4` | Lecteur réseau | Découverte des partages publiés dans l'AD ou UNC manuel, mappage persistant |
| `4/4` | Durcissement | CIS Benchmark ou ANSSI BP‑028, par niveau |

Chaque étape est **facultative** et peut être ignorée. Les étapes nom/domaine et certaines mesures de durcissement nécessitent un redémarrage, **différé à la fin** (un seul reboot proposé) afin de ne pas interrompre le parcours.

---

## Niveaux de durcissement

Les niveaux sont **cumulatifs** (un niveau supérieur inclut les précédents).

### CIS Benchmark

| Niveau | Cible | Contenu principal |
|--------|-------|-------------------|
| **L1 — Sécurité de base** | Majorité des postes | Pare‑feu, UAC, SMBv1 off, NTLM durci, LLMNR off, politique de mots de passe, audit de base, verrouillage écran |
| **L2 — Défense en profondeur** | Environnements sensibles | L1 + WDigest off, LSASS protégé, RDP NLA, assistance distante off, Controlled Folder Access, transcription PowerShell, signature LDAP, audit 4688 |

### ANSSI BP‑028

| Niveau | Cible | Contenu principal |
|--------|-------|-------------------|
| **Minimal** | Postes exposés à Internet, données peu sensibles | Pare‑feu, UAC, SMBv1 off, AutoRun off, compte Invité off, antivirus actif, politique de mots de passe |
| **Intermédiaire** | Réseau d'entreprise standard | Minimal + signature SMB, NTLM durci, LLMNR off, restriction anonyme, journalisation PowerShell, audit, verrouillage écran |
| **Élevé** | Données sensibles (RH, finance, R&D) | Intermédiaire + WDigest off, LSASS protégé, RDP NLA, assistance distante off, Controlled Folder Access, signature LDAP, audit 4688 |
| **Renforcé** | OIV, défense | Élevé + règles ASR, VBS / Credential Guard, effacement du pagefile, PowerShell v2 off, bannière légale |

> Les mesures s'appliquent **localement** (stratégies machine du registre + cmdlets natives), ce qui convient aussi bien à un poste autonome qu'à un futur membre de domaine.

---

## Reprise après redémarrage

L'avancement est enregistré dans `%ProgramData%\Init-WindowsClient11\state.json`.

- Au démarrage, si un état est détecté, le script propose de **reprendre** (les étapes déjà réalisées sont ignorées) ou de **tout recommencer**.
- Lorsqu'un redémarrage est déclenché par le script (par exemple après une jonction au domaine, pour rendre la découverte AD effective), une **tâche planifiée « à l'ouverture de session »** relance automatiquement le script pour poursuivre.
- En fin de parcours complet, l'état et la tâche de reprise sont supprimés.

---

## Structure du dépôt

```
Win11-Baseline/
├─ Init-WindowsClient11.ps1        # Script principal (interactif)
├─ Lancer-Init-WindowsClient11.cmd # Lanceur (contourne l'ExecutionPolicy)
├─ README.md                       # Ce fichier
├─ LICENSE                         # Licence MIT
└─ .gitignore
```

---

## Avertissements et limites

- **Ce n'est pas une certification de conformité.** CIS et ANSSI comportent des centaines de contrôles ; ce script en applique un sous‑ensemble représentatif et raisonnablement sûr.
- **Testez sur un poste pilote** avant tout déploiement. Certaines mesures du niveau *Renforcé* (VBS / Credential Guard, désactivation de PowerShell v2, LSASS PPL) requièrent du matériel compatible et un redémarrage, et peuvent impacter des usages.
- **Contexte élevé (UAC)** : un lecteur réseau mappé en administrateur peut ne pas apparaître immédiatement dans la session standard ; étant persistant, il se reconnecte à l'ouverture de session suivante. Le script propose d'activer `EnableLinkedConnections` pour une visibilité immédiate.
- **Découverte AD** : seuls les partages **explicitement publiés** dans l'Active Directory sont remontés en découverte automatique. Une jonction récente n'est effective qu'après redémarrage.
- Pour un **parc**, le déploiement (mappage de lecteurs, durcissement) se fait idéalement côté serveur via **GPO** ou **Intune**.

---

## Contribuer

Les contributions sont les bienvenues. Ouvrez une *issue* pour signaler un bug ou proposer une amélioration, ou soumettez une *pull request*. Merci de préciser la version de Windows et de PowerShell utilisée pour tout rapport de bug.

---

## Licence

Distribué sous licence **MIT**. Voir le fichier [`LICENSE`](LICENSE) pour les détails.

---

<p align="center">
  Réalisé avec PowerShell — pour l'administration et la sécurisation de postes Windows 11.
</p>
