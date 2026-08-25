# One-Click EXE
A small SteamOS/KDE helper for standalone Windows `.exe` games using **Steam / Proton by default**, with **Lutris / Wine** available as an alternative backend.

<img width="663" height="630" alt="image" src="https://github.com/user-attachments/assets/49f695dc-24c1-4582-91dc-03bf8364a71a" />   <img width="548" height="427" alt="image" src="https://github.com/user-attachments/assets/286f9ebf-d08a-466c-81e3-f8fd4580f71d" />


## Features

- **Double-click a Windows `.exe`** → opens the One-Click installer with three choices:
  - **Install as a new game**
  - **Update an installed game**
  - **Add existing game to Steam (no install)**
- **Steam / Proton is the default backend.** New games are installed into their own Steam Proton prefix and become normal non-Steam shortcuts that can later use Proton Experimental, GE-Proton or another compatibility tool from Steam Properties.
- **Lutris / Wine remains available** as an alternative backend for games or installers that work better through Lutris.
- The installer window has its own **Steam / Proton ↔ Lutris / Wine selector**, so you can change backend for one installation without changing your saved default.
- Automatically creates the final **Steam / Gaming Mode shortcut** after installation.
- Normal Steam-native installs and updates do **not force-restart Steam**. Pending shortcut changes are finalized when Steam naturally closes/restarts, such as when returning to Gaming Mode.
- Smart update detection recognizes names containing words such as **Update, Patch, Hotfix** and preselects the update workflow.
- Updates run inside the existing game's current Steam Proton or Lutris Wine prefix instead of creating a separate `drive_c`.
- Right-click an updater `.exe` → **Run as game update / patch** → choose the installed game.
- Right-click a folder → **Find Game EXE + Add to Steam** → recursively finds likely game executables and creates a shortcut without installing anything.
- Right-click a folder → **Find Game EXE + Install** → recursively finds likely installer/update executables and opens the normal One-Click installer dialog.
- Smart folder scanning filters setup/uninstall/redist/helper files when looking for a game EXE, but deliberately prioritizes `setup.exe` / installer files when using **Find EXE + Install**.
- Smart game-name detection uses the EXE path and cleans common version/platform/release-folder noise.
- Automatic artwork support:
  - **Official Steam artwork first** when available.
  - **SteamGridDB fallback** when official Steam artwork is unavailable.
  - Downloads and applies **Capsule, Wide Capsule, Hero, Logo and Icon**.
  - Artwork is cached so unchanged images are not downloaded again.
  - SteamGridDB matching uses the game name, EXE/folder hints and safe aliases.
  - A one-time **Which game is this?** chooser appears only when a manual artwork attempt finds **no artwork at all**.
- **One-Click Tools** provides one clean GUI with:
  - Install Game
  - **Play Game**
  - Repair Steam Shortcut
  - Download + Apply All Artworks
  - Complete Game Removal
- Multiple games can be selected for batch repair, artwork and removal. **Play Game** is available when exactly one game is selected.
- Complete Removal can remove the game entry, Steam shortcut, custom artwork, One-Click artwork cache and related One-Click metadata; permanent game-file deletion is separately confirmed.
- **Settings** includes:
  - Default installer backend
  - Saved SteamGridDB API key
  - Open Selected Game Folder
  - Clean Failed Steam Installs
  - Current One-Click EXE version
- Failed Steam-native installs are tracked so incomplete One-Click Proton prefixes can be cleaned without blindly deleting unrelated Steam `compatdata` folders.
- Uses normal KDE/GTK window frames and a consistent One-Click light/blue interface.

## Requirements

- SteamOS / KDE Plasma
- Steam
- Lutris installed from **Discover / Flatpak**
- Proton Experimental available in Steam for the default Steam-native install workflow
- A free SteamGridDB API key is optional but recommended for games whose official Steam artwork is unavailable

## Install

### Option 1 — Konsole

```bash
bash "$HOME/Downloads/OneClick_EXE_V6.7.17/OneClick_EXE_Setup_V6.7.17.sh"
```

### Option 2 — Right-click → Run in Konsole

1. Right-click `OneClick_EXE_Setup_V6.7.17.sh`
2. **Properties → Permissions**
3. Enable **Is executable**
4. Right-click again → **Run in Konsole**

Then close and reopen Dolphin once so KDE refreshes the One-Click context-menu actions.

## Usage

<img width="391" height="545" alt="image" src="https://github.com/user-attachments/assets/bf8091d1-eabd-4149-a4e1-bb28d6717a68" />

**Install a new game:** double-click its installer `.exe` **or** open **One-Click Tools → Install Game**. Choose Steam / Proton or Lutris / Wine if you want to override the default for that installation.

**Update / patch:** double-click the updater and choose **Update an installed game**, or right-click it → **Run as game update / patch** → choose the game.

**Already have a complete game folder:** right-click the folder → **Find Game EXE + Add to Steam**, or double-click the game's `.exe` and choose **Add existing game to Steam (no install)**.

**Find an installer inside a large folder:** right-click the folder → **Find Game EXE + Install**. One-Click scans nested folders, lets you choose the EXE, then opens the normal installer menu.

**Manage games:** Application Launcher → **One-Click Tools**.

**Play a game:** select one game in One-Click Tools → **Play Game**. Steam-native games use the already-running Steam client; One-Click does not start/restart Steam from the Play button.

**Artwork:** select one or more games → **Download + Apply All Artworks**. Configure your SteamGridDB API key once under **Settings**.

## Uninstall this integration

```bash
bash "$HOME/Downloads/OneClick_EXE_V6.7.17/OneClick_EXE_Uninstall_V6.7.17.sh"
```

This removes the One-Click helper, integration files, settings and One-Click caches. It does **not** delete your installed games, Steam Proton prefixes, Lutris Wine prefixes or existing Steam shortcuts.
