# Lutris One-Click EXE

<img width="539" height="489" alt="image" src="https://github.com/user-attachments/assets/22916fb4-918a-4723-8ed7-e0644ea82719" />

A small SteamOS/KDE helper for standalone Windows `.exe` games using **Lutris Flatpak**.

## Features

- **Double-click `Setup.exe`** → install a new Lutris game.
- Automatically creates its **Steam / Gaming Mode shortcut** after installation.
- No Steam restart and no success popup.
- Right-click `Update.exe` → **Run as Lutris game update / patch** → uses the existing Wine prefix / `drive_c`.
- **Lutris One-Click Tools** provides one clean GUI with:
  - Install Game
  - Repair Steam Shortcut
  - Complete Game Removal
- **Install Game** opens a file picker and sends the selected `.exe` through the same One-Click installer used by double-click/Open with Lutris Installer.
- The Tools window stays open after removing a game so you can manage several games in one session.
- Complete Removal bypasses Lutris' SteamOS/Flatpak Trash issue and asks twice before permanently deleting game files.
- Uses the normal KDE window frame to avoid GTK3 drag/ghosting artifacts.

## Requirements

- SteamOS / KDE Plasma
- Lutris installed from **Discover / Flatpak**

## Install

### Option 1 — Konsole

```bash
bash "$HOME/Downloads/Lutris_OneClick_EXE_Setup_V4.2.sh"
```

### Option 2 — Right-click → Run in Konsole

1. Right-click `Lutris_OneClick_EXE_Setup_V4.2.sh`
2. **Properties → Permissions**
3. Enable **Is executable**
4. Right-click again → **Run in Konsole**

Then close and reopen Dolphin once.

## Usage

<img width="392" height="548" alt="image" src="https://github.com/user-attachments/assets/a4b04a55-7078-41ae-8307-fbbd3d698d08" />

**Install:** double-click `Setup.exe` **or** open **Lutris One-Click Tools → Install Game**.

**Update / patch:** right-click the updater → **Run as Lutris game update / patch** → choose the game.

**Manage games:** Application Launcher → **Lutris One-Click Tools**.

## Uninstall this integration

```bash
bash "$HOME/Downloads/Lutris_OneClick_EXE_Uninstall_V4.2.sh"
```

This removes only the helper. It does **not** delete your Lutris games, prefixes, or existing Steam shortcuts.
