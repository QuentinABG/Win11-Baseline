# Win11-Baseline

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Windows-11-0078D6?logo=windows&logoColor=white)
![GUI](https://img.shields.io/badge/Interface-WPF-3B82F6?logo=windows&logoColor=white)
![License](https://img.shields.io/badge/Licence-MIT-green)
![Status](https://img.shields.io/badge/Statut-Actif-brightgreen)
![Quick Launch](https://img.shields.io/badge/Lancement-1%20commande%20PowerShell-5391FE?logo=powershell&logoColor=white)

**Application graphique PowerShell d'initialisation et de durcissement d'un poste client Windows 11.**
Un seul fichier `.ps1`, aucune installation : configuration réseau, renommage et jonction au domaine, mappage de lecteurs réseau, et durcissement **à la carte** selon les référentiels **CIS Benchmark** ou **ANSSI BP‑028**.

> ⚠️ **Avertissement** : le module de durcissement applique un **sous‑ensemble représentatif** de mesures inspirées de CIS et de l'ANSSI. Il ne constitue **ni une implémentation exhaustive ni une certification de conformité**. Testez toujours sur un poste pilote avant tout déploiement ; en production, privilégiez GPO / Microsoft Intune.

---

## ⚡ Quick Launch

Ouvrez **PowerShell** (une console utilisateur standard suffit : l'élévation est automatique) et collez :

```powershell
irm https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1 | iex
```

Rien à cloner, rien à décompresser : le script est téléchargé et exécuté **en mémoire**, demande les droits administrateur (UAC), puis **ouvre sa fenêtre**.

<details>
<summary>Que fait exactement cette commande ?</summary>

| Étape | Détail |
|-------|--------|
| `irm` | `Invoke-RestMethod` télécharge le **texte** du script depuis GitHub (aucun fichier écrit sur le disque). |
| `\| iex` | `Invoke-Expression` exécute ce texte dans la session PowerShell courante. La stratégie d'exécution (`Restricted`) ne s'applique pas : aucun fichier `.ps1` n'est chargé. |
| Élévation | Si la console n'est pas administrateur, le script relance **la même commande** dans une fenêtre élevée (`Start-Process powershell -Verb RunAs` + `-Command`), en conservant `-NoProfile -ExecutionPolicy Bypass -STA`. |
| Interface | La fenêtre WPF s'ouvre : catégories à gauche, interrupteurs au centre, journal temps réel en bas. |

</details>

> 💡 Version figée (recommandé en production) : remplacez `main` par un tag de release, par exemple
> `.../Win11-Baseline/v2.0.0/Init-WindowsClient11.ps1`.

---

## Sommaire

- [Quick Launch](#-quick-launch)
- [L'interface](#linterface)
- [Fonctionnalités](#fonctionnalités)
- [Catalogue des actions](#catalogue-des-actions)
- [Niveaux de durcissement](#niveaux-de-durcissement)
- [Mode sans interface (déploiement)](#mode-sans-interface-déploiement)
- [Journalisation](#journalisation)
- [Prérequis](#prérequis)
- [Installation locale](#installation-locale)
- [Architecture technique](#architecture-technique)
- [Avertissements et limites](#avertissements-et-limites)
- [Contribuer](#contribuer)
- [Licence](#licence)

---

## L'interface

<!-- TODO : remplacer par une vraie capture — Win + Maj + S, puis déposer l'image dans docs/screenshot.png -->
<p align="center">
  <img src="docs/screenshot.png" alt="Interface de Win11-Baseline" width="900">
  <br>
  <em>Placeholder — capture d'écran à ajouter dans <code>docs/screenshot.png</code></em>
</p>

L'application reprend le modèle de **[WinUtil](https://github.com/ChrisTitusTech/winutil)** : thème sombre, navigation latérale par catégories, interrupteurs par mesure, exécution en arrière‑plan et journal temps réel.

| Zone | Rôle |
|------|------|
| **En‑tête** | Version, nom du poste, utilisateur, mode d'exécution et **badge d'élévation** (vert = administrateur). |
| **Navigation latérale** | Six catégories : *Système et réseau*, *Sécurité — Socle / Intermédiaire / Élevé / Renforcé*, *Préréglages*. |
| **Liste d'actions** | Un interrupteur par mesure, avec info‑bulle explicative et **pastilles** : `Sensible`, `Risque élevé`, `Redémarrage`. |
| **Boutons de catégorie** | *Tout sélectionner* / *Tout désélectionner* dans chaque onglet de sécurité. |
| **Préréglages** | Un clic coche les mesures d'un niveau CIS ou ANSSI ; le détail reste ajustable ensuite. |
| **Progression** | Barre, libellé de l'action en cours et compteur d'actions restantes. |
| **Journal** | Défilement temps réel des commandes et de leurs résultats, avec bouton d'ouverture du fichier de log. |
| **Pied de page** | Compteur de sélection, *Annuler la sélection* (rollback) et **Appliquer la baseline**. |

L'interface reste **réactive pendant l'exécution** : tout le travail se fait dans un runspace séparé. Fermer la fenêtre en cours d'exécution demande une confirmation.

---

## Fonctionnalités

- **Sélection à la carte** — chaque mesure de durcissement est un interrupteur indépendant, avec description et niveau de risque.
- **Préréglages en un clic** — CIS L1 / L2 et ANSSI Minimal / Intermédiaire / Élevé / Renforcé (niveaux cumulatifs).
- **Formulaires intégrés** — configuration IP, renommage, jonction de domaine et mappage de lecteur se saisissent dans la fenêtre, plus aucune question en console.
- **Découverte AD sans RSAT** — les partages publiés dans l'annuaire (objets `volume`) sont listés via `System.DirectoryServices`, en tâche de fond.
- **Point de restauration** — proposé avant application, coché automatiquement avec un préréglage.
- **Annulation** — la plupart des mesures disposent d'une fonction de retour à la valeur par défaut de Windows (bouton *Annuler la sélection*).
- **Auto‑élévation** — UAC demandé automatiquement, y compris en exécution `irm | iex`.
- **Mode sans interface** — `-NoGUI` pour Intune, GPO ou SCCM, avec code de sortie.
- **Journalisation complète** — fichier horodaté dans `%LOCALAPPDATA%\Win11-Baseline\logs\`.

---

## Catalogue des actions

35 actions réparties en cinq catégories. La liste complète, avec identifiants et niveaux de risque, s'obtient sans droits particuliers :

```powershell
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -ListActions
```

| Catégorie | Contenu |
|-----------|---------|
| **Système et réseau** | Point de restauration, configuration IP, renommage, jonction AD, mappage de lecteur, `EnableLinkedConnections` |
| **Sécurité — Socle** | Pare‑feu, SMBv1 off, UAC, AutoRun off, compte Invité off, politique de mots de passe, Defender |
| **Sécurité — Intermédiaire** | Signature SMB, NTLM durci, accès anonyme restreint, LLMNR off, journalisation PowerShell, audit, verrouillage écran |
| **Sécurité — Élevé** | WDigest off, LSASS PPL, audit 4688, transcription PowerShell, RDP NLA, assistance distante off, *Controlled Folder Access*, signature LDAP, cache d'ouvertures de session |
| **Sécurité — Renforcé** | Règles ASR, VBS / Credential Guard, effacement du pagefile, PowerShell v2 off, `RemoteSigned`, bannière légale |

Les mesures qui peuvent **casser un usage** portent une pastille `Sensible` ou `Risque élevé`, et une confirmation récapitule les mesures à risque élevé avant application.

---

## Niveaux de durcissement

Les niveaux sont **cumulatifs** (un niveau supérieur inclut les précédents).

### CIS Benchmark

| Niveau | Cible | Contenu principal |
|--------|-------|-------------------|
| **L1 — Sécurité de base** | Majorité des postes | Socle + Intermédiaire |
| **L2 — Défense en profondeur** | Environnements sensibles | L1 + mesures Élevé |

### ANSSI BP‑028

| Niveau | Cible | Contenu principal |
|--------|-------|-------------------|
| **Minimal** | Postes exposés à Internet, données peu sensibles | Socle |
| **Intermédiaire** | Réseau d'entreprise standard | Socle + Intermédiaire |
| **Élevé** | Données sensibles (RH, finance, R&D) | + mesures Élevé |
| **Renforcé** | OIV, défense | + mesures Renforcé |

> Les mesures s'appliquent **localement** (stratégies machine du registre + cmdlets natives), ce qui convient aussi bien à un poste autonome qu'à un membre de domaine.

---

## Mode sans interface (déploiement)

Pour Intune, une GPO de démarrage, SCCM ou tout scénario non interactif :

```powershell
# Un niveau complet
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -NoGUI -Preset ANSSI-Eleve

# Des mesures précises
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -NoGUI -Actions SEC-Firewall,SEC-SMB1Off,SEC-LLMNR

# Depuis un fichier local
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Init-WindowsClient11.ps1 -NoGUI -Preset CIS-L1
```

| Paramètre | Rôle |
|-----------|------|
| `-NoGUI` (alias `-CLI`) | Exécute sans interface, sans aucune interaction. |
| `-Preset <niveau>` | `CIS-L1`, `CIS-L2`, `ANSSI-Minimal`, `ANSSI-Intermediaire`, `ANSSI-Eleve`, `ANSSI-Renforce`. |
| `-Actions <id,...>` | Identifiants d'actions, cumulables avec `-Preset`. |
| `-ListActions` | Affiche le catalogue et quitte (aucun droit requis). |

**Code de sortie** : `0` si aucune erreur, `1` si au moins une action a échoué, `2` si un identifiant est inconnu.

> La forme `irm ... | iex` **ne transmet pas de paramètres** : utilisez `&([scriptblock]::Create((irm '<url>'))) -NoGUI ...`.
> Les actions de type formulaire (IP, renommage, jonction, mappage) exigent des saisies : elles sont **ignorées** en mode sans interface et signalées dans le journal.

---

## Journalisation

Chaque session écrit un fichier horodaté :

```
%LOCALAPPDATA%\Win11-Baseline\logs\AAAA-MM-JJ_HH-mm-ss.log
```

Format `[heure] [niveau] message`, niveaux `INFO` / `RUN` / `OK` / `WARN` / `ERR` / `STEP`. Le même flux alimente le panneau de journal de la fenêtre. Le résumé de fin propose d'ouvrir le fichier.

---

## Prérequis

- **Windows 11** (cmdlets natives, aucune dépendance externe).
- **Windows PowerShell 5.1** (inclus dans Windows 11). Fonctionne aussi sous PowerShell 7 lancé en `-STA`.
- **Droits administrateur** (le script s'auto‑élève).
- **.NET Framework / WPF** : présents en standard sur Windows 11.
- La découverte AD utilise `System.DirectoryServices` : **RSAT n'est pas requis**.

---

## Installation locale

Inutile avec le [Quick Launch](#-quick-launch). L'installation locale sert pour un poste **sans accès Internet**, un déploiement depuis une **clé USB**, ou pour travailler sur une version modifiée.

```bash
git clone https://github.com/QuentinABG/Win11-Baseline.git
```

Gardez les deux fichiers dans le même dossier :

- `Init-WindowsClient11.ps1` — l'application
- `Lancer-Init-WindowsClient11.cmd` — le lanceur (double‑clic, contourne l'`ExecutionPolicy`)

> ⚠️ Le fichier `.ps1` doit rester encodé en **UTF‑8 avec BOM** : Windows PowerShell 5.1 lit sinon les accents en ANSI et l'interface s'affiche avec des caractères erronés.

---

## Architecture technique

Fichier unique, sections délimitées : `# CONFIG` / `# FONCTIONS` / `# CATALOGUE` / `# XAML` / `# GUI` / `# LOGIQUE`.

| Brique | Mise en œuvre |
|--------|---------------|
| **Interface** | XAML intégré en here‑string, chargé par `[Windows.Markup.XamlReader]::Load()`, affiché par `ShowDialog()` sur un thread **STA**. |
| **État partagé** | `$sync = [Hashtable]::Synchronized(@{})` — unique canal entre le thread UI et les runspaces. |
| **Exécution** | `RunspacePool` dont l'`InitialSessionState` reçoit `$sync` et toutes les fonctions `*W11B*`. L'instance PowerShell est libérée via `RegisterWaitForSingleObject` (pas de fuite de runspace). |
| **Journal & progression** | Les runspaces écrivent dans une `ConcurrentQueue` ; un `DispatcherTimer` (150 ms) la draine côté UI. Aucun contrôle WPF n'est touché depuis un runspace. |
| **Catalogue** | Source unique de vérité : l'interface est **générée** à partir de `$sync.Catalog`. Le catalogue ne stocke que des **noms de fonctions** (jamais des `scriptblock`, qui traversent mal les runspaces). |
| **Fonctions d'action** | Pures, sans dépendance à la GUI, donc réutilisables en CLI. Chacune lève une exception en cas d'échec ; le wrapper journalise et poursuit. |

Ajouter une mesure = ajouter une fonction `Invoke-W11B<Nom>` (et éventuellement `Undo-W11B<Nom>`) puis une entrée dans `$sync.Catalog`. Elle apparaît automatiquement dans l'interface et devient utilisable via `-Actions`.

---

## Avertissements et limites

- **Ce n'est pas une certification de conformité.** CIS et ANSSI comportent des centaines de contrôles ; ce projet en applique un sous‑ensemble représentatif et raisonnablement sûr.
- **Testez sur un poste pilote.** Les mesures marquées `Risque élevé` (*Controlled Folder Access*, règles ASR, VBS / Credential Guard, cache d'ouvertures de session) peuvent bloquer des usages métier ou, sur du matériel non compatible, empêcher le démarrage.
- **Annulation partielle.** Les mesures de registre et de service savent revenir au défaut Windows. Les actions de type formulaire (jonction de domaine, renommage, configuration IP) **ne sont pas réversibles** automatiquement.
- **Jonction de domaine.** Elle n'est effective **qu'après redémarrage** : la découverte AD des partages publiés ne fonctionnera pas dans la même session.
- **Contexte élevé (UAC).** Un lecteur mappé en administrateur peut ne pas apparaître immédiatement en session standard ; l'action `EnableLinkedConnections` corrige ce point (redémarrage requis).
- Pour un **parc**, le durcissement et le mappage de lecteurs se déploient idéalement via **GPO** ou **Intune**.

---

## Contribuer

Les contributions sont les bienvenues. Ouvrez une *issue* pour signaler un bug ou proposer une mesure, ou soumettez une *pull request*. Merci de préciser la version de Windows et de PowerShell utilisée pour tout rapport de bug, et de joindre l'extrait de journal correspondant.

---

## Licence

Distribué sous licence **MIT**. Voir le fichier [`LICENSE`](LICENSE) pour les détails.

---

<p align="center">
  Réalisé avec PowerShell — pour l'administration et la sécurisation de postes Windows 11.
</p>
