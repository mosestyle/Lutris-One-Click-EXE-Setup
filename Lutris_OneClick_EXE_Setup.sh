#!/usr/bin/env bash
set -euo pipefail

APP_ID="net.lutris.Lutris"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
SERVICE_DIR="$HOME/.local/share/kio/servicemenus"
HELPER="$BIN_DIR/lutris-exe-helper"
APP_DESKTOP="$APP_DIR/lutris-exe-installer.desktop"
SERVICE_DESKTOP="$SERVICE_DIR/lutris-exe-update.desktop"
REMOVE_APP_DESKTOP="$APP_DIR/lutris-complete-game-remove.desktop"
REMOVE_HELPER="$BIN_DIR/lutris-complete-game-remove"
STEAM_REPAIR_DESKTOP="$APP_DIR/lutris-steam-shortcut-repair.desktop"
TOOLS_DESKTOP="$APP_DIR/lutris-oneclick-tools.desktop"
DATA_DIR="$HOME/.local/share/lutris-oneclick"
TOOLS_GUI="$DATA_DIR/lutris_oneclick_tools.py"
OLD_SERVICE="$SERVICE_DIR/lutris-exe.desktop"

refresh_kde() {
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
  kbuildsycoca6 >/dev/null 2>&1 || true
}

uninstall_all() {
  echo "Removing Lutris one-click EXE integration..."
  rm -f "$HELPER" "$REMOVE_HELPER" "$APP_DESKTOP" "$SERVICE_DESKTOP" "$REMOVE_APP_DESKTOP" "$STEAM_REPAIR_DESKTOP" "$TOOLS_DESKTOP" "$OLD_SERVICE"
  rm -rf "$DATA_DIR"

  if command -v flatpak >/dev/null 2>&1 && flatpak info com.usebottles.bottles >/dev/null 2>&1; then
    for mime in \
      application/x-ms-dos-executable \
      application/x-msdownload \
      application/vnd.microsoft.portable-executable
    do
      xdg-mime default com.usebottles.bottles.desktop "$mime" >/dev/null 2>&1 || true
    done
  fi

  refresh_kde
  echo "Done. Your Lutris games and Wine prefixes were NOT removed."
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall_all
  exit 0
fi

if ! command -v flatpak >/dev/null 2>&1; then
  echo "ERROR: Flatpak was not found."
  exit 1
fi

if ! flatpak info "$APP_ID" >/dev/null 2>&1; then
  echo "ERROR: The Flatpak/Discover version of Lutris is not installed."
  echo "Install Lutris from Discover first, then run this setup again."
  exit 1
fi

if ! command -v kdialog >/dev/null 2>&1; then
  echo "ERROR: kdialog was not found."
  exit 1
fi

mkdir -p "$BIN_DIR" "$APP_DIR" "$SERVICE_DIR" "$DATA_DIR" "$HOME/.cache/lutris-exe-helper"

cat > "$HELPER" <<'__PYHELPER_41C2__'
#!/usr/bin/env python3

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

APP_ID = "net.lutris.Lutris"
CACHE_DIR = Path.home() / ".cache/lutris-exe-helper"
CACHE_DIR.mkdir(parents=True, exist_ok=True)


def dialog(args):
    result = subprocess.run(["kdialog", *args], text=True, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout.rstrip("\n")


def error(message):
    subprocess.run(["kdialog", "--error", message])


def database_path():
    candidates = [
        Path.home() / ".var/app/net.lutris.Lutris/data/lutris/pga.db",
        Path.home() / ".local/share/lutris/pga.db",
    ]
    for path in candidates:
        if path.exists():
            return path
    return None



def get_max_game_id():
    db = database_path()
    if not db:
        return 0
    try:
        conn = sqlite3.connect(db)
        try:
            row = conn.execute(
                "SELECT MAX(CAST(id AS INTEGER)) FROM games"
            ).fetchone()
            return int(row[0] or 0)
        finally:
            conn.close()
    except Exception:
        return 0


def steam_is_running():
    try:
        result = subprocess.run(
            ["pgrep", "-x", "steam"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return True

        # Steam's launcher process can occasionally have a different visible
        # command name while the client is still alive.
        result = subprocess.run(
            ["pgrep", "-f", r"(^|/)steam(\s|$)|steamwebhelper"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return result.returncode == 0
    except Exception:
        return False


def wait_for_steam_to_stop(timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not steam_is_running():
            return True
        time.sleep(0.5)
    return not steam_is_running()


def stop_steam_cleanly():
    if not steam_is_running():
        return True

    steam = shutil.which("steam")
    if not steam:
        return False

    try:
        subprocess.run(
            [steam, "-shutdown"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        pass
    except Exception:
        return False

    return wait_for_steam_to_stop()


def start_steam():
    steam = shutil.which("steam")
    if not steam:
        return False

    try:
        subprocess.Popen(
            [steam, "-silent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except Exception:
        try:
            subprocess.Popen(
                [steam],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return True
        except Exception:
            return False


def create_or_repair_steam_shortcut(game_id):
    """Use Lutris' own Steam shortcut implementation after Steam is stopped."""
    inside_flatpak = r"""
import os
import sys
import traceback

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

wrapper = "/app/share/lutris/bin/lutris-wrapper"
if not os.path.isfile(wrapper):
    raise FileNotFoundError(
        f"Expected Lutris wrapper was not found at {wrapper}"
    )

sys.argv[0] = "/app/bin/lutris"

from lutris.game import Game
from lutris.util.steam import shortcut as steam_shortcut

game_id = sys.argv[1]

try:
    game = Game(game_id)

    if not game.id:
        raise RuntimeError("The selected Lutris game could not be loaded.")
    if not game.is_installed:
        raise RuntimeError("The selected Lutris game is not installed.")
    if not game.config:
        raise RuntimeError("The selected Lutris game has no configuration.")

    # Avoid duplicates/stale entries, then create the primary shortcut
    # exactly through Lutris' own shortcut implementation.
    steam_shortcut.remove_shortcut(game)
    steam_shortcut.create_shortcut(game, "")

except Exception:
    traceback.print_exc()
    sys.exit(1)
"""

    return subprocess.run(
        [
            "flatpak", "run", "--command=python3", APP_ID, "-c",
            inside_flatpak, str(game_id)
        ],
        text=True,
        capture_output=True,
    )


def repair_shortcut_with_steam_restart(
    game_id,
    game_name,
    ask=True,
    close_steam=True,
    reopen_steam=True,
):
    """Create/repair a Lutris Steam shortcut.

    Automatic installs can leave Desktop Steam running. The new shortcut will
    then be picked up the next time Steam reloads, such as when entering
    Gaming Mode.
    """
    if ask:
        confirm = subprocess.run(
            [
                "kdialog",
                "--title", "Add to Steam Gaming Mode",
                "--yesno",
                f"{game_name} is ready.\\n\\n"
                "Add/repair its Steam shortcut now?\\n\\n"
                "Steam may need to close briefly so the shortcut database can be updated."
            ]
        )
        if confirm.returncode != 0:
            return False

    steam_was_running = steam_is_running()

    if steam_was_running and close_steam:
        if not stop_steam_cleanly():
            error(
                "Steam could not be closed automatically.\\n\\n"
                "Nothing was changed. You can use "
                "'Lutris Steam Shortcut Repair' later."
            )
            return False

        # Give Steam a moment to finish saving its own shortcut database.
        time.sleep(1.5)

    result = create_or_repair_steam_shortcut(game_id)

    if result.returncode != 0:
        log_file = CACHE_DIR / "last-steam-shortcut-error.txt"
        log_file.write_text(
            (result.stdout or "") + "\\n\\nSTDERR:\\n" + (result.stderr or ""),
            encoding="utf-8",
        )

        if steam_was_running and close_steam and reopen_steam:
            start_steam()

        error(
            "The Steam shortcut could not be created.\\n\\n"
            "Steam was not left closed.\\n\\n"
            f"Technical log:\\n{log_file}"
        )
        return False

    if steam_was_running and close_steam and reopen_steam:
        start_steam()

    if steam_was_running and not close_steam:
        popup_text = (
            f"{game_name} was added to Steam.\\n"
            "It may not appear in Desktop Steam immediately. "
            "Return to Gaming Mode normally and it should appear there."
        )
    elif steam_was_running and close_steam and not reopen_steam:
        popup_text = (
            f"{game_name} was added to Steam.\\n"
            "Steam was left closed — just Return to Gaming Mode when you're ready."
        )
    else:
        popup_text = (
            f"{game_name} was added to Steam. "
            "It should appear under Non-Steam games / Gaming Mode."
        )

    # Automatic post-install shortcut creation should be completely silent.
    # Manual repair mode can still show feedback if explicitly requested.
    if ask:
        subprocess.run(
            [
                "kdialog",
                "--passivepopup",
                popup_text,
                "5",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return True


def find_completed_install(unique_config_prefix, game_name, min_id):
    db = database_path()
    if not db:
        return None

    conn = sqlite3.connect(db)
    try:
        # Best match: config path generated by THIS exact one-click install.
        row = conn.execute(
            """
            SELECT id, name, installed, runner, configpath
            FROM games
            WHERE configpath LIKE ?
            ORDER BY CAST(id AS INTEGER) DESC
            LIMIT 1
            """,
            (unique_config_prefix + "%",),
        ).fetchone()

        if row and int(row[2] or 0) == 1:
            return str(row[0]), row[1]

        # Fallback for future Lutris changes that rename config paths.
        row = conn.execute(
            """
            SELECT id, name, installed, runner, configpath
            FROM games
            WHERE CAST(id AS INTEGER) > ?
              AND name = ?
            ORDER BY CAST(id AS INTEGER) DESC
            LIMIT 1
            """,
            (int(min_id), game_name),
        ).fetchone()

        if row and int(row[2] or 0) == 1:
            return str(row[0]), row[1]

        return None
    finally:
        conn.close()


def watch_install_and_offer_steam(unique_config_prefix, game_name, min_id):
    # Poll lightly in the background. If the user cancels the installer,
    # this watcher simply expires without changing anything.
    deadline = time.time() + (6 * 60 * 60)

    while time.time() < deadline:
        try:
            match = find_completed_install(
                unique_config_prefix, game_name, min_id
            )
        except Exception:
            match = None

        if match:
            game_id, detected_name = match

            # Let Lutris finish its final DB/config flush.
            time.sleep(3)

            # One-click behavior:
            # - no confirmation popup
            # - DO NOT close Desktop Steam
            # - write/repair the shortcut immediately
            # - Steam will pick it up naturally when it next reloads,
            #   e.g. when the user enters Gaming Mode
            repair_shortcut_with_steam_restart(
                game_id,
                detected_name or game_name,
                ask=False,
                close_steam=False,
                reopen_steam=False,
            )
            return

        time.sleep(5)


def launch_install_watcher(unique_config_prefix, game_name, min_id):
    log_file = CACHE_DIR / "steam-shortcut-watcher.log"

    try:
        log = open(log_file, "a", encoding="utf-8")
        subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "watchsteam",
                unique_config_prefix,
                game_name,
                str(min_id),
            ],
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
        log.close()
    except Exception:
        # Installer itself should still work even if the optional watcher
        # cannot be launched.
        pass


def list_games_for_steam_repair():
    db = database_path()
    if not db:
        return []

    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            """
            SELECT id, name
            FROM games
            WHERE installed = 1
              AND runner != 'steam'
              AND configpath IS NOT NULL
              AND configpath != ''
            ORDER BY name COLLATE NOCASE
            """
        ).fetchall()
    finally:
        conn.close()


def steam_shortcut_repair_menu():
    if not database_path():
        error(
            "Could not find the Lutris game database.\\n\\n"
            "Open Lutris once, close it, and try again."
        )
        return

    try:
        games = list_games_for_steam_repair()
    except Exception as exc:
        error(f"Could not read Lutris game list:\\n\\n{exc}")
        return

    if not games:
        error("No installed non-Steam Lutris games were found.")
        return

    args = ["--menu", "Choose a game to add/repair in Steam:"]
    for game_id, name in games:
        args.extend([str(game_id), name])

    game_id = dialog(args)
    if not game_id:
        return

    name = next(
        (name for gid, name in games if str(gid) == str(game_id)),
        "Selected game",
    )

    repair_shortcut_with_steam_restart(
        str(game_id),
        name,
        ask=True,
        close_steam=True,
        reopen_steam=True,
    )


def force_steam_shortcut_default_on():
    code = r'''
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
import os, sys
if os.path.isfile("/app/share/lutris/bin/lutris-wrapper"):
    sys.argv[0] = "/app/bin/lutris"
from lutris import settings
settings.write_setting("installer_create_steam_shortcut", True)
'''
    subprocess.run(
        ["flatpak", "run", "--command=python3", APP_ID, "-c", code],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def derive_default_name(exe: Path):
    name = exe.stem.strip()
    generic = {
        "setup", "setup64", "setup_x64", "setup-x64", "install", "installer",
        "gameinstaller", "game-installer", "start", "launcher"
    }
    if name.lower() in generic and exe.parent.name:
        name = exe.parent.name
    name = re.sub(r"[_\.]+", " ", name)
    name = re.sub(r"\s+", " ", name).strip()
    return name or "New Lutris Game"


def install_new(exe: Path):
    game_name = dialog([
        "--inputbox",
        "Name for the new Lutris game:",
        derive_default_name(exe),
    ])
    if not game_name:
        return

    slug = re.sub(r"[^a-z0-9]+", "-", game_name.lower()).strip("-") or "local-game"
    stamp = int(time.time())

    installer = {
        "name": game_name,
        "game_slug": slug,
        "version": "Local setup",
        "slug": f"{slug}-local-{stamp}",
        "runner": "wine",
        "script": {
            "game": {
                "exe": "_xXx_AUTO_WIN32_xXx_",
                "prefix": "$GAMEDIR",
            },
            "installer": [
                {
                    "task": {
                        "name": "wineexec",
                        "executable": str(exe),
                        "working_dir": str(exe.parent),
                        "arch": "win64",
                    }
                }
            ],
        },
    }

    installer_file = CACHE_DIR / f"{slug}-{stamp}.yml"
    installer_file.write_text(json.dumps(installer, indent=2), encoding="utf-8")

    # Remember where the database was before this install so the background
    # watcher can reliably identify the game that THIS installer creates.
    min_game_id = get_max_game_id()

    # Keep Lutris' normal checkbox enabled too.
    force_steam_shortcut_default_on()

    subprocess.Popen(
        ["flatpak", "run", APP_ID, "-i", str(installer_file)],
        start_new_session=True,
    )

    # After the installation is actually marked complete by Lutris, offer to
    # create/repair the Steam shortcut and restart Steam automatically.
    launch_install_watcher(
        f"{slug}-local-{stamp}",
        game_name,
        min_game_id,
    )


def list_installed_wine_games():
    db = database_path()
    if not db:
        return []
    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            """
            SELECT id, name
            FROM games
            WHERE installed = 1
              AND runner = 'wine'
              AND configpath IS NOT NULL
              AND configpath != ''
            ORDER BY name COLLATE NOCASE
            """
        ).fetchall()
    finally:
        conn.close()


def run_existing(exe: Path):
    if not database_path():
        error("Could not find the Lutris game database.\n\nOpen Lutris once, close it, and try again.")
        return

    try:
        games = list_installed_wine_games()
    except Exception as exc:
        error(f"Could not read Lutris game list:\n\n{exc}")
        return

    if not games:
        error("No installed Lutris Wine games were found.")
        return

    args = ["--menu", "Run this EXE inside which Lutris game?"]
    for game_id, name in games:
        args.extend([str(game_id), name])

    game_id = dialog(args)
    if not game_id:
        return

    inside_flatpak = r'''
import os
import sys
import traceback

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

wrapper = "/app/share/lutris/bin/lutris-wrapper"
if not os.path.isfile(wrapper):
    raise FileNotFoundError(f"Expected Lutris wrapper was not found at {wrapper}")

sys.argv[0] = "/app/bin/lutris"

from lutris.game import Game
from lutris.runners.commands.wine import wineexec

game_id = sys.argv[1]
exe = os.path.abspath(sys.argv[2])

try:
    game = Game(game_id)

    if not game.is_installed:
        raise RuntimeError("Selected game is not installed.")
    if game.runner_name != "wine":
        raise RuntimeError("Selected game is not using the Wine runner.")

    runner = game.runner
    if not runner.prefix_path:
        raise RuntimeError("Lutris could not determine this game's Wine prefix.")

    runner.prelaunch()

    wineexec(
        exe,
        wine_path=runner.get_executable(),
        prefix=runner.prefix_path,
        arch=runner.wine_arch,
        working_dir=os.path.dirname(exe),
        config=runner,
        env=runner.get_env(os_env=True),
        runner=runner,
        blocking=True,
    )
except Exception:
    traceback.print_exc()
    sys.exit(1)
'''

    result = subprocess.run(
        [
            "flatpak", "run", "--command=python3", APP_ID, "-c",
            inside_flatpak, str(game_id), str(exe)
        ],
        text=True,
        capture_output=True,
    )

    if result.returncode != 0:
        log_file = CACHE_DIR / "last-update-error.txt"
        log_file.write_text(
            (result.stdout or "") + "\n\nSTDERR:\n" + (result.stderr or ""),
            encoding="utf-8",
        )
        error(
            "The update could not be started.\n\n"
            "I saved the exact technical error here:\n\n"
            f"{log_file}\n\n"
            "Send that file if you need troubleshooting."
        )


def lutris_is_running():
    try:
        result = subprocess.run(
            ["flatpak", "ps", "--columns=application"],
            text=True,
            capture_output=True,
        )
        return APP_ID in result.stdout.split()
    except Exception:
        return False


def close_lutris_for_removal(timeout=15):
    """Close the Flatpak Lutris app automatically before editing its database."""
    if not lutris_is_running():
        return True

    try:
        subprocess.run(
            ["flatpak", "kill", APP_ID],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except Exception:
        pass

    deadline = time.time() + timeout
    while time.time() < deadline:
        if not lutris_is_running():
            # Give SQLite/config writes a moment to finish settling.
            time.sleep(0.75)
            return True
        time.sleep(0.25)

    return not lutris_is_running()


def list_installed_wine_games_for_removal():
    db = database_path()
    if not db:
        return []

    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            '''
            SELECT id, name, directory
            FROM games
            WHERE installed = 1
              AND runner = 'wine'
              AND directory IS NOT NULL
              AND directory != ''
              AND configpath IS NOT NULL
              AND configpath != ''
            ORDER BY name COLLATE NOCASE
            '''
        ).fetchall()
    finally:
        conn.close()


def safe_game_directory(path_text):
    if not path_text:
        raise RuntimeError("Lutris did not provide a game directory.")

    raw = Path(os.path.expanduser(path_text))
    if not raw.is_absolute():
        raise RuntimeError(f"The game directory is not an absolute path:\\n\\n{raw}")

    if raw.is_symlink():
        raise RuntimeError(
            "The game directory is a symbolic link.\\n\\n"
            "For safety, this helper will not permanently delete symlinked game folders.\\n\\n"
            f"Path:\\n{raw}"
        )

    path = raw.resolve(strict=False)
    home = Path.home().resolve()

    protected = {
        Path("/"),
        Path("/home"),
        Path("/var"),
        Path("/mnt"),
        Path("/media"),
        Path("/run"),
        home,
        home / "Games",
        home / "Desktop",
        home / "Documents",
        home / "Downloads",
        home / "Pictures",
        home / "Videos",
    }

    if path in protected:
        raise RuntimeError(
            "Refusing to delete a protected folder.\\n\\n"
            f"Path:\\n{path}"
        )

    if len(path.parts) < 4:
        raise RuntimeError(
            "Refusing to permanently delete this path because it is too close "
            "to a filesystem root.\\n\\n"
            f"Path:\\n{path}"
        )

    return path


def remove_lutris_entry(game_id):
    inside_flatpak = r'''
import os
import sys
import traceback

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

wrapper = "/app/share/lutris/bin/lutris-wrapper"
if not os.path.isfile(wrapper):
    raise FileNotFoundError(f"Expected Lutris wrapper was not found at {wrapper}")

sys.argv[0] = "/app/bin/lutris"

from lutris.game import Game

game_id = sys.argv[1]

try:
    game = Game(game_id)

    # Let Lutris remove its own config and Steam shortcut.
    # delete_files=False deliberately avoids Lutris' Trash operation.
    if game.is_installed:
        game.uninstall(delete_files=False)

    if game.id is not None:
        game.delete()

except Exception:
    traceback.print_exc()
    sys.exit(1)
'''

    return subprocess.run(
        [
            "flatpak", "run", "--command=python3", APP_ID, "-c",
            inside_flatpak, str(game_id)
        ],
        text=True,
        capture_output=True,
    )


def complete_remove():
    # Make the removal tool one-click: if Lutris is open, close it automatically
    # before reading/modifying the game database.
    if not close_lutris_for_removal():
        error(
            "Lutris could not be closed automatically.\\n\\n"
            "Please close Lutris manually and try again."
        )
        return

    if not database_path():
        error("Could not find the Lutris game database.\\n\\nOpen Lutris once, close it, and try again.")
        return

    try:
        games = list_installed_wine_games_for_removal()
    except Exception as exc:
        error(f"Could not read the Lutris game list:\\n\\n{exc}")
        return

    if not games:
        error("No installed Lutris Wine games were found.")
        return

    game_map = {str(game_id): (name, directory) for game_id, name, directory in games}

    args = ["--menu", "Choose the Lutris game to completely remove:"]
    for game_id, name, directory in games:
        args.extend([str(game_id), f"{name}   —   {directory}"])

    game_id = dialog(args)
    if not game_id:
        return

    name, directory = game_map[game_id]

    try:
        game_path = safe_game_directory(directory)
    except Exception as exc:
        error(str(exc))
        return

    first = subprocess.run(
        [
            "kdialog",
            "--warningyesno",
            "Remove this game from Lutris?\\n\\n"
            f"{name}\\n\\n"
            "This will remove its Lutris entry, configuration and Steam shortcut.\\n\\n"
            f"Game folder:\\n{game_path}\\n\\n"
            "The game files will NOT be deleted until you confirm a second time."
        ]
    )
    if first.returncode != 0:
        return

    result = remove_lutris_entry(game_id)

    if result.returncode != 0:
        log_file = CACHE_DIR / "last-remove-error.txt"
        log_file.write_text(
            (result.stdout or "") + "\\n\\nSTDERR:\\n" + (result.stderr or ""),
            encoding="utf-8",
        )
        error(
            "Lutris could not remove the game entry.\\n\\n"
            "No game files were deleted.\\n\\n"
            "Technical log:\\n"
            f"{log_file}"
        )
        return

    if not game_path.exists():
        subprocess.run([
            "kdialog", "--msgbox",
            f"{name} was removed from Lutris and its Steam shortcut was removed.\\n\\n"
            "The game folder was already missing, so there were no files to delete."
        ])
        return

    second = subprocess.run(
        [
            "kdialog",
            "--title", "Permanent deletion",
            "--warningyesno",
            "PERMANENTLY DELETE THESE GAME FILES?\\n\\n"
            f"{name}\\n\\n"
            f"{game_path}\\n\\n"
            "This bypasses Lutris' Trash operation and deletes the folder directly.\\n\\n"
            "THIS CANNOT BE UNDONE."
        ]
    )
    if second.returncode != 0:
        subprocess.run([
            "kdialog", "--msgbox",
            f"{name} was removed from Lutris and Steam, but its files were kept at:\\n\\n{game_path}"
        ])
        return

    try:
        shutil.rmtree(game_path)
    except Exception as exc:
        error(
            "The Lutris entry and Steam shortcut were removed, but the game folder "
            "could not be deleted.\\n\\n"
            f"Path:\\n{game_path}\\n\\n"
            f"Error:\\n{exc}"
        )
        return

    subprocess.run([
        "kdialog", "--msgbox",
        f"{name} was completely removed.\\n\\n"
        "Removed:\\n"
        "• Lutris library entry\\n"
        "• Lutris game configuration\\n"
        "• Steam shortcut\\n"
        f"• Game folder: {game_path}"
    ])


def main():
    if len(sys.argv) < 2:
        sys.exit(2)

    mode = sys.argv[1]

    if mode == "tools":
        if len(sys.argv) != 3:
            sys.exit(2)

        gui_path = Path(sys.argv[2]).expanduser().resolve()
        if not gui_path.is_file():
            error(f"Tools GUI was not found:\n\n{gui_path}")
            return

        # Close the normal Lutris application if it is open. This prevents
        # stale in-memory library data while still letting the Tools window
        # run as its own Python process inside the Lutris Flatpak.
        close_lutris_for_removal()

        subprocess.Popen(
            [
                "flatpak",
                "run",
                "--command=python3",
                APP_ID,
                str(gui_path),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return

    if mode == "remove":
        if len(sys.argv) != 2:
            sys.exit(2)
        complete_remove()
        return

    if mode == "steamrepair":
        if len(sys.argv) != 2:
            sys.exit(2)
        steam_shortcut_repair_menu()
        return

    if mode == "watchsteam":
        if len(sys.argv) != 5:
            sys.exit(2)
        watch_install_and_offer_steam(
            sys.argv[2],
            sys.argv[3],
            int(sys.argv[4]),
        )
        return

    if len(sys.argv) != 3:
        sys.exit(2)

    exe = Path(sys.argv[2]).expanduser().resolve()
    if not exe.is_file():
        error(f"EXE not found:\n\n{exe}")
        sys.exit(1)

    if mode == "new":
        install_new(exe)
    elif mode == "existing":
        run_existing(exe)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
__PYHELPER_41C2__

chmod +x "$HELPER"

cat > "$TOOLS_GUI" <<'__TOOLS_GUI_4A91__'
#!/usr/bin/env python3

import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")

from gi.repository import Gtk, Gdk, GLib

# Lutris imports must happen after forcing GTK 3.
sys.argv[0] = "/app/bin/lutris"

from lutris.game import Game
from lutris.util.steam import shortcut as steam_shortcut


APP_ID = "net.lutris.Lutris"


def database_path():
    candidates = [
        Path.home() / ".var/app/net.lutris.Lutris/data/lutris/pga.db",
        Path.home() / ".local/share/lutris/pga.db",
    ]
    for path in candidates:
        if path.exists():
            return path
    return None


def list_games():
    db = database_path()
    if not db:
        return []

    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            """
            SELECT id, name, directory, runner
            FROM games
            WHERE installed = 1
              AND runner != 'steam'
              AND configpath IS NOT NULL
              AND configpath != ''
            ORDER BY name COLLATE NOCASE
            """
        ).fetchall()
    finally:
        conn.close()


def safe_game_directory(path_text):
    if not path_text:
        raise RuntimeError("Lutris did not provide a game folder for this game.")

    raw = Path(os.path.expanduser(path_text))

    if not raw.is_absolute():
        raise RuntimeError(f"The game folder is not an absolute path:\n\n{raw}")

    if raw.is_symlink():
        raise RuntimeError(
            "For safety, symbolic-link game folders are not permanently deleted."
        )

    path = raw.resolve(strict=False)
    home = Path.home().resolve()

    protected = {
        Path("/"),
        Path("/home"),
        Path("/var"),
        Path("/usr"),
        Path("/opt"),
        Path("/tmp"),
        home,
        home / "Games",
        home / "Desktop",
        home / "Downloads",
        home / "Documents",
    }

    if path in protected or len(path.parts) < 4:
        raise RuntimeError(
            "Refusing to permanently delete this protected folder:\n\n"
            f"{path}"
        )

    # Installed Lutris games are normally under the user's home directory.
    # Refuse anything outside HOME to reduce risk.
    try:
        path.relative_to(home)
    except ValueError:
        raise RuntimeError(
            "For safety, this tool will only permanently delete game folders "
            "inside your home directory."
        )

    return path


def message(parent, title, text, kind=Gtk.MessageType.INFO):
    dlg = Gtk.MessageDialog(
        transient_for=parent,
        modal=True,
        destroy_with_parent=True,
        message_type=kind,
        buttons=Gtk.ButtonsType.OK,
        text=title,
    )
    dlg.format_secondary_text(text)
    dlg.run()
    dlg.destroy()


def confirm(parent, title, text, destructive=False):
    dlg = Gtk.MessageDialog(
        transient_for=parent,
        modal=True,
        destroy_with_parent=True,
        message_type=Gtk.MessageType.WARNING if destructive else Gtk.MessageType.QUESTION,
        buttons=Gtk.ButtonsType.NONE,
        text=title,
    )
    dlg.format_secondary_text(text)
    dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    yes = dlg.add_button(
        "Delete permanently" if destructive else "Continue",
        Gtk.ResponseType.OK,
    )

    if destructive:
        yes.get_style_context().add_class("destructive-action")
    else:
        yes.get_style_context().add_class("suggested-action")

    response = dlg.run()
    dlg.destroy()
    return response == Gtk.ResponseType.OK


class OneClickTools(Gtk.Window):
    def __init__(self):
        super().__init__(title="Lutris One-Click Tools")

        # IMPORTANT:
        # Do NOT use Gtk.HeaderBar / client-side decorations here.
        # SteamOS KDE/X11 can produce ugly drag ghosting with GTK3 CSD.
        # Let KWin draw the normal native title bar instead.
        self.set_default_size(540, 360)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_icon_name("net.lutris.Lutris")
        self.set_decorated(True)
        self.set_type_hint(Gdk.WindowTypeHint.NORMAL)

        settings = Gtk.Settings.get_default()
        if settings:
            try:
                settings.set_property("gtk-application-prefer-dark-theme", False)
                settings.set_property("gtk-theme-name", "Adwaita")
            except Exception:
                pass

        self.install_css()

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        root.get_style_context().add_class("window-root")
        self.add(root)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        body.set_border_width(26)
        root.pack_start(body, True, True, 0)

        # Header area
        title = Gtk.Label()
        title.set_markup(
            "<span size='x-large' weight='bold'>Manage your Lutris games</span>"
        )
        title.set_xalign(0)
        title.set_margin_bottom(4)
        body.pack_start(title, False, False, 0)

        subtitle = Gtk.Label(
            label="Repair Steam integration or completely remove an installed game."
        )
        subtitle.set_xalign(0)
        subtitle.set_line_wrap(True)
        subtitle.set_margin_bottom(24)
        subtitle.get_style_context().add_class("subtitle")
        body.pack_start(subtitle, False, False, 0)

        # Game selector label — deliberately OUTSIDE the bordered selector.
        selector_label = Gtk.Label(label="SELECT GAME")
        selector_label.set_xalign(0)
        selector_label.set_margin_bottom(7)
        selector_label.get_style_context().add_class("section-label")
        body.pack_start(selector_label, False, False, 0)

        selector_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        selector_row.set_margin_bottom(22)
        body.pack_start(selector_row, False, False, 0)

        self.combo = Gtk.ComboBoxText()
        self.combo.set_hexpand(True)
        selector_row.pack_start(self.combo, True, True, 0)

        refresh = Gtk.Button()
        refresh.set_tooltip_text("Refresh game list")
        refresh.set_size_request(44, 42)
        refresh_image = Gtk.Image.new_from_icon_name(
            "view-refresh-symbolic", Gtk.IconSize.BUTTON
        )
        refresh.add(refresh_image)
        refresh.connect("clicked", lambda *_: self.refresh_games())
        refresh.get_style_context().add_class("icon-button")
        selector_row.pack_start(refresh, False, False, 0)

        # Actions
        actions_label = Gtk.Label(label="ACTIONS")
        actions_label.set_xalign(0)
        actions_label.set_margin_bottom(7)
        actions_label.get_style_context().add_class("section-label")
        body.pack_start(actions_label, False, False, 0)

        actions_panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        actions_panel.get_style_context().add_class("actions-panel")
        body.pack_start(actions_panel, False, False, 0)

        self.install_btn = Gtk.Button()
        self.install_btn.set_hexpand(True)
        self.install_btn.set_size_request(-1, 46)
        self.install_btn.get_style_context().add_class("primary")
        self.install_btn.connect("clicked", self.on_install)

        install_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        install_box.set_halign(Gtk.Align.CENTER)
        install_icon = Gtk.Image.new_from_icon_name(
            "list-add-symbolic", Gtk.IconSize.BUTTON
        )
        install_text = Gtk.Label(label="Install Game")
        install_text.get_style_context().add_class("button-label")
        install_box.pack_start(install_icon, False, False, 0)
        install_box.pack_start(install_text, False, False, 0)
        self.install_btn.add(install_box)
        actions_panel.pack_start(self.install_btn, False, False, 0)

        self.repair_btn = Gtk.Button()
        self.repair_btn.set_hexpand(True)
        self.repair_btn.set_size_request(-1, 46)
        self.repair_btn.get_style_context().add_class("secondary")
        self.repair_btn.connect("clicked", self.on_repair)

        repair_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        repair_box.set_halign(Gtk.Align.CENTER)
        repair_icon = Gtk.Image.new_from_icon_name(
            "emblem-synchronizing-symbolic", Gtk.IconSize.BUTTON
        )
        repair_text = Gtk.Label(label="Repair Steam Shortcut")
        repair_text.get_style_context().add_class("button-label")
        repair_box.pack_start(repair_icon, False, False, 0)
        repair_box.pack_start(repair_text, False, False, 0)
        self.repair_btn.add(repair_box)
        actions_panel.pack_start(self.repair_btn, False, False, 0)

        self.remove_btn = Gtk.Button()
        self.remove_btn.set_hexpand(True)
        self.remove_btn.set_size_request(-1, 46)
        self.remove_btn.get_style_context().add_class("danger")
        self.remove_btn.connect("clicked", self.on_remove)

        remove_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        remove_box.set_halign(Gtk.Align.CENTER)
        remove_icon = Gtk.Image.new_from_icon_name(
            "user-trash-symbolic", Gtk.IconSize.BUTTON
        )
        remove_text = Gtk.Label(label="Complete Game Removal")
        remove_text.get_style_context().add_class("button-label")
        remove_box.pack_start(remove_icon, False, False, 0)
        remove_box.pack_start(remove_text, False, False, 0)
        self.remove_btn.add(remove_box)
        actions_panel.pack_start(self.remove_btn, False, False, 0)

        self.status = Gtk.Label(label="")
        self.status.set_xalign(0)
        self.status.set_line_wrap(True)
        self.status.set_margin_top(16)
        self.status.get_style_context().add_class("status")
        body.pack_start(self.status, False, False, 0)

        self.games = {}
        self.refresh_games()

    def install_css(self):
        css = b"""
        window, .window-root {
            background-color: #f6f7f9;
            color: #202124;
        }

        .subtitle {
            color: #70757a;
            font-size: 10.5pt;
        }

        .section-label {
            color: #6b7075;
            font-size: 8.5pt;
            font-weight: 700;
            letter-spacing: 0.7px;
        }

        combobox button {
            min-height: 40px;
            padding-left: 12px;
            padding-right: 12px;
            background-image: none;
            background-color: #ffffff;
            color: #202124;
            border: 1px solid #cfd3d8;
            border-radius: 7px;
            box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
        }

        combobox button:hover {
            border-color: #aeb4ba;
            background-color: #ffffff;
        }

        button.icon-button {
            min-width: 42px;
            min-height: 40px;
            padding: 0;
            background-image: none;
            background-color: #ffffff;
            color: #4b5156;
            border: 1px solid #cfd3d8;
            border-radius: 7px;
        }

        button.icon-button:hover {
            background-color: #f0f2f4;
        }

        .actions-panel {
            background-color: transparent;
        }

        button.primary {
            min-height: 44px;
            background-image: none;
            background-color: #2f80ed;
            color: #ffffff;
            border: 1px solid #2f80ed;
            border-radius: 7px;
            box-shadow: none;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        button.primary label,
        button.primary image {
            color: #ffffff;
            text-shadow: none;
            -gtk-icon-shadow: none;
            box-shadow: none;
        }

        button.primary:hover {
            background-color: #1f6fd5;
            border-color: #1f6fd5;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        button.primary:active {
            background-color: #195fb8;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        button.secondary {
            min-height: 44px;
            background-image: none;
            background-color: #ffffff;
            color: #2f6fbd;
            border: 1px solid #b9cbe0;
            border-radius: 7px;
            box-shadow: none;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        button.secondary label,
        button.secondary image {
            color: #2f6fbd;
            text-shadow: none;
            -gtk-icon-shadow: none;
            box-shadow: none;
        }

        button.secondary:hover {
            background-color: #f3f8fd;
            border-color: #8fb2da;
        }

        button.secondary:active {
            background-color: #e6f0fa;
        }

        button.danger {
            min-height: 44px;
            background-image: none;
            background-color: #ffffff;
            color: #c62828;
            border: 1px solid #e1b4b4;
            border-radius: 7px;
            box-shadow: none;
        }

        button.danger:hover {
            background-color: #fff4f4;
            border-color: #d98c8c;
        }

        button.danger:active {
            background-color: #fde8e8;
        }

        .button-label {
            font-weight: 600;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        .status {
            color: #6b7075;
            font-size: 9.5pt;
        }

        .success {
            color: #2e7d32;
        }
        """

        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        screen = Gdk.Screen.get_default()
        if screen:
            Gtk.StyleContext.add_provider_for_screen(
                screen,
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
            )

    def selected_game(self):
        game_id = self.combo.get_active_id()
        if not game_id:
            return None
        return self.games.get(game_id)

    def set_status(self, text, success=False):
        self.status.set_text(text)
        ctx = self.status.get_style_context()
        if success:
            ctx.add_class("success")
        else:
            ctx.remove_class("success")

    def refresh_games(self, preferred_id=None):
        self.combo.remove_all()
        self.games.clear()

        try:
            rows = list_games()
        except Exception as exc:
            self.repair_btn.set_sensitive(False)
            self.remove_btn.set_sensitive(False)
            self.set_status(f"Could not read Lutris library: {exc}")
            return

        for game_id, name, directory, runner in rows:
            sid = str(game_id)
            self.games[sid] = {
                "id": sid,
                "name": name,
                "directory": directory or "",
                "runner": runner or "",
            }
            self.combo.append(sid, name)

        enabled = bool(self.games)
        self.repair_btn.set_sensitive(enabled)
        self.remove_btn.set_sensitive(enabled)

        if not enabled:
            self.combo.append("", "No installed Lutris games found")
            self.combo.set_active(0)
            self.combo.set_sensitive(False)
            self.set_status("No installed Lutris games were found.")
            return

        self.combo.set_sensitive(True)

        if preferred_id and preferred_id in self.games:
            self.combo.set_active_id(preferred_id)
        else:
            self.combo.set_active(0)

        self.set_status("")

    def on_install(self, _button):
        chooser = Gtk.FileChooserDialog(
            title="Choose Windows Game Installer",
            parent=self,
            action=Gtk.FileChooserAction.OPEN,
        )
        chooser.add_button("Cancel", Gtk.ResponseType.CANCEL)
        open_button = chooser.add_button("Install", Gtk.ResponseType.OK)
        open_button.get_style_context().add_class("suggested-action")

        exe_filter = Gtk.FileFilter()
        exe_filter.set_name("Windows executables (*.exe)")
        exe_filter.add_pattern("*.exe")
        exe_filter.add_pattern("*.EXE")
        chooser.add_filter(exe_filter)

        all_filter = Gtk.FileFilter()
        all_filter.set_name("All files")
        all_filter.add_pattern("*")
        chooser.add_filter(all_filter)

        response = chooser.run()
        filename = chooser.get_filename()
        chooser.destroy()

        if response != Gtk.ResponseType.OK or not filename:
            return

        exe = Path(filename).expanduser().resolve()

        if not exe.is_file():
            message(
                self,
                "Installer could not be opened",
                f"The selected file no longer exists:\\n\\n{exe}",
                Gtk.MessageType.ERROR,
            )
            return

        if exe.suffix.lower() != ".exe":
            if not confirm(
                self,
                "This file is not an .exe",
                f"{exe.name}\\n\\nContinue anyway?",
            ):
                return

        helper = Path.home() / ".local/bin/lutris-exe-helper"

        if not helper.is_file():
            message(
                self,
                "One-Click installer helper was not found",
                str(helper),
                Gtk.MessageType.ERROR,
            )
            return

        # The Tools GUI itself runs inside the Lutris Flatpak.
        # Ask Flatpak to run our existing host-side helper, so this follows
        # EXACTLY the same install path as double-click/Open with Lutris Installer.
        try:
            subprocess.Popen(
                [
                    "flatpak-spawn",
                    "--host",
                    str(helper),
                    "new",
                    str(exe),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as exc:
            message(
                self,
                "Could not start the Lutris installer",
                str(exc),
                Gtk.MessageType.ERROR,
            )
            return

        self.set_status(
            f"Opening Lutris installer for {exe.name}…",
            success=True,
        )


    def on_repair(self, _button):
        item = self.selected_game()
        if not item:
            return

        self.repair_btn.set_sensitive(False)
        self.set_status(f"Creating Steam shortcut for {item['name']}…")

        while Gtk.events_pending():
            Gtk.main_iteration_do(False)

        try:
            game = Game(item["id"])

            if not game.id or not game.is_installed:
                raise RuntimeError("Lutris could not load this installed game.")

            # Mimic Lutris' own Create Steam Shortcut action.
            # Steam stays running; the shortcut appears after Steam next reloads.
            steam_shortcut.remove_shortcut(game)
            steam_shortcut.create_shortcut(game, "")

            self.set_status(
                f"Steam shortcut repaired for {item['name']}. "
                "It will appear after Steam next reloads / when you enter Gaming Mode.",
                success=True,
            )

        except Exception as exc:
            message(
                self,
                "Steam shortcut could not be created",
                str(exc),
                Gtk.MessageType.ERROR,
            )
            self.set_status("Steam shortcut repair failed.")
        finally:
            self.repair_btn.set_sensitive(True)

    def on_remove(self, _button):
        item = self.selected_game()
        if not item:
            return

        name = item["name"]

        try:
            game_path = safe_game_directory(item["directory"])
        except Exception as exc:
            message(
                self,
                "This game cannot be permanently removed safely",
                str(exc),
                Gtk.MessageType.ERROR,
            )
            return

        if not confirm(
            self,
            f"Remove {name}?",
            "This will remove the Lutris library entry, configuration and "
            "Steam shortcut.\n\n"
            f"Game folder:\n{game_path}\n\n"
            "Your game files are not deleted until the second confirmation.",
        ):
            return

        self.remove_btn.set_sensitive(False)
        self.repair_btn.set_sensitive(False)
        self.set_status(f"Removing {name} from Lutris…")

        while Gtk.events_pending():
            Gtk.main_iteration_do(False)

        try:
            game = Game(item["id"])

            if game.is_installed:
                # Avoid Lutris' broken Trash path. We delete the exact game
                # directory ourselves only after the second confirmation.
                game.uninstall(delete_files=False)

            if game.id is not None:
                game.delete()

        except Exception as exc:
            message(
                self,
                "Lutris could not remove the game",
                f"No game files were permanently deleted.\n\n{exc}",
                Gtk.MessageType.ERROR,
            )
            self.refresh_games()
            return

        if game_path.exists():
            if not confirm(
                self,
                "Permanently delete game files?",
                f"{name}\n\n{game_path}\n\n"
                "This deletes the folder directly and cannot be undone.",
                destructive=True,
            ):
                self.set_status(
                    f"{name} was removed from Lutris and Steam, but its files were kept at {game_path}."
                )
                self.refresh_games()
                return

            try:
                shutil.rmtree(game_path)
            except Exception as exc:
                message(
                    self,
                    "Game entry removed, but files could not be deleted",
                    f"Folder:\n{game_path}\n\n{exc}",
                    Gtk.MessageType.ERROR,
                )
                self.refresh_games()
                return

        # Keep this window open and refresh immediately for multi-game removal.
        self.refresh_games()
        self.set_status(
            f"{name} was completely removed. You can choose another game.",
            success=True,
        )


def main():
    win = OneClickTools()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()

__TOOLS_GUI_4A91__

chmod +x "$TOOLS_GUI"

# Dedicated launcher for complete game removal. This is intentionally separate
# from the .exe file handler so KDE Plasma can index it as a normal application.
cat > "$REMOVE_HELPER" <<'__REMOVEHELPER_5D91__'
#!/usr/bin/env bash
exec "$HOME/.local/bin/lutris-exe-helper" remove
__REMOVEHELPER_5D91__
chmod +x "$REMOVE_HELPER"

cat > "$APP_DESKTOP" <<__APPDESKTOP_73A0__
[Desktop Entry]
Type=Application
Name=Lutris Installer
Comment=Install Windows EXE files as new Lutris games
Icon=net.lutris.Lutris
Exec=$HELPER new %f
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/x-msdownload;application/vnd.microsoft.portable-executable;
Categories=Game;
StartupNotify=true
__APPDESKTOP_73A0__

cat > "$SERVICE_DESKTOP" <<__SERVICEMENU_D58F__
[Desktop Entry]
Type=Service
MimeType=application/x-ms-dos-executable;application/x-msdownload;application/vnd.microsoft.portable-executable;
Actions=lutrisExisting;
X-KDE-Priority=TopLevel

[Desktop Action lutrisExisting]
Name=Run as Lutris game update / patch
Icon=net.lutris.Lutris
Exec=$HELPER existing %f
__SERVICEMENU_D58F__

chmod +x "$SERVICE_DESKTOP"

# Remove legacy standalone launchers from older versions.
rm -f "$REMOVE_APP_DESKTOP" "$STEAM_REPAIR_DESKTOP" "$REMOVE_HELPER"

cat > "$TOOLS_DESKTOP" <<__TOOLS_DESKTOP_7B31__
[Desktop Entry]
Type=Application
Version=1.0
Name=Lutris One-Click Tools
GenericName=Lutris Game Tools
Comment=Repair Steam shortcuts and completely remove Lutris games
Icon=net.lutris.Lutris
Exec=$HELPER tools $TOOLS_GUI
TryExec=$HELPER
Terminal=false
NoDisplay=false
Categories=Game;Utility;
Keywords=Lutris;Steam;Shortcut;Repair;Remove;Uninstall;Games;
StartupNotify=true
X-KDE-StartupNotify=true
__TOOLS_DESKTOP_7B31__

chmod +x "$TOOLS_DESKTOP"
rm -f "$OLD_SERVICE"

for mime in \
  application/x-ms-dos-executable \
  application/x-msdownload \
  application/vnd.microsoft.portable-executable
do
  xdg-mime default lutris-exe-installer.desktop "$mime" || true
done

refresh_kde

echo
echo "============================================================"
echo " Lutris One-Click EXE integration installed successfully!"
echo "============================================================"
echo
echo "NEW GAME:"
echo "  Double-click any .exe -> Lutris Installer"
echo "  Lutris will default 'Create Steam shortcut' to ON."
echo "  When installation finishes, the helper automatically adds/repairs"
echo "  the Steam shortcut with no question."
echo "  Desktop Steam stays running — it is NOT closed or restarted."
echo "  The shortcut appears after Steam next reloads, such as when"
echo "  you choose Return to Gaming Mode."
echo
echo "UPDATE / PATCH:"
echo "  Right-click update.exe -> Run as Lutris game update / patch"
echo "  Choose the installed game -> same existing Wine prefix/drive_c"
echo
echo "LUTRIS ONE-CLICK TOOLS:"
echo "  Application Launcher -> Lutris One-Click Tools"
echo "  One clean native KDE-framed window for:"
echo "    - Install Game"
echo "    - Repair Steam Shortcut"
echo "    - Complete Game Removal"
echo "  The window stays open after removal so you can manage multiple games."
echo "  If Plasma has not refreshed yet, run: $REMOVE_HELPER"
echo
echo "Close all Dolphin windows and open Dolphin again once."
echo
echo "To remove this integration later:"
echo "  bash \"$0\" --uninstall"
echo
