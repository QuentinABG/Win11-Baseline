# Win11-Baseline

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Windows-11-0078D6?logo=windows&logoColor=white)
![License](https://img.shields.io/badge/Licence-MIT-green)

Application graphique PowerShell pour initialiser et durcir un poste client Windows 11. Un seul fichier `.ps1`, aucune installation : configuration réseau, jonction au domaine, mappage de lecteurs, et durcissement **à la carte** selon **CIS Benchmark** ou **ANSSI BP‑028**.

> ⚠️ Sous‑ensemble représentatif de mesures CIS / ANSSI — **ni exhaustif, ni une certification de conformité**. Testez sur un poste pilote ; en production, privilégiez GPO / Intune.

---

## Lancement

```powershell
irm https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1 | iex
```

---

## Interface

<p align="center">
  <img src="docs/screenshot.png" alt="Interface de Win11-Baseline" width="900">
  <br>
  <em>Capture d'écran à ajouter dans <code>docs/screenshot.png</code></em>
</p>

Modèle [WinUtil](https://github.com/ChrisTitusTech/winutil) : thème sombre, navigation latérale, un interrupteur par mesure (info‑bulle + pastille `Sensible` / `Risque élevé` / `Redémarrage`), journal temps réel repliable. L'exécution se fait dans un runspace séparé — la fenêtre reste réactive.

Les étapes qui demandent une saisie (IP, renommage, jonction AD, mappage) ont un formulaire dédié dans l'onglet *Système et réseau*.

---

## Catalogue

35 actions. Liste complète avec identifiants et niveaux de risque :

```powershell
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -ListActions
```

| Catégorie | Contenu |
|-----------|---------|
| **Système et réseau** | Point de restauration, configuration IP, renommage, jonction AD, mappage de lecteur, `EnableLinkedConnections` |
| **Socle** | Pare‑feu, SMBv1 off, UAC, AutoRun off, compte Invité off, politique de mots de passe, Defender |
| **Intermédiaire** | Signature SMB, NTLM durci, accès anonyme restreint, LLMNR off, journalisation PowerShell, audit, verrouillage écran |
| **Élevé** | WDigest off, LSASS PPL, audit 4688, transcription PowerShell, RDP NLA, assistance distante off, Controlled Folder Access, signature LDAP, cache d'ouvertures de session |
| **Renforcé** | Règles ASR, VBS / Credential Guard, effacement du pagefile, PowerShell v2 off, `RemoteSigned`, bannière légale |

**Préréglages** (cumulatifs, un clic coche le niveau) : CIS `L1` = Socle + Intermédiaire, `L2` = + Élevé — ANSSI `Minimal` = Socle, `Intermédiaire`, `Élevé`, `Renforcé` = + la catégorie du même nom.

---

## Déploiement sans interface

```powershell
# Un niveau complet
&([scriptblock]::Create((irm 'https://raw.githubusercontent.com/QuentinABG/Win11-Baseline/main/Init-WindowsClient11.ps1'))) -NoGUI -Preset ANSSI-Eleve

# Des mesures précises
&([scriptblock]::Create((irm '<url>'))) -NoGUI -Actions SEC-Firewall,SEC-SMB1Off,SEC-LLMNR
```

| Paramètre | Rôle |
|-----------|------|
| `-NoGUI` (alias `-CLI`) | Sans interface, aucune interaction. |
| `-Preset <niveau>` | `CIS-L1`, `CIS-L2`, `ANSSI-Minimal`, `ANSSI-Intermediaire`, `ANSSI-Eleve`, `ANSSI-Renforce` |
| `-Actions <id,...>` | Identifiants d'actions, cumulable avec `-Preset`. |
| `-ListActions` | Affiche le catalogue et quitte. |

Codes de sortie : `0` succès, `1` au moins un échec, `2` identifiant inconnu.

> `irm ... | iex` ne transmet pas de paramètres : utilisez la forme `&([scriptblock]::Create(...))`.
> Les actions de type formulaire sont ignorées en mode `-NoGUI` (saisies impossibles).

---

## Prérequis

Windows 11 et Windows PowerShell 5.1 — aucune dépendance externe, RSAT non requis. Le script s'auto‑élève.

## Journal

`%LOCALAPPDATA%\Win11-Baseline\logs\AAAA-MM-JJ_HH-mm-ss.log`, un fichier par session.

## Usage hors ligne

`git clone` puis double‑clic sur `Lancer-Init-WindowsClient11.cmd` (contourne l'`ExecutionPolicy`).

> ⚠️ Le `.ps1` est en **ASCII pur, sans BOM** — ne le ré‑enregistrez pas en UTF‑8 avec BOM, cela casse `irm | iex`. Les accents de l'interface sont stockés échappés (`&#233;`) et décodés à l'exécution.

---

## Limites

- Les mesures `Risque élevé` (Controlled Folder Access, ASR, VBS / Credential Guard, cache d'ouvertures de session) peuvent bloquer un usage métier ou, sur matériel non compatible, empêcher le démarrage.
- L'annulation couvre les mesures de registre et de service. Jonction de domaine, renommage et configuration IP **ne sont pas réversibles** automatiquement.
- Une jonction de domaine n'est effective qu'après redémarrage : la découverte AD des partages ne fonctionne pas dans la même session.

---

## Licence

MIT — voir [`LICENSE`](LICENSE).
