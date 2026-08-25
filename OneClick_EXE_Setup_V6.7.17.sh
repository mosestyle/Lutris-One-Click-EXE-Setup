#!/usr/bin/env bash
set -euo pipefail

APP_ID="net.lutris.Lutris"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
SERVICE_DIR="$HOME/.local/share/kio/servicemenus"
HELPER="$BIN_DIR/lutris-exe-helper"
LUTRIS_STEAM_WRAPPER="$BIN_DIR/oneclick-lutris-steam-launch"
APP_DESKTOP="$APP_DIR/lutris-exe-installer.desktop"
SERVICE_DESKTOP="$SERVICE_DIR/lutris-exe-update.desktop"
REMOVE_APP_DESKTOP="$APP_DIR/lutris-complete-game-remove.desktop"
REMOVE_HELPER="$BIN_DIR/lutris-complete-game-remove"
STEAM_REPAIR_DESKTOP="$APP_DIR/lutris-steam-shortcut-repair.desktop"
TOOLS_DESKTOP="$APP_DIR/lutris-oneclick-tools.desktop"
DATA_DIR="$HOME/.local/share/lutris-oneclick"
TOOLS_GUI="$DATA_DIR/lutris_oneclick_tools.py"
ACTION_GUI="$DATA_DIR/oneclick_action_dialog.py"
FOLDER_SERVICE_DESKTOP="$SERVICE_DIR/oneclick-add-existing-folder.desktop"
FOLDER_INSTALL_SERVICE_DESKTOP="$SERVICE_DIR/oneclick-find-exe-install.desktop"
OLD_SERVICE="$SERVICE_DIR/lutris-exe.desktop"
SGDB_CONFIG_DIR="$HOME/.var/app/net.lutris.Lutris/config/lutris-oneclick"
SGDB_CACHE_DIR="$HOME/.var/app/net.lutris.Lutris/cache/lutris-oneclick"

refresh_kde() {
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
  kbuildsycoca6 >/dev/null 2>&1 || true
}

uninstall_all() {
  echo "Removing One-Click EXE integration..."
  rm -f "$HELPER" "$LUTRIS_STEAM_WRAPPER" "$REMOVE_HELPER" "$APP_DESKTOP" "$SERVICE_DESKTOP" "$FOLDER_SERVICE_DESKTOP" "$FOLDER_INSTALL_SERVICE_DESKTOP" "$REMOVE_APP_DESKTOP" "$STEAM_REPAIR_DESKTOP" "$TOOLS_DESKTOP" "$OLD_SERVICE"
  rm -rf "$DATA_DIR"
  rm -rf "$HOME/.cache/lutris-exe-helper"
  rm -rf "$SGDB_CONFIG_DIR" "$SGDB_CACHE_DIR"

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
  echo "Done. Your installed games, Steam Proton prefixes and Lutris Wine prefixes were NOT removed."
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

import binascii
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
TOOLS_GUI_PATH = Path.home() / ".local/share/lutris-oneclick/lutris_oneclick_tools.py"
ACTION_GUI_PATH = Path.home() / ".local/share/lutris-oneclick/oneclick_action_dialog.py"
BACKGROUND_ARTWORK_LOG = CACHE_DIR / "background-artwork.log"
ACTION_DIALOG_LOG = CACHE_DIR / "action-dialog.log"
ACTION_DIALOG_INTENTIONAL_CLOSE = CACHE_DIR / "action-dialog-intentional-close"

SETTINGS_FILE = Path.home() / ".var/app/net.lutris.Lutris/config/lutris-oneclick/settings.json"
STEAM_NATIVE_REGISTRY = Path.home() / ".local/share/oneclick-exe/steam-native-games.json"
STEAM_NATIVE_LOG = CACHE_DIR / "steam-native.log"
PROTON_LOG_ROOT = CACHE_DIR / "proton-logs"
PROTON_LOG_ROOT.mkdir(parents=True, exist_ok=True)
DEFAULT_INSTALLER_BACKEND = "steam"
DEFAULT_STEAM_COMPAT_TOOL = "proton_experimental"


def load_oneclick_settings():
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {}


def installer_backend():
    backend = str(load_oneclick_settings().get("installer_backend", DEFAULT_INSTALLER_BACKEND)).strip().lower()
    return backend if backend in {"steam", "lutris"} else DEFAULT_INSTALLER_BACKEND


def load_steam_registry():
    try:
        data = json.loads(STEAM_NATIVE_REGISTRY.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            games = data.get("games", {})
            return games if isinstance(games, dict) else {}
    except Exception:
        pass
    return {}


def save_steam_registry(games):
    STEAM_NATIVE_REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    temp = STEAM_NATIVE_REGISTRY.with_suffix(".tmp")
    temp.write_text(json.dumps({"version": 1, "games": games}, indent=2, sort_keys=True), encoding="utf-8")
    temp.replace(STEAM_NATIVE_REGISTRY)


def update_steam_registry_entry(appid, **updates):
    games = load_steam_registry()
    key = str(int(appid))
    entry = dict(games.get(key) or {})
    entry.update(updates)
    entry["appid"] = int(appid)
    games[key] = entry
    save_steam_registry(games)
    return entry


def remove_steam_registry_entry(appid):
    games = load_steam_registry()
    key = str(int(appid))
    if key in games:
        games.pop(key, None)
        save_steam_registry(games)
        return True
    return False


def _safe_filename(text):
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", str(text or "game")).strip("-._")
    return value[:80] or "game"


def _new_proton_log_dir(game_name, appid, started_at):
    folder = PROTON_LOG_ROOT / f"{_safe_filename(game_name)}-{int(appid)}-{int(started_at)}"
    folder.mkdir(parents=True, exist_ok=True)
    _prune_proton_logs()
    return folder


def _prune_proton_logs(keep=10):
    try:
        dirs = sorted(
            [x for x in PROTON_LOG_ROOT.iterdir() if x.is_dir()],
            key=lambda x: x.stat().st_mtime,
            reverse=True,
        )
        for old in dirs[int(keep):]:
            shutil.rmtree(old, ignore_errors=True)
    except Exception:
        pass


def _directory_size(path):
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            for name in files:
                try:
                    total += (Path(root) / name).stat().st_size
                except OSError:
                    pass
    except Exception:
        pass
    return total


def _human_size(size):
    value = float(max(0, int(size or 0)))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024.0 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{value:.1f} TB"


ONECLICK_PREFIX_MARKER = ".oneclick-exe-prefix.json"


def _write_oneclick_prefix_marker(compatdata, appid):
    try:
        path = Path(compatdata)
        path.mkdir(parents=True, exist_ok=True)
        (path / ONECLICK_PREFIX_MARKER).write_text(
            json.dumps({"appid": int(appid), "created_at": int(time.time()), "owner": "oneclick-exe"}, indent=2),
            encoding="utf-8",
        )
    except Exception:
        pass


def _steam_shortcut_appids():
    code = r'''
from lutris.util.steam import shortcut, vdf
path = shortcut.get_shortcuts_vdf_path()
if not path:
    raise SystemExit(0)
try:
    with open(path, "rb") as f:
        root = vdf.binary_loads(f.read())
except FileNotFoundError:
    raise SystemExit(0)
for item in (root.get("shortcuts") or {}).values():
    try:
        print(int(item.get("appid", 0)) & 0xffffffff)
    except Exception:
        pass
'''
    try:
        result = subprocess.run(
            ["flatpak", "run", "--command=python3", APP_ID, "-c", code],
            text=True, capture_output=True, timeout=20,
        )
        return {int(x.strip()) for x in result.stdout.splitlines() if x.strip().isdigit()}
    except Exception:
        return set()


def _historical_oneclick_appids():
    ids = set()
    for key in load_steam_registry().keys():
        try:
            ids.add(int(key))
        except Exception:
            pass
    try:
        if STEAM_NATIVE_LOG.is_file():
            log_text = STEAM_NATIVE_LOG.read_text(encoding="utf-8", errors="replace")
            ids.update(int(x) for x in re.findall(r"/compatdata/(\d+)(?:/|\\)", log_text))
    except Exception:
        pass
    try:
        for item in PROTON_LOG_ROOT.iterdir():
            if item.is_dir():
                match = re.search(r"-(\d+)-\d+$", item.name)
                if match:
                    ids.add(int(match.group(1)))
    except Exception:
        pass
    root = steam_root_path()
    if root:
        compat_root = root / "steamapps" / "compatdata"
        try:
            for item in compat_root.iterdir():
                if item.is_dir() and item.name.isdigit() and (item / ONECLICK_PREFIX_MARKER).is_file():
                    ids.add(int(item.name))
        except Exception:
            pass
    return ids


def _safe_remove_failed_compatdata(appid, entry=None):
    entry = dict(entry or (load_steam_registry().get(str(int(appid))) or {}))
    if not entry or not bool(entry.get("cleanup_on_failure", False)):
        return 0, False
    if entry.get("final_exe"):
        return 0, False
    path_text = str(entry.get("compatdata") or "").strip()
    if not path_text:
        return 0, False
    root = steam_root_path()
    if not root:
        return 0, False
    path = Path(path_text).expanduser()
    expected = root / "steamapps" / "compatdata" / str(int(appid))
    try:
        if path.resolve() != expected.resolve():
            return 0, False
    except Exception:
        return 0, False
    if not path.exists():
        return 0, True
    size = _directory_size(path)
    shutil.rmtree(path)
    return size, True


def cleanup_tracked_failed_installs():
    """Remove orphaned One-Click Steam prefixes, including older V6 failures."""
    root = steam_root_path()
    if not root:
        return {"removed_count": 0, "bytes": 0, "removed": [], "skipped": ["Steam root not found"]}
    games = load_steam_registry()
    active_shortcuts = _steam_shortcut_appids()
    candidates = _historical_oneclick_appids()
    compat_root = root / "steamapps" / "compatdata"
    removed, skipped = [], []
    changed = False
    for appid in sorted(candidates):
        key = str(int(appid))
        entry = dict(games.get(key) or {})
        name = str(entry.get("name") or f"One-Click AppID {appid}")
        path = compat_root / key
        if int(appid) in active_shortcuts:
            skipped.append(name)
            continue
        final_exe = str(entry.get("final_exe") or "").strip()
        if final_exe and Path(final_exe).is_file():
            skipped.append(name)
            continue
        if str(entry.get("status") or "") in {"installed", "pending_steam"} and final_exe:
            skipped.append(name)
            continue
        try:
            if path.resolve() != (compat_root / key).resolve():
                skipped.append(name)
                continue
        except Exception:
            skipped.append(name)
            continue
        if not path.exists():
            if entry and str(entry.get("status") or "").startswith("install_failed"):
                entry["status"] = "install_failed_cleaned"
                entry["compatdata"] = ""
                games[key] = entry
                changed = True
            continue
        size = _directory_size(path)
        try:
            shutil.rmtree(path)
        except Exception:
            skipped.append(name)
            continue
        removed.append((name, size))
        if entry:
            entry["status"] = "install_failed_cleaned"
            entry["compatdata"] = ""
            games[key] = entry
            changed = True
    if changed:
        save_steam_registry(games)
    return {
        "removed_count": len(removed),
        "bytes": sum(size for _name, size in removed),
        "removed": [name for name, _size in removed],
        "skipped": skipped,
        "candidates": len(candidates),
    }


def steam_user_config_path():
    # Locate the active Steam user config directory via Lutris VDF helper.
    code = r'''
from lutris.util.steam import shortcut
print(shortcut.get_config_path() or "")
'''
    try:
        result = subprocess.run(
            ["flatpak", "run", "--command=python3", APP_ID, "-c", code],
            text=True,
            capture_output=True,
            timeout=20,
        )
        path = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
        return Path(path) if path else None
    except Exception:
        return None


def steam_root_path():
    config = steam_user_config_path()
    if not config:
        candidates = [Path.home() / ".local/share/Steam", Path.home() / ".steam/steam", Path.home() / ".steam/root"]
        return next((x.resolve() for x in candidates if x.exists()), None)
    try:
        return config.parents[2]
    except Exception:
        return None


def _steam_native_appid(game_name):
    # Stable across installer filenames and final EXE retargeting.
    unique = '\"OneClickSteamNative\"' + game_name.strip().casefold()
    return binascii.crc32(unique.encode("utf-8")) | 0x80000000


def _big_picture_id(appid):
    return ((int(appid) & 0xFFFFFFFF) << 32) | 0x02000000


def _steam_native_upsert_shortcut(appid, game_name, exe_path, start_dir, icon_path=""):
    code = r'''
import os, sys, shutil
from lutris.util.steam import shortcut, vdf

appid_u = int(sys.argv[1]) & 0xffffffff
appid_s = appid_u if appid_u < 0x80000000 else appid_u - 0x100000000
name, exe, startdir, icon = sys.argv[2:6]
path = shortcut.get_shortcuts_vdf_path()
if not path:
    raise RuntimeError("Steam active-user shortcuts.vdf could not be located")
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    with open(path, "rb") as f:
        root = vdf.binary_loads(f.read())
    current = list((root.get("shortcuts") or {}).values())
    backup = path + ".oneclick.bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
else:
    current = []

kept = []
for s in current:
    try:
        sid = int(s.get("appid", 0)) & 0xffffffff
    except Exception:
        sid = 0
    if sid != appid_u:
        kept.append(s)

kept.append({
    "appid": appid_s,
    "AppName": name,
    "Exe": '"' + exe + '"',
    "StartDir": '"' + startdir + '"',
    "icon": icon,
    "ShortcutPath": "",
    "LaunchOptions": "",
    "IsHidden": 0,
    "AllowDesktopConfig": 1,
    "AllowOverlay": 1,
    "OpenVR": 0,
    "Devkit": 0,
    "DevkitGameID": "",
    "DevkitOverrideAppID": 0,
    "LastPlayTime": 0,
    "FlatpakAppID": "",
    "tags": {},
})
updated = {"shortcuts": {str(i): item for i, item in enumerate(kept)}}
with open(path, "wb") as f:
    f.write(vdf.binary_dumps(updated))
print(path)
'''
    result = subprocess.run(
        ["flatpak", "run", "--command=python3", APP_ID, "-c", code,
         str(int(appid)), str(game_name), str(exe_path), str(start_dir), str(icon_path or "")],
        text=True,
        capture_output=True,
        timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "Could not update Steam shortcut").strip())
    return True


def _matching_brace_host(text, open_index):
    depth = 0
    quoted = False
    escaped = False
    for index in range(open_index, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return -1


def _find_named_vdf_block_host(text, name, start=0, end=None):
    limit = len(text) if end is None else min(len(text), end)
    match = re.search(r'"' + re.escape(str(name)) + r'"', text[start:limit], re.IGNORECASE)
    if not match:
        return None
    key_start = start + match.start()
    key_end = start + match.end()
    open_index = text.find("{", key_end, limit)
    if open_index < 0:
        return None
    close_index = _matching_brace_host(text, open_index)
    if close_index < 0 or close_index >= limit:
        return None
    return key_start, open_index, close_index


def _set_steam_compat_mapping(appid, tool=DEFAULT_STEAM_COMPAT_TOOL, only_if_missing=False):
    root = steam_root_path()
    if not root:
        raise RuntimeError("Steam installation folder could not be found")
    path = root / "config/config.vdf"
    if not path.is_file():
        raise RuntimeError(f"Steam config.vdf was not found: {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    outer = _find_named_vdf_block_host(text, "CompatToolMapping")
    if not outer:
        raise RuntimeError("Steam CompatToolMapping section was not found")
    _, outer_open, outer_close = outer
    entry = _find_named_vdf_block_host(text, str(int(appid)), outer_open + 1, outer_close)
    if entry and only_if_missing:
        return False
    if entry:
        key_start, _, entry_close = entry
        line_start = text.rfind("\n", 0, key_start) + 1
        remove_end = entry_close + 1
        while remove_end < len(text) and text[remove_end] in " \t":
            remove_end += 1
        if remove_end < len(text) and text[remove_end] == "\r":
            remove_end += 1
        if remove_end < len(text) and text[remove_end] == "\n":
            remove_end += 1
        text = text[:line_start] + text[remove_end:]
        outer = _find_named_vdf_block_host(text, "CompatToolMapping")
        _, outer_open, outer_close = outer
    snippet = (
        f'\n\t\t\t\t\t\t"{int(appid)}"\n'
        '\t\t\t\t\t\t{\n'
        f'\t\t\t\t\t\t\t"name"\t\t"{tool}"\n'
        '\t\t\t\t\t\t\t"config"\t\t""\n'
        '\t\t\t\t\t\t\t"Priority"\t\t"250"\n'
        '\t\t\t\t\t\t}\n'
    )
    text = text[:outer_close] + snippet + text[outer_close:]
    backup = path.with_name("config.vdf.oneclick.bak")
    if not backup.exists():
        shutil.copy2(path, backup)
    temp = path.with_suffix(".vdf.tmp")
    temp.write_text(text, encoding="utf-8")
    temp.replace(path)
    return True



def _steam_library_roots():
    root = steam_root_path()
    roots = []
    if root:
        roots.append(root)
        lf = root / "steamapps/libraryfolders.vdf"
        if lf.is_file():
            try:
                text = lf.read_text(encoding="utf-8", errors="replace")
                for raw in re.findall(r'"path"\s*"([^"]+)"', text, re.IGNORECASE):
                    path = Path(raw.replace("\\\\", "\\")).expanduser()
                    if path.exists() and path not in roots:
                        roots.append(path)
            except Exception:
                pass
    return roots


def _find_proton_experimental():
    for library in _steam_library_roots():
        candidate = library / "steamapps/common/Proton - Experimental/proton"
        if candidate.is_file():
            return candidate
    for candidate in (
        Path.home() / ".local/share/Steam/steamapps/common/Proton - Experimental/proton",
        Path.home() / ".steam/root/steamapps/common/Proton - Experimental/proton",
    ):
        if candidate.is_file():
            return candidate.resolve()
    return None


def _current_steam_compat_tool(appid):
    """Read the compatibility tool Steam currently assigned to this shortcut."""
    root = steam_root_path()
    if not root:
        return ""
    path = root / "config/config.vdf"
    if not path.is_file():
        return ""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        outer = _find_named_vdf_block_host(text, "CompatToolMapping")
        if not outer:
            return ""
        _, outer_open, outer_close = outer
        entry = _find_named_vdf_block_host(text, str(int(appid)), outer_open + 1, outer_close)
        if not entry:
            return ""
        _, entry_open, entry_close = entry
        body = text[entry_open + 1:entry_close]
        match = re.search(r'"name"\s*"([^"]*)"', body, re.IGNORECASE)
        return match.group(1).strip() if match else ""
    except Exception:
        return ""


def _find_proton_for_tool(tool_name):
    """Best-effort resolver for Steam's selected official/custom Proton tool."""
    tool = str(tool_name or "").strip()
    if not tool or tool == "proton_experimental":
        return _find_proton_experimental(), "Proton Experimental"

    # Custom compatibility tools (GE-Proton etc.) advertise the exact tool
    # name in compatibilitytool.vdf. Check the normal SteamOS locations.
    roots = []
    steam_root = steam_root_path()
    if steam_root:
        roots.append(steam_root / "compatibilitytools.d")
    roots.extend([
        Path.home() / ".local/share/Steam/compatibilitytools.d",
        Path.home() / ".steam/root/compatibilitytools.d",
    ])
    seen = set()
    for root in roots:
        try:
            root = root.resolve()
        except Exception:
            pass
        if str(root) in seen or not root.is_dir():
            continue
        seen.add(str(root))
        direct = root / tool / "proton"
        if direct.is_file():
            return direct, tool
        try:
            for manifest in root.glob("*/compatibilitytool.vdf"):
                try:
                    data = manifest.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    continue
                if re.search(r'"' + re.escape(tool) + r'"\s*\{', data, re.IGNORECASE):
                    candidate = manifest.parent / "proton"
                    if candidate.is_file():
                        return candidate, tool
        except Exception:
            pass

    # For official non-Experimental tools the internal config name and folder
    # name are not always identical. Prefer safety over guessing: use current
    # Experimental in the *same prefix* if we cannot resolve the selected tool.
    return _find_proton_experimental(), "Proton Experimental (fallback)"


def _finalize_steam_shortcut_now(appid, game_name, final_exe, icon_path=""):
    """Write a completed shortcut only while Steam is not running."""
    if steam_is_running():
        return False
    final_exe = Path(final_exe)
    if not final_exe.is_file():
        return False
    entry = load_steam_registry().get(str(int(appid))) or {}
    tool = _current_steam_compat_tool(appid) or str(entry.get("compat_tool") or DEFAULT_STEAM_COMPAT_TOOL)
    _steam_native_upsert_shortcut(appid, game_name, final_exe, final_exe.parent, icon_path or entry.get("icon", ""))
    _set_steam_compat_mapping(appid, tool or DEFAULT_STEAM_COMPAT_TOOL, only_if_missing=True)
    update_steam_registry_entry(
        appid,
        name=game_name,
        final_exe=str(final_exe),
        start_dir=str(final_exe.parent),
        status="installed",
        backend="steam",
        compat_tool=tool or DEFAULT_STEAM_COMPAT_TOOL,
        updated_at=int(time.time()),
    )
    return True


def _deferred_steam_finalize(appid, max_wait=7 * 24 * 60 * 60):
    """Wait for the user to close Steam naturally, then finalize once.

    One-Click never shuts down or reopens Steam here. This avoids KDE's
    Steam/Wayland screen-cast portal popup. The worker is intentionally tiny
    and can sit idle until the next manual Steam restart or Return to Gaming
    Mode transition.
    """
    appid = int(appid)
    deadline = time.time() + max_wait
    while time.time() < deadline:
        entry = load_steam_registry().get(str(appid)) or {}
        if entry.get("status") != "pending_steam":
            return
        final_text = str(entry.get("final_exe") or "")
        if not final_text:
            return
        if not steam_is_running():
            # Give the parallel artwork worker a chance to persist the custom
            # icon path before shortcuts.vdf is finalized. The worker clears
            # artwork_pending even when artwork fails, so this cannot block
            # forever.
            if entry.get("artwork_pending"):
                time.sleep(0.25)
                continue
            try:
                if _finalize_steam_shortcut_now(appid, entry.get("name") or str(appid), Path(final_text), entry.get("icon", "")):
                    return
            except Exception as exc:
                with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as log:
                    log.write(f"{time.ctime()}: deferred finalize AppID {appid} failed: {exc}\n")
        time.sleep(0.25)


def launch_deferred_steam_finalizer(appid):
    helper = str(Path(__file__).resolve())
    args = [sys.executable, helper, "finalize-pending-steam", str(int(appid))]
    # A transient user service survives closing One-Click/Dolphin and normally
    # survives the Desktop -> Gaming Mode transition. Fall back to a detached
    # process when systemd-run is unavailable.
    systemd_run = shutil.which("systemd-run")
    if systemd_run:
        unit = f"oneclick-steam-finalize-{int(appid)}-{int(time.time())}"
        result = subprocess.run(
            [systemd_run, "--user", "--quiet", "--collect", f"--unit={unit}", *args],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return True
    log = open(STEAM_NATIVE_LOG, "a", encoding="utf-8")
    subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    log.close()
    return True


def _direct_update_watch(appid, game_name, proton_pid, proton_path, log_dir, update_exe="", retry_count=0):
    entry = load_steam_registry().get(str(int(appid))) or {}
    compat_text = str(entry.get("compatdata") or "")
    compatdata = Path(compat_text) if compat_text else (steam_root_path() / "steamapps/compatdata" / str(int(appid)))
    _wait_pid(int(proton_pid))
    _wait_wineserver_for_prefix(proton_path, compatdata)

    # Retry an updater only when its Proton log contains a clear crash marker.
    # We intentionally do not retry a normal/clean exit because many patchers
    # are not idempotent and running a successful patch twice would be unsafe.
    update_path = Path(update_exe) if update_exe else None
    if int(retry_count) < 1 and update_path and update_path.is_file() and _retryable_proton_failure(log_dir):
        try:
            retry_started = int(time.time())
            retry_log_dir = _new_proton_log_dir(f"{game_name}-update-retry", appid, retry_started)
            env, _ = _direct_proton_env(appid, retry_log_dir)
            launcher_log = open(retry_log_dir / "launcher.log", "a", encoding="utf-8")
            try:
                proc = subprocess.Popen(
                    [str(proton_path), "run", str(update_path)], cwd=str(update_path.parent), env=env,
                    stdout=launcher_log, stderr=launcher_log, start_new_session=True, close_fds=True,
                )
            finally:
                launcher_log.close()
            subprocess.run(
                ["kdialog", "--passivepopup", f"{game_name} update exited unexpectedly. Retrying once automatically…", "5"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            launch_direct_update_watcher(appid, game_name, proc.pid, proton_path, retry_log_dir, update_path, 1)
            return
        except Exception as exc:
            with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as log:
                log.write(f"{time.ctime()}: update auto-retry AppID {appid} failed to launch: {exc}\n")

    subprocess.run(
        ["kdialog", "--passivepopup", f"{game_name} update/patch finished. Steam was not restarted.", "5"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def launch_direct_update_watcher(appid, game_name, proton_pid, proton_path, log_dir, update_exe="", retry_count=0):
    log = open(STEAM_NATIVE_LOG, "a", encoding="utf-8")
    args = [sys.executable, str(Path(__file__).resolve()), "protonwatch-update",
            str(int(appid)), str(game_name), str(int(proton_pid)), str(proton_path), str(log_dir),
            str(update_exe or ""), str(int(retry_count))]
    subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    log.close()


def _direct_proton_env(appid, proton_log_dir=None):
    root = steam_root_path()
    if not root:
        raise RuntimeError("Steam installation folder could not be found")
    compatdata = root / "steamapps/compatdata" / str(int(appid))
    compatdata.mkdir(parents=True, exist_ok=True)
    _write_oneclick_prefix_marker(compatdata, appid)
    env = os.environ.copy()
    env["STEAM_COMPAT_DATA_PATH"] = str(compatdata)
    env["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = str(root)
    # Keep installer launches neutral, like the known-good V6.7.5 path.
    # Do NOT make the installer impersonate the final Steam shortcut: some
    # installers behave differently when SteamAppId/STEAM_COMPAT_APP_ID are
    # populated. Proton only needs SteamGameId for the PROTON_LOG filename,
    # so give logging its own harmless identity while keeping SteamAppId 0.
    env["STEAM_COMPAT_APP_ID"] = "0"
    env["SteamAppId"] = "0"
    env["SteamGameId"] = f"oneclick-{int(appid)}"
    # Installers and patchers do not need Proton's controller-friendly Xalia
    # helper. On SteamOS it can intermittently attach before an installer
    # window is ready and abort the setup with invalid-window-handle errors.
    # This environment is used only for One-Click's direct installer/update
    # runs; the installed game later uses Steam's normal Proton defaults.
    env["PROTON_USE_XALIA"] = "0"
    # Some heavily-compressed 32-bit installers (ISDone/unarc/cls-lolz style)
    # can exhaust or fragment their Win32 virtual address space when Proton's
    # Large Address Aware forcing is enabled. This is an installer-only
    # compatibility setting; the installed game later launches through Steam
    # with its normal Proton defaults.
    env["PROTON_FORCE_LARGE_ADDRESS_AWARE"] = "0"
    env["WINE_LARGE_ADDRESS_AWARE"] = "0"
    # PROTON_LOG=1 enables a very broad Wine trace and can generate hundreds
    # of MB during decompression, materially slowing a setup that is already
    # struggling. Keep normal installs lightweight and capture only Wine error
    # lines in launcher.log. Detailed Proton logging can be re-enabled later
    # for a specific diagnostic build if needed.
    env.pop("PROTON_LOG", None)
    env.pop("PROTON_LOG_DIR", None)
    if proton_log_dir:
        log_path = str(Path(proton_log_dir))
        env["PROTON_CRASH_REPORT_DIR"] = log_path
    env["WINEDEBUG"] = "err+all"
    return env, compatdata


def _wait_pid(pid, timeout=12 * 60 * 60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass
        time.sleep(1.0)
    return False


def _wait_wineserver_for_prefix(proton_path, compatdata, timeout=12 * 60 * 60):
    wineserver = Path(proton_path).parent / "files/bin/wineserver"
    if not wineserver.is_file():
        deadline = time.time() + timeout
        quiet_since = None
        pfx = str((Path(compatdata) / "pfx").resolve())
        compat_real = str(Path(compatdata).resolve())
        while time.time() < deadline:
            active = False
            try:
                for item in Path("/proc").iterdir():
                    if not item.name.isdigit():
                        continue
                    try:
                        data = (item / "environ").read_bytes()
                        if (f"WINEPREFIX={pfx}".encode() in data or
                                f"STEAM_COMPAT_DATA_PATH={compat_real}".encode() in data):
                            active = True
                            break
                    except Exception:
                        continue
            except Exception:
                pass
            if active:
                quiet_since = None
            elif quiet_since is None:
                quiet_since = time.time()
            elif time.time() - quiet_since >= 8:
                return True
            time.sleep(1.0)
        return False

    env = os.environ.copy()
    env["WINEPREFIX"] = str((Path(compatdata) / "pfx").resolve())
    try:
        subprocess.run([str(wineserver), "-w"], env=env, timeout=timeout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def _retryable_proton_failure(log_dir):
    """Return True for transient Proton/installer failures worth one retry.

    Keep this conservative: the main known case is Xalia/window bootstrap
    failure. We also allow a very short failed first launch, which commonly
    indicates a bootstrap race rather than a completed/cancelled install.
    """
    markers = (
        "xalia.exe",
        "invalid window handle",
        "invalidcastexception",
        "exception handling",
        "unhandled exception",
        "segmentation fault",
    )
    try:
        root = Path(log_dir)
        for path in root.glob("*.log"):
            try:
                text = path.read_text(encoding="utf-8", errors="ignore").casefold()
            except Exception:
                continue
            if any(item in text for item in markers):
                return True
    except Exception:
        pass
    return False


def _launch_direct_proton_retry(appid, game_name, installer, proton_path, original_started_at):
    retry_started = int(time.time())
    retry_log_dir = _new_proton_log_dir(f"{game_name}-retry", appid, retry_started)
    env, _compatdata = _direct_proton_env(appid, retry_log_dir)
    launcher_log = open(retry_log_dir / "launcher.log", "a", encoding="utf-8")
    try:
        proc = subprocess.Popen(
            [str(proton_path), "run", str(installer)],
            cwd=str(Path(installer).parent), env=env, stdout=launcher_log, stderr=launcher_log,
            start_new_session=True, close_fds=True,
        )
    finally:
        launcher_log.close()
    update_steam_registry_entry(
        appid, status="installing_retry", retry_count=1,
        proton_log_dir=str(retry_log_dir), updated_at=int(time.time()),
    )
    with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as summary:
        summary.write(
            f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] AUTO-RETRY {game_name} "
            f"AppID={int(appid)} log={retry_log_dir}\n"
        )
    subprocess.run(
        ["kdialog", "--passivepopup",
         f"{game_name} installer exited unexpectedly. Retrying once automatically…", "5"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    _direct_proton_watch(int(appid), game_name, int(original_started_at), proc.pid, str(proton_path))


def _direct_proton_watch(appid, game_name, started_at, proton_pid, proton_path):
    appid = int(appid)
    entry = (load_steam_registry().get(str(appid)) or {})
    compatdata_text = entry.get("compatdata") or ""
    compatdata = Path(compatdata_text) if compatdata_text else None

    _wait_pid(int(proton_pid))
    if compatdata:
        _wait_wineserver_for_prefix(proton_path, compatdata)

    time.sleep(2.0)
    final_exe = _find_game_exe(appid, game_name, started_at)
    if not final_exe:
        entry = (load_steam_registry().get(str(appid)) or entry or {})
        log_dir = str(entry.get("proton_log_dir") or PROTON_LOG_ROOT)
        installer_text = str(entry.get("installer") or "").strip()
        retry_count = int(entry.get("retry_count") or 0)
        elapsed = max(0, int(time.time()) - int(started_at))
        # One transparent retry covers the intermittent first-launch failure
        # seen with fresh Proton prefixes. Never clean the prefix between the
        # two attempts; the second attempt deliberately reuses it.
        if (retry_count < 1 and installer_text and Path(installer_text).is_file() and
                (_retryable_proton_failure(log_dir) or elapsed <= 60)):
            try:
                _launch_direct_proton_retry(appid, game_name, Path(installer_text), proton_path, started_at)
                return
            except Exception as retry_exc:
                with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as retry_log:
                    retry_log.write(f"{time.ctime()}: automatic retry for AppID {appid} failed to launch: {retry_exc}\n")

        cleanup_size = 0
        cleanup_done = False
        try:
            cleanup_size, cleanup_done = _safe_remove_failed_compatdata(appid, entry)
        except Exception:
            cleanup_done = False
        update_steam_registry_entry(
            appid,
            status="install_failed_cleaned" if cleanup_done else "install_failed",
            compatdata="" if cleanup_done else str(entry.get("compatdata") or ""),
            updated_at=int(time.time()),
        )

        cleanup_text = (
            f"\n\nThe incomplete Steam prefix was removed ({_human_size(cleanup_size)}) so failed installs do not build up."
            if cleanup_done and cleanup_size
            else ("\n\nThe incomplete Steam prefix was removed so failed installs do not build up." if cleanup_done else "")
        )
        retry = False
        if installer_text and Path(installer_text).is_file():
            retry = subprocess.run(
                [
                    "kdialog", "--warningyesno",
                    f"{game_name} did not complete with Proton Experimental.\n\n"
                    "Steam was NOT stopped and One-Click did not terminate the installer."
                    f"{cleanup_text}\n\n"
                    f"Installer diagnostics were saved in:\n{log_dir}\n\n"
                    "Retry this installer with Lutris / Wine?\n\nOne-Click will use Lutris\' normal Wine configuration (for example your System 11.0 setting).",
                ],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode == 0
        else:
            error(
                f"{game_name} did not complete with Proton Experimental.\n\n"
                f"Installer diagnostics were saved in:\n{log_dir}{cleanup_text}"
            )
            return

        if retry:
            try:
                # Do not reuse/mix the failed Proton prefix. Lutris gets its own
                # separate Wine prefix and we explicitly request System Wine.
                install_new_lutris(Path(installer_text), game_name=game_name)
                remove_steam_registry_entry(appid)
            except Exception as exc:
                error(
                    f"Could not start the Lutris / Wine fallback for {game_name}:\n\n{exc}\n\n"
                    f"The Proton diagnostic logs are still available in:\n{log_dir}"
                )
        return

    # V6.4: never shut down or reopen Steam automatically. Final shortcut
    # integration is queued until the user naturally closes/restarts Steam or
    # switches back to Gaming Mode. Artwork can be prepared immediately.
    update_steam_registry_entry(
        appid, name=game_name, final_exe=str(final_exe), start_dir=str(final_exe.parent),
        status="pending_steam", backend="steam", compat_tool=DEFAULT_STEAM_COMPAT_TOOL,
        artwork_pending=True, updated_at=int(time.time()),
    )
    launch_background_steam_artwork(appid, game_name)
    if steam_is_running():
        launch_deferred_steam_finalizer(appid)
        subprocess.run(
            ["kdialog", "--passivepopup",
             f"{game_name} is installed. Steam can stay open. The shortcut will finalize the next time Steam closes/restarts or you return to Gaming Mode.", "8"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    else:
        try:
            _finalize_steam_shortcut_now(appid, game_name, final_exe, entry.get("icon", ""))
        except Exception as exc:
            with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as log:
                log.write(f"{time.ctime()}: immediate finalize AppID {appid} failed: {exc}\n")


def launch_direct_proton_watcher(appid, game_name, started_at, proton_pid, proton_path):
    log = open(STEAM_NATIVE_LOG, "a", encoding="utf-8")
    args = [sys.executable, str(Path(__file__).resolve()), "protonwatch-native",
            str(int(appid)), game_name, str(int(started_at)), str(int(proton_pid)), str(proton_path)]
    subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    log.close()

def _steam_reaper_running(appid):
    try:
        result = subprocess.run(
            ["pgrep", "-af", f"SteamLaunch AppId={int(appid)}"],
            text=True,
            capture_output=True,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except Exception:
        return False


def _wait_for_steam_ready(timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if steam_is_running():
            time.sleep(2.0)
            return True
        time.sleep(0.5)
    return False


def _launch_steam_shortcut(appid):
    steam = shutil.which("steam")
    if not steam:
        raise RuntimeError("Steam executable was not found")
    bpid = _big_picture_id(appid)
    subprocess.Popen(
        [steam, f"steam://rungameid/{bpid}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return bpid


def _candidate_score(path, game_name, started_at=0):
    lower = str(path).lower().replace("\\", "/")
    stem = path.stem.lower()
    tokens = [x for x in re.findall(r"[a-z0-9]+", game_name.lower()) if len(x) > 1]
    score = 0

    # Never offer executables that merely belong to the fresh Proton/Wine
    # prefix. V6.0 could show steam.exe / iexplore.exe / wordpad.exe when a
    # bootstrap installer exited early; those are not game candidates.
    blocked_parts = (
        "/windows/", "/system32/", "/syswow64/", "/winsxs/",
        "/users/steamuser/appdata/", "/programdata/",
        "/program files (x86)/steam/", "/program files/steam/",
        "/internet explorer/", "/windows nt/", "/windows media player/",
        "/common files/", "/microsoft/edge/",
    )
    if any(x in lower for x in blocked_parts):
        return -10000

    system_stems = {
        "steam", "iexplore", "wordpad", "wmplayer", "explorer", "services",
        "rundll32", "regedit", "control", "hh", "wineboot", "winedevice",
        "plugplay", "rpcss", "svchost", "start",
    }
    if stem in system_stems:
        return -10000

    bad_names = (
        "unins", "uninstall", "setup", "installer", "installshield", "vc_redist", "vcredist",
        "dxsetup", "directx", "unitycrashhandler", "crashpad", "crashreport", "reporter",
        "dotnet", "redistributable", "prereq", "supporttool", "helper", "repair"
    )
    if any(x in stem for x in bad_names):
        score -= 180
    if any(x in lower for x in ("/redist/", "/_redist/", "/redists/", "/support/", "/prereq/")):
        score -= 120

    if "/gog games/" in lower:
        score += 120
    if "/program files" in lower:
        score += 25

    norm_stem = re.sub(r"[^a-z0-9]+", "", stem)
    norm_name = re.sub(r"[^a-z0-9]+", "", game_name.lower())
    if norm_name and norm_name in norm_stem:
        score += 120
    elif norm_stem and norm_stem in norm_name and len(norm_stem) >= 5:
        score += 80
    for token in tokens:
        if token in stem:
            score += 20
        if token in path.parent.name.lower():
            score += 10

    try:
        stat = path.stat()
        size = stat.st_size
        # Prefer files touched by this installation, but don't require the
        # timestamp because some installers preserve original file mtimes.
        if started_at and stat.st_mtime >= started_at - 10:
            score += 12
    except OSError:
        size = 0

    if size >= 20 * 1024 * 1024:
        score += 30
    elif size >= 5 * 1024 * 1024:
        score += 22
    elif size >= 1 * 1024 * 1024:
        score += 10
    elif size < 100 * 1024:
        score -= 30
    if "launcher" in stem:
        score += 3
    return score


def _prefix_runtime_processes(appid):
    """Return PIDs still running inside this Steam Proton prefix.

    GOG/InstallShield/Inno installers often launch a child process and let the
    original bootstrap EXE exit. Steam's reaper can therefore disappear while
    the real installer is still open. V6.0 treated that as completion and then
    shut Steam down, which killed the installer. Checking /proc environments
    keeps the watcher attached to the actual Proton prefix instead.
    """
    root = steam_root_path()
    if not root:
        return []
    compat = str((root / "steamapps" / "compatdata" / str(int(appid))).resolve())
    pfx = str((Path(compat) / "pfx").resolve())
    needles = (
        f"STEAM_COMPAT_DATA_PATH={compat}".encode(),
        f"WINEPREFIX={pfx}".encode(),
        f"STEAM_COMPAT_APP_ID={int(appid)}".encode(),
    )
    found = []
    proc = Path("/proc")
    try:
        entries = list(proc.iterdir())
    except Exception:
        return found
    own = os.getpid()
    for item in entries:
        if not item.name.isdigit():
            continue
        pid = int(item.name)
        if pid == own:
            continue
        try:
            data = (item / "environ").read_bytes()
            if any(n in data for n in needles):
                cmd = (item / "cmdline").read_bytes().replace(b"\\0", b" ").decode("utf-8", "ignore")
                found.append((pid, cmd))
        except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
            continue
    return found


def _wait_for_steam_native_session(appid, initial_timeout=180, quiet_seconds=8, max_runtime=12 * 60 * 60):
    """Wait until the Steam/Proton installer is *actually* finished."""
    first_deadline = time.time() + initial_timeout
    seen = False
    while time.time() < first_deadline:
        if _steam_reaper_running(appid) or _prefix_runtime_processes(appid):
            seen = True
            break
        time.sleep(0.5)
    if not seen:
        return False

    deadline = time.time() + max_runtime
    quiet_since = None
    while time.time() < deadline:
        active = _steam_reaper_running(appid) or bool(_prefix_runtime_processes(appid))
        if active:
            quiet_since = None
        else:
            if quiet_since is None:
                quiet_since = time.time()
            elif time.time() - quiet_since >= quiet_seconds:
                return True
        time.sleep(1.0)
    return False


def _find_game_exe(appid, game_name, started_at=0):
    root = steam_root_path()
    if not root:
        return None
    drive_c = root / "steamapps" / "compatdata" / str(int(appid)) / "pfx" / "drive_c"
    if not drive_c.is_dir():
        return None
    candidates = []
    try:
        for path in drive_c.rglob("*.exe"):
            if path.is_file():
                score = _candidate_score(path, game_name, started_at)
                if score > -500:
                    candidates.append((score, path))
    except Exception:
        pass
    candidates.sort(key=lambda x: (-x[0], len(str(x[1]))))
    if not candidates:
        return None

    best_score, best = candidates[0]
    second_score = candidates[1][0] if len(candidates) > 1 else -9999
    if best_score >= 70 and best_score - second_score >= 10:
        return best

    # Don't show a chooser full of Proton's stock Windows programs. If nothing
    # looks remotely like the requested game, report a clean detection failure.
    plausible = [(score, path) for score, path in candidates if score >= 18]
    if not plausible:
        return None

    args = ["--menu", f"Choose the main game EXE for {game_name}:"]
    for _score, path in plausible[:12]:
        try:
            rel = path.relative_to(drive_c)
        except Exception:
            rel = path
        args.extend([str(path), str(rel)])
    choice = dialog(args)
    return Path(choice) if choice else None

def launch_background_steam_artwork(appid, game_name):
    if not TOOLS_GUI_PATH.is_file():
        return False
    try:
        log = open(BACKGROUND_ARTWORK_LOG, "a", encoding="utf-8")
        subprocess.Popen(
            ["flatpak", "run", "--command=python3", APP_ID, str(TOOLS_GUI_PATH),
             "--background-steam-artwork", str(int(appid)), str(game_name or "")],
            stdout=log, stderr=log, start_new_session=True, close_fds=True,
        )
        log.close()
        return True
    except Exception:
        return False


def _steam_native_watch(appid, game_name, started_at, restore_exe=""):
    appid = int(appid)
    if not _wait_for_steam_native_session(appid):
        with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as log:
            log.write(f"{time.ctime()}: AppID {appid} did not reach a clean finished state\n")
        return

    entry = (load_steam_registry().get(str(appid)) or {})
    if restore_exe:
        final_exe = Path(restore_exe)
    else:
        final_exe = _find_game_exe(appid, game_name, started_at)
        if not final_exe:
            error(
                f"{game_name} finished, but One-Click could not find a newly installed main game EXE.\n\n"
                "The installer may have been cancelled, installed outside the Steam Proton C: drive, "
                "or used an unusual launcher. No system/Proton EXE was selected."
            )
            return

    update_steam_registry_entry(
        appid, name=game_name, final_exe=str(final_exe), start_dir=str(final_exe.parent),
        status="pending_steam", backend="steam", updated_at=int(time.time()),
    )
    if not restore_exe:
        launch_background_steam_artwork(appid, game_name)
    if steam_is_running():
        launch_deferred_steam_finalizer(appid)
    else:
        _finalize_steam_shortcut_now(appid, game_name, final_exe, entry.get("icon", ""))

def launch_steam_native_watcher(appid, game_name, started_at, restore_exe=""):
    log = open(STEAM_NATIVE_LOG, "a", encoding="utf-8")
    args = [sys.executable, str(Path(__file__).resolve()), "steamwatch-native", str(int(appid)), game_name, str(int(started_at))]
    if restore_exe:
        args.append(str(restore_exe))
    subprocess.Popen(args, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    log.close()



def _looks_like_update_exe(exe: Path):
    """Conservative filename-only update/patch detection.

    We intentionally preselect Update rather than silently routing it. The user
    can still choose Install as new game when a title genuinely contains one of
    these words.
    """
    text = exe.stem.casefold().replace("_", " ").replace("-", " ")
    return bool(re.search(r"\b(update|patch|hotfix|upgrade|fixpack|title update)\b", text))


def _derive_update_game_name(exe: Path):
    raw = exe.stem.strip()
    # Remove common update marker + optional version/build suffix, in either
    # "Game Update 1.42" or "Game 1.42 Update" style.
    raw = re.sub(
        r"(?ix)[\s_.-]+(?:update|patch|hotfix|upgrade|fixpack|title[\s_.-]*update)"
        r"(?:[\s_.-]+(?:v(?:er(?:sion)?)?[\s_.-]*)?\d+(?:\.\d+)+(?:[a-z0-9.-]*)?)?$",
        "",
        raw,
    )
    raw = re.sub(
        r"(?ix)[\s_.-]+(?:v(?:er(?:sion)?)?[\s_.-]*)?\d+(?:\.\d+)+(?:[a-z0-9.-]*)?"
        r"[\s_.-]+(?:update|patch|hotfix|upgrade)$",
        "",
        raw,
    )
    cleaned = _clean_installer_name(raw)
    if not cleaned:
        cleaned = _clean_installer_name(exe.parent.name)
    return _smart_title_case(cleaned) if cleaned else derive_default_name(exe)


def _read_action_gui_result(result):
    if result.returncode != 0:
        return None
    for line in reversed((result.stdout or "").splitlines()):
        if line.startswith("ONECLICK_RESULT="):
            try:
                value = json.loads(line.split("=", 1)[1])
                return value if isinstance(value, dict) else None
            except Exception:
                return None
    return None


def choose_new_exe_action(exe: Path):
    likely_update = _looks_like_update_exe(exe)
    suggested = _derive_update_game_name(exe) if likely_update else derive_default_name(exe)
    if not ACTION_GUI_PATH.is_file():
        error(
            "The One-Click installer dialog is missing.\n\n"
            "Please reinstall One-Click V6.7.17."
        )
        return None
    try:
        # A previous Tools launch may have intentionally closed an old action
        # dialog. Never let that marker suppress a real future dialog error.
        try:
            ACTION_DIALOG_INTENTIONAL_CLOSE.unlink(missing_ok=True)
        except Exception:
            pass

        result = subprocess.run(
            [
                "flatpak", "run", "--command=python3", APP_ID,
                str(ACTION_GUI_PATH), "new-exe", str(exe), suggested,
                "1" if likely_update else "0", installer_backend(),
            ],
            text=True, capture_output=True, timeout=60 * 60,
        )
    except Exception as exc:
        try:
            ACTION_DIALOG_LOG.write_text(
                f"Failed to launch One-Click installer dialog: {exc}\n", encoding="utf-8"
            )
        except Exception:
            pass
        error(
            "One-Click could not open its installer dialog.\n\n"
            f"Details were saved to:\n{ACTION_DIALOG_LOG}"
        )
        return None

    parsed = _read_action_gui_result(result)
    if parsed:
        return parsed
    if result.returncode == 0:
        return None  # user cancelled/closed it

    # Opening One-Click Tools intentionally stops the Lutris Flatpak so its
    # database/config cannot be stale. The rich installer dialog lives inside
    # that same Flatpak, so it is terminated too. Treat that specific case as
    # a normal cancel/hand-off, not a crash.
    try:
        if ACTION_DIALOG_INTENTIONAL_CLOSE.is_file():
            age = time.time() - ACTION_DIALOG_INTENTIONAL_CLOSE.stat().st_mtime
            ACTION_DIALOG_INTENTIONAL_CLOSE.unlink(missing_ok=True)
            if 0 <= age <= 20:
                return None
    except Exception:
        pass

    try:
        ACTION_DIALOG_LOG.write_text(
            "One-Click installer dialog failed.\n\n"
            f"Exit code: {result.returncode}\n\n"
            f"STDOUT:\n{result.stdout or ''}\n\n"
            f"STDERR:\n{result.stderr or ''}\n",
            encoding="utf-8",
        )
    except Exception:
        pass
    error(
        "One-Click's installer dialog failed to start.\n\n"
        f"Please send this log if it happens again:\n{ACTION_DIALOG_LOG}"
    )
    return None

def _folder_norm_name(text: str) -> str:
    text = str(text or "").casefold().replace("&", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def _clean_folder_game_name(raw_name: str) -> str:
    """Turn release/package folder names into a plausible human game title.

    Folder scans often start one or more levels above the actual installer and
    those outer folders may contain release-group tags, platform markers or
    mangled archive names.  We prefer the cleanest human-looking component of
    the chosen EXE's path instead of blindly using the folder the user clicked.
    """
    text = str(raw_name or "").strip()
    if not text:
        return ""

    # Drop common bracketed packaging metadata first.
    text = re.sub(
        r"(?ix)\s*[\[(](?:pc|windows|win64|win32|x64|x86|portable|repack|gog|multi\d*|"
        r"elamigos|fitgirl|dodi|codex|plaza|tenoke|rune|flt|skidrow|empress)[\]) ]*\s*$",
        "",
        text,
    )
    # Drop common trailing release/package tags.  This is deliberately only a
    # suffix cleanup so legitimate words in the middle of a title are kept.
    text = re.sub(
        r"(?ix)(?:[\s._-]+(?:elamigos|fitgirl|dodi|repack|portable|gog|codex|plaza|"
        r"tenoke|rune|flt|skidrow|empress|multi\d*|pcv?\d*|win(?:32|64)?|x(?:86|64)))+$",
        "",
        text,
    ).strip(" -_.")

    text = _clean_installer_name(text)
    return _smart_title_case(text) if text else ""


def _folder_name_quality(name: str) -> int:
    """Score whether a path component looks like a real human game title."""
    clean = str(name or "").strip()
    if not clean:
        return -10000
    norm = _folder_norm_name(clean)
    if not norm:
        return -10000
    if norm in {
        "bin", "binaries", "game", "games", "setup", "installer", "install",
        "redist", "support", "data", "files", "program files", "program files x86",
    }:
        return -1000

    words = clean.split()
    letters = sum(ch.isalpha() for ch in clean)
    digits = sum(ch.isdigit() for ch in clean)
    score = 0
    score += min(len(words), 8) * 12
    if len(words) >= 2:
        score += 28
    if any(ch in clean for ch in ("'", ":", "-")):
        score += 8
    if 4 <= letters <= 80:
        score += 20
    if digits:
        ratio = digits / max(1, letters + digits)
        score -= int(ratio * 120)
    # Archive/release folder names are often one long token with digits woven
    # through otherwise recognizable words. Prefer a clean nested folder.
    if len(words) == 1 and len(clean) > 18:
        score -= 35
    if len(re.findall(r"(?i)[a-z]\d|\d[a-z]", clean)) >= 3:
        score -= 80
    return score


def _suggest_game_name_for_candidate(folder: Path, exe_path: Path, fallback: str = "") -> str:
    """Derive a display name from the most human-looking path component."""
    folder = folder.resolve()
    exe_path = exe_path.resolve()
    raw_candidates = []

    # A non-generic EXE filename can itself be the best clue for portable games.
    stem = exe_path.stem.strip()
    if stem.casefold() not in {
        "setup", "setup64", "setup_x64", "setup-x64", "install", "installer",
        "launcher", "start", "game", "update", "patch",
    }:
        raw_candidates.append(stem)

    current = exe_path.parent
    for _ in range(12):
        raw_candidates.append(current.name)
        if current == folder or current.parent == current:
            break
        try:
            current.relative_to(folder)
        except Exception:
            break
        current = current.parent
    raw_candidates.append(folder.name)
    if fallback:
        raw_candidates.append(fallback)

    best_name = ""
    best_score = -10000
    seen = set()
    for raw in raw_candidates:
        clean = _clean_folder_game_name(raw)
        norm = _folder_norm_name(clean)
        if not clean or not norm or norm in seen:
            continue
        seen.add(norm)
        score = _folder_name_quality(clean)
        if score > best_score:
            best_name, best_score = clean, score
    return best_name or (_smart_title_case(_clean_installer_name(fallback)) if fallback else "New Game")


def _scan_game_folder_exes(folder: Path, game_name: str, limit=18, purpose="existing"):
    purpose = "install" if str(purpose).strip().lower() == "install" else "existing"
    folder = folder.resolve()
    candidates = []
    skip_dirs = {
        "$recycle.bin", "system volume information", "__pycache__", ".git",
        "redist", "redists", "_redist", "__redist", "redistributables",
        "directx", "vcredist", "dotnet", "support", "supportfiles",
        "installer", "installers", "prereq", "prereqs", "prerequisites",
    }
    norm_game = re.sub(r"[^a-z0-9]+", "", game_name.casefold())
    root_depth = len(folder.parts)
    seen = 0

    try:
        walker = os.walk(folder)
        for root_text, dirs, files in walker:
            root = Path(root_text)
            depth = len(root.parts) - root_depth
            if depth > 10:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d.casefold() not in skip_dirs]
            for filename in files:
                if not filename.casefold().endswith(".exe"):
                    continue
                seen += 1
                if seen > 12000:
                    break
                path = root / filename
                score = _candidate_score(path, game_name, 0)
                low = path.stem.casefold()
                rel_text = str(path.relative_to(folder)).casefold().replace("\\", "/")

                norm_stem = re.sub(r"[^a-z0-9]+", "", low)
                if norm_game and (norm_game in norm_stem or norm_stem in norm_game) and len(norm_stem) >= 4:
                    score += 90
                if path.parent == folder:
                    score += 25

                if purpose == "install":
                    # Folder -> Find EXE + Install is intentionally looking for
                    # setup/installer/update executables.  Do NOT use the
                    # existing-game penalties here; those caused setup.exe to
                    # be discovered and then thrown away in V6.7.11.
                    if low in {"setup", "install", "installer"}:
                        score += 260
                    elif low.startswith(("setup", "install")):
                        score += 220
                    if any(x in low for x in ("update", "patch", "hotfix", "upgrade")):
                        score += 120
                    if any(x in low for x in ("unins", "uninstall", "crash", "report", "redist", "dxsetup")):
                        score -= 180
                    # Installer packages commonly keep setup.exe one or two
                    # levels below the folder the user right-clicked.
                    score += max(0, 28 - (depth * 4))
                else:
                    # Existing/portable game mode: strongly avoid setup/update
                    # utilities and prefer the actual gameplay executable.
                    if any(x in low for x in ("update", "patch", "hotfix", "unins", "uninstall", "setup", "installer", "crash", "report", "redist", "dxsetup")):
                        score -= 180
                    if any(x in rel_text for x in ("/redist/", "/_redist/", "/support/", "/installer/")):
                        score -= 120
                candidates.append((score, path))
            if seen > 12000:
                break
    except Exception:
        pass

    candidates.sort(key=lambda item: (-item[0], len(str(item[1]))))
    # Install mode is deliberately permissive because installer packages can
    # use generic names such as setup.exe. Existing-game mode stays stricter.
    threshold = -170 if purpose == "install" else -50
    useful = [(score, path) for score, path in candidates if score > threshold]
    return useful[: int(limit)]


def choose_game_exe_from_folder(folder: Path, suggested_name=None, purpose="existing"):
    purpose = "install" if str(purpose).strip().lower() == "install" else "existing"
    folder = folder.resolve()
    rough_name = suggested_name or _smart_title_case(_clean_installer_name(folder.name) or folder.name)
    candidates = _scan_game_folder_exes(folder, rough_name, purpose=purpose)
    if not candidates:
        wanted = "Windows installer/update EXE" if purpose == "install" else "Windows game EXE"
        error(
            f"One-Click could not find any plausible {wanted} in this folder.\n\n"
            f"Folder:\n{folder}"
        )
        return None

    # The folder the user right-clicked may be a mangled release/archive name.
    # Use the best-ranked EXE path to infer a cleaner title, then re-rank once
    # using that title so the EXE ranking and display name reinforce each other.
    game_name = _suggest_game_name_for_candidate(folder, candidates[0][1], rough_name)
    if _folder_norm_name(game_name) != _folder_norm_name(rough_name):
        reranked = _scan_game_folder_exes(folder, game_name, purpose=purpose)
        if reranked:
            candidates = reranked

    payload = []
    for score, path in candidates:
        try:
            rel = str(path.relative_to(folder))
        except Exception:
            rel = str(path)
        try:
            size = path.stat().st_size
        except OSError:
            size = 0
        payload.append({
            "path": str(path),
            "label": rel,
            "score": int(score),
            "size": int(size),
            "suggested_name": _suggest_game_name_for_candidate(folder, path, game_name),
        })

    if not ACTION_GUI_PATH.is_file():
        error(
            "The One-Click existing-game dialog is missing.\n\n"
            "Please reinstall One-Click V6.7.17."
        )
        return None
    try:
        result = subprocess.run(
            [
                "flatpak", "run", "--command=python3", APP_ID,
                str(ACTION_GUI_PATH), "folder-install" if purpose == "install" else "folder", str(folder), game_name,
                json.dumps(payload, separators=(",", ":")),
            ],
            text=True, capture_output=True, timeout=60 * 60,
        )
        parsed = _read_action_gui_result(result)
        if parsed and parsed.get("exe"):
            return parsed
        if result.returncode == 0:
            return None
        ACTION_DIALOG_LOG.write_text(
            "One-Click existing-game dialog failed.\n\n"
            f"Exit code: {result.returncode}\n\n"
            f"STDOUT:\n{result.stdout or ''}\n\n"
            f"STDERR:\n{result.stderr or ''}\n",
            encoding="utf-8",
        )
        error(
            "One-Click's existing-game dialog failed to start.\n\n"
            f"Please send this log if it happens again:\n{ACTION_DIALOG_LOG}"
        )
        return None
    except Exception as exc:
        try:
            ACTION_DIALOG_LOG.write_text(
                f"Failed to launch existing-game dialog: {exc}\n", encoding="utf-8"
            )
        except Exception:
            pass
        error(
            "One-Click could not open its existing-game dialog.\n\n"
            f"Details were saved to:\n{ACTION_DIALOG_LOG}"
        )
        return None
def add_existing_steam_exe(exe: Path, game_name: str):
    """Register an already-complete Windows game without running an installer."""
    exe = exe.expanduser().resolve()
    if not exe.is_file():
        error(f"Game EXE was not found:\n\n{exe}")
        return
    game_name = str(game_name or "").strip() or _smart_title_case(_clean_installer_name(exe.parent.name) or exe.stem)
    appid = _steam_native_appid(game_name)
    existing = load_steam_registry().get(str(appid)) or {}
    if existing.get("status") in {"installed", "pending_steam", "detached"} and existing.get("final_exe"):
        old = str(existing.get("final_exe") or "")
        if old != str(exe):
            if subprocess.run(
                ["kdialog", "--warningyesno",
                 f"{game_name} is already managed by One-Click.\n\n"
                 f"Current EXE:\n{old}\n\nReplace it with:\n{exe}?"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode != 0:
                return

    update_steam_registry_entry(
        appid,
        name=game_name,
        installer="",
        final_exe=str(exe),
        start_dir=str(exe.parent),
        status="pending_steam",
        backend="steam",
        compat_tool=str(existing.get("compat_tool") or DEFAULT_STEAM_COMPAT_TOOL),
        artwork_pending=True,
        created_at=int(existing.get("created_at") or time.time()),
        updated_at=int(time.time()),
    )
    launch_background_steam_artwork(appid, game_name)
    if steam_is_running():
        launch_deferred_steam_finalizer(appid)
        subprocess.run(
            ["kdialog", "--passivepopup",
             f"{game_name} is ready. The Steam shortcut will appear/finalize the next time Steam closes or you return to Gaming Mode.", "7"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    else:
        # Artwork may still be running; finalizing without an icon is harmless
        # because the artwork worker can queue the PNG icon path afterwards.
        _finalize_steam_shortcut_now(appid, game_name, exe, existing.get("icon", ""))


def add_existing_from_folder(folder: Path):
    folder = folder.expanduser().resolve()
    if not folder.is_dir():
        error(f"Folder was not found:\n\n{folder}")
        return
    picked = choose_game_exe_from_folder(folder)
    if not picked:
        return
    add_existing_steam_exe(Path(picked["exe"]), picked.get("name") or folder.name)


def find_exe_and_open_installer(folder: Path):
    """Scan a folder for likely EXEs, then hand the chosen EXE to the normal double-click workflow."""
    folder = folder.expanduser().resolve()
    if not folder.is_dir():
        error(f"Folder was not found:\n\n{folder}")
        return
    picked = choose_game_exe_from_folder(folder, purpose="install")
    if not picked:
        return
    exe = Path(str(picked.get("exe") or "")).expanduser().resolve()
    if not exe.is_file():
        error(f"Selected EXE was not found:\n\n{exe}")
        return
    # Reuse the exact same Install / Update / Add Existing dialog and logic as
    # a normal double-click. The folder scanner merely saves the user from
    # browsing through a large directory tree manually.
    handle_new_exe(exe)


def handle_new_exe(exe: Path):
    choice = choose_new_exe_action(exe)
    if not choice:
        return
    action = str(choice.get("action") or "").strip().lower()
    game_name = str(choice.get("name") or "").strip() or derive_default_name(exe)
    backend_override = str(choice.get("backend") or "").strip().lower()
    if backend_override not in {"steam", "lutris"}:
        backend_override = installer_backend()

    if action == "update":
        # Use the existing game's already-configured prefix. This is the same
        # path as the right-click "Run as game update / patch" action.
        return run_existing(exe)
    if action == "existing":
        # If the clicked EXE itself looks like an installer/update, scan its
        # enclosing folder instead of accidentally making setup.exe the game.
        low = exe.stem.casefold()
        if _looks_like_update_exe(exe) or re.search(r"\b(setup|install|installer|unins|uninstall)\b", low):
            picked = choose_game_exe_from_folder(exe.parent, game_name)
            if not picked:
                return
            return add_existing_steam_exe(Path(picked["exe"]), picked.get("name") or game_name)
        return add_existing_steam_exe(exe, game_name)
    if action == "install":
        return install_new(exe, game_name=game_name, backend_override=backend_override)


def install_new_steam(exe: Path, game_name=None):
    if not game_name:
        game_name = dialog(["--inputbox", "Detected game name (edit if needed):", derive_default_name(exe)])
    if not game_name:
        return
    appid = _steam_native_appid(game_name)
    existing = load_steam_registry().get(str(appid))
    if existing and existing.get("status") == "installed":
        if subprocess.run(["kdialog", "--warningyesno",
                           f"{game_name} is already managed by the Steam backend.\n\nRe-run its installer anyway?"]).returncode != 0:
            return

    root = steam_root_path()
    proton = _find_proton_experimental()
    if not root:
        error("Steam installation folder could not be found.")
        return
    if not proton:
        error(
            "Proton Experimental is not installed.\n\n"
            "Install Proton Experimental from Steam first, then try the installer again."
        )
        return

    started_at = int(time.time())
    cleanup_on_failure = not bool(existing and existing.get("status") == "installed" and existing.get("final_exe"))
    proton_log_dir = _new_proton_log_dir(game_name, appid, started_at)
    try:
        env, compatdata = _direct_proton_env(appid, proton_log_dir)
        update_steam_registry_entry(
            appid, name=game_name, installer=str(exe), final_exe="", start_dir=str(exe.parent),
            compatdata=str(compatdata), status="installing", backend="steam",
            compat_tool=DEFAULT_STEAM_COMPAT_TOOL, created_at=started_at,
            cleanup_on_failure=cleanup_on_failure, proton_log_dir=str(proton_log_dir),
            retry_count=0,
        )
        launcher_log = open(proton_log_dir / "launcher.log", "a", encoding="utf-8")
        proc = subprocess.Popen(
            [str(proton), "run", str(exe)],
            cwd=str(exe.parent), env=env, stdout=launcher_log, stderr=launcher_log,
            start_new_session=True, close_fds=True,
        )
        launcher_log.close()
        with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as summary:
            summary.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {game_name} AppID={appid} log={proton_log_dir}\n")
    except Exception as exc:
        error(f"Could not launch the installer with Proton Experimental:\n\n{exc}\n\nLog folder:\n{proton_log_dir}")
        return

    # Steam stays open for the whole installer. Final Steam integration happens
    # only after Proton/Wine has completely finished.
    launch_direct_proton_watcher(appid, game_name, started_at, proc.pid, proton)


def list_steam_native_games():
    games = load_steam_registry()
    return [entry for entry in games.values() if entry.get("status") in {"installed", "detached", "pending_steam"}]


def run_existing_steam(exe: Path):
    games = [x for x in list_steam_native_games() if x.get("final_exe")]
    if not games:
        error("No Steam-native One-Click games were found.")
        return
    args = ["--menu", "Run this EXE inside which Steam game prefix?"]
    by_id = {}
    for entry in sorted(games, key=lambda x: str(x.get("name", "")).casefold()):
        key = str(entry["appid"])
        by_id[key] = entry
        args.extend([key, entry.get("name", key)])
    key = dialog(args)
    if not key:
        return
    entry = by_id[key]
    appid = int(entry["appid"])
    game_name = str(entry.get("name") or appid)

    selected_tool = _current_steam_compat_tool(appid) or str(entry.get("compat_tool") or DEFAULT_STEAM_COMPAT_TOOL)
    proton, resolved_name = _find_proton_for_tool(selected_tool)
    if not proton:
        error(
            "Could not find a Proton executable for this game.\n\n"
            "Install Proton Experimental or select an installed Proton version in Steam and try again."
        )
        return

    started_at = int(time.time())
    log_dir = _new_proton_log_dir(f"{game_name}-update", appid, started_at)
    try:
        env, compatdata = _direct_proton_env(appid, log_dir)
        launcher_log = open(log_dir / "launcher.log", "a", encoding="utf-8")
        proc = subprocess.Popen(
            [str(proton), "run", str(exe)],
            cwd=str(exe.parent), env=env, stdout=launcher_log, stderr=launcher_log,
            start_new_session=True, close_fds=True,
        )
        launcher_log.close()
        with open(STEAM_NATIVE_LOG, "a", encoding="utf-8") as summary:
            summary.write(
                f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] UPDATE {game_name} AppID={appid} "
                f"tool={resolved_name} log={log_dir}\n"
            )
    except Exception as exc:
        error(f"Could not launch the update/patch with {resolved_name}:\n\n{exc}\n\nLog folder:\n{log_dir}")
        return

    launch_direct_update_watcher(appid, game_name, proc.pid, proton, log_dir, exe, 0)


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


def _clean_child_env():
    # Desktop-launched helpers inherit GIO/activation variables identifying the
    # parent as "One-Click Game Installer". If Steam inherits them, KDE's
    # PipeWire portal can attribute Steam's own capture request to One-Click and
    # repeatedly show a misleading screen-sharing dialog. Strip those variables
    # before launching Steam.
    env = os.environ.copy()
    for key in (
        "GIO_LAUNCHED_DESKTOP_FILE",
        "GIO_LAUNCHED_DESKTOP_FILE_PID",
        "DESKTOP_STARTUP_ID",
        "XDG_ACTIVATION_TOKEN",
    ):
        env.pop(key, None)
    return env


def start_steam():
    # Prefer launching Steam through its real desktop entry. Besides giving KDE
    # the correct application identity, this avoids the screen-share portal being
    # associated with One-Click after repair/install/remove operations.
    env = _clean_child_env()
    gtk_launch = shutil.which("gtk-launch")
    if gtk_launch:
        for desktop_id in ("steam.desktop", "com.valvesoftware.Steam.desktop"):
            try:
                result = subprocess.run(
                    [gtk_launch, desktop_id],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env=env,
                    timeout=3,
                )
                if result.returncode == 0:
                    return True
            except subprocess.TimeoutExpired:
                # gtk-launch may remain attached briefly even though Steam has
                # already started. Treat that as success if the client appears.
                if steam_is_running():
                    return True
            except Exception:
                pass

    steam = shutil.which("steam")
    if not steam:
        return False
    try:
        subprocess.Popen(
            [steam, "-silent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=env,
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
from lutris.util import resources
from lutris.util.steam import shortcut as steam_shortcut


def install_steamos_safe_shortcut_generator():
    # Use a tiny host-side wrapper instead of launching the Lutris Flatpak
    # directly from Steam. The wrapper keeps SteamGameId for UMU/Gaming Mode
    # but strips Steam's outer runtime/Proton variables before starting Lutris.
    # We deliberately keep Lutris' original explicit shortcut AppID, so
    # existing artwork filenames remain stable after Repair.
    original = steam_shortcut.generate_shortcut
    if getattr(original, "_lutris_oneclick_steamos_safe", False):
        return

    def fixed_generate_shortcut(game, launch_config_name):
        shortcut = original(game, launch_config_name)
        exe = str(shortcut.get("Exe", "")).strip('\"')
        if exe == "/usr/bin/flatpak":
            host_wrapper = os.path.expanduser("~/.local/bin/oneclick-lutris-steam-launch")
            shortcut["Exe"] = '"' + host_wrapper + '"'
            shortcut["StartDir"] = '"' + os.path.expanduser("~") + '"'
            shortcut["LaunchOptions"] = str(game.id)
        return shortcut

    fixed_generate_shortcut._lutris_oneclick_steamos_safe = True
    steam_shortcut.generate_shortcut = fixed_generate_shortcut


install_steamos_safe_shortcut_generator()

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
    # through Lutris' own shortcut implementation, with the current
    # SteamOS-safe Flatpak LaunchOptions backported above.
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


def launch_background_artwork(game_id, game_name):
    """Run the normal artwork engine silently after an automatic install.

    This never blocks or fails the installation flow. Official Steam artwork is
    attempted even if no SteamGridDB API key has been saved yet; SteamGridDB is
    simply unavailable as a fallback until the user saves a key in the Tools UI.
    """
    if not TOOLS_GUI_PATH.is_file():
        return False

    try:
        log = open(BACKGROUND_ARTWORK_LOG, "a", encoding="utf-8")
        subprocess.Popen(
            [
                "flatpak",
                "run",
                "--command=python3",
                APP_ID,
                str(TOOLS_GUI_PATH),
                "--background-artwork",
                str(game_id),
                str(game_name or ""),
            ],
            stdout=log,
            stderr=log,
            start_new_session=True,
            close_fds=True,
        )
        log.close()
        return True
    except Exception:
        return False


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
            shortcut_ok = repair_shortcut_with_steam_restart(
                game_id,
                detected_name or game_name,
                ask=False,
                close_steam=False,
                reopen_steam=False,
            )
            if shortcut_ok:
                # Fire-and-forget: artwork is downloaded/applied silently while
                # the user continues in Desktop Mode. It will already be ready
                # when Steam next reloads / Gaming Mode opens.
                launch_background_artwork(
                    game_id,
                    detected_name or game_name,
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
        reopen_steam=False,
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


def _smart_title_case(text: str) -> str:
    """Make installer-style lowercase names look like game titles."""
    small_words = {
        "a", "an", "and", "as", "at", "but", "by", "for", "from",
        "in", "into", "of", "on", "or", "the", "to", "with",
    }
    roman = {
        "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x",
        "xi", "xii", "xiii", "xiv", "xv",
    }
    special = {
        "vr": "VR",
        "hd": "HD",
        "pc": "PC",
        "rpg": "RPG",
        "fps": "FPS",
        "goty": "GOTY",
        "dx": "DX",
    }

    words = text.split()
    out = []

    for index, word in enumerate(words):
        low = word.lower()

        if low in roman:
            out.append(low.upper())
            continue

        if low in special:
            out.append(special[low])
            continue

        if low in small_words and index not in (0, len(words) - 1):
            out.append(low)
            continue

        # Preserve mixed-case names if the original installer already had them.
        if any(ch.isupper() for ch in word[1:]):
            out.append(word)
        elif word:
            out.append(word[0].upper() + word[1:])
        else:
            out.append(word)

    return " ".join(out)


def _clean_installer_name(raw_name: str) -> str:
    """Best-effort cleanup for GOG and other common Windows installer names."""
    name = raw_name.strip()

    # Common installer prefixes:
    # setup_game, install-game, installer.game, gog_setup_game, etc.
    name = re.sub(
        r"(?ix)^"
        r"(?:gog[\s_.-]*)?"
        r"(?:setup|installer?|install|game[\s_.-]*installer|game[\s_.-]*setup)"
        r"[\s_.-]+",
        "",
        name,
    )

    # GOG and similar installers often end with metadata such as:
    # _(64bit)_(89650), (x64), (32bit), (windows), (gog), etc.
    metadata_pattern = re.compile(
        r"(?ix)"
        r"[\s_.-]*"
        r"\("
        r"(?:"
        r"x?64|amd64|64[\s_-]*bit|"
        r"x86|32[\s_-]*bit|"
        r"win(?:32|64)?|windows|"
        r"gog|offline|"
        r"\d{4,}"
        r")"
        r"\)"
        r"$"
    )

    previous = None
    while previous != name:
        previous = name
        name = metadata_pattern.sub("", name).strip(" _.-")

    # Also strip common architecture/platform tokens when not parenthesized.
    name = re.sub(
        r"(?ix)[\s_.-]+"
        r"(?:x64|amd64|64[\s_-]*bit|x86|32[\s_-]*bit|win64|win32|windows)"
        r"$",
        "",
        name,
    )

    # Strip a trailing dotted version, but keep normal title numbers.
    #
    # Examples removed:
    #   1.0
    #   1.0.30000
    #   v2.31
    #   version-1.4.2
    #
    # Examples preserved:
    #   The Witcher 3
    #   Cyberpunk 2077
    #   Resident Evil 4
    name = re.sub(
        r"(?ix)"
        r"[\s_-]+"
        r"(?:v(?:er(?:sion)?)?[\s_.-]*)?"
        r"\d+(?:\.\d+){1,}"
        r"(?:[a-z0-9.-]*)?"
        r"$",
        "",
        name,
    )

    # Trailing build/revision markers.
    name = re.sub(
        r"(?ix)[\s_.-]+(?:build|revision|rev)[\s_.-]*\d+$",
        "",
        name,
    )

    # Generic suffixes.
    name = re.sub(
        r"(?ix)[\s_.-]+(?:setup|installer?|install|offline[\s_-]*installer)$",
        "",
        name,
    )

    # Convert filename separators to normal spaces only AFTER stripping versions.
    name = re.sub(r"[_]+", " ", name)
    name = re.sub(r"\.{2,}", " ", name)
    name = re.sub(r"(?<!\d)\.(?!\d)", " ", name)
    name = re.sub(r"\s+", " ", name).strip(" -_.")

    return name


def derive_default_name(exe: Path):
    raw = exe.stem.strip()

    generic = {
        "setup", "setup64", "setup_x64", "setup-x64",
        "install", "installer", "gameinstaller",
        "game-installer", "start", "launcher",
    }

    # If the executable is literally just "setup.exe", the enclosing folder
    # is usually a better clue.
    if raw.lower() in generic and exe.parent.name:
        raw = exe.parent.name

    name = _clean_installer_name(raw)

    # If cleanup produced something useless, make one attempt using the folder.
    if not name or name.lower() in generic or re.fullmatch(r"[\d\s._-]+", name):
        name = _clean_installer_name(exe.parent.name)

    if not name:
        return "New Lutris Game"

    return _smart_title_case(name)


def install_new_lutris(exe: Path, game_name=None):
    if not game_name:
        game_name = dialog([
            "--inputbox",
            "Detected game name (edit if needed):",
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


def run_existing_lutris(exe: Path):
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


def install_new(exe: Path, game_name=None, backend_override=None):
    backend = str(backend_override or installer_backend()).strip().lower()
    if backend == "lutris":
        return install_new_lutris(exe, game_name=game_name)
    return install_new_steam(exe, game_name=game_name)


def run_existing(exe: Path):
    if installer_backend() == "lutris":
        return run_existing_lutris(exe)
    return run_existing_steam(exe)


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
        # run as its own Python process inside the Lutris Flatpak. The action
        # dialog also runs inside this Flatpak; mark the shutdown as intentional
        # so its parent helper does not show a false crash popup.
        try:
            ACTION_DIALOG_INTENTIONAL_CLOSE.write_text(str(time.time()), encoding="utf-8")
        except Exception:
            pass
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

    if mode == "add-folder":
        if len(sys.argv) != 3:
            sys.exit(2)
        add_existing_from_folder(Path(sys.argv[2]))
        return

    if mode == "find-install-folder":
        if len(sys.argv) != 3:
            sys.exit(2)
        find_exe_and_open_installer(Path(sys.argv[2]))
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

    if mode == "protonwatch-native":
        if len(sys.argv) != 7:
            sys.exit(2)
        _direct_proton_watch(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6])
        return

    if mode == "cleanup-failed":
        result = cleanup_tracked_failed_installs()
        print(json.dumps(result))
        return

    if mode == "finalize-pending-steam":
        if len(sys.argv) < 3:
            sys.exit(2)
        _deferred_steam_finalize(int(sys.argv[2]))
        return

    if mode == "protonwatch-update":
        if len(sys.argv) < 7:
            sys.exit(2)
        update_exe = sys.argv[7] if len(sys.argv) >= 8 else ""
        retry_count = int(sys.argv[8]) if len(sys.argv) >= 9 and sys.argv[8] else 0
        _direct_update_watch(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], update_exe, retry_count)
        return

    if mode == "steamwatch-native":
        if len(sys.argv) not in (5, 6):
            sys.exit(2)
        restore = sys.argv[5] if len(sys.argv) == 6 else ""
        _steam_native_watch(int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), restore)
        return

    if len(sys.argv) != 3:
        sys.exit(2)

    exe = Path(sys.argv[2]).expanduser().resolve()
    if not exe.is_file():
        error(f"EXE not found:\n\n{exe}")
        sys.exit(1)

    if mode == "new":
        handle_new_exe(exe)
    elif mode == "existing":
        run_existing(exe)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
__PYHELPER_41C2__

chmod +x "$HELPER"

# Small GTK dialog used for the double-click workflow and for adding an
# already-complete game folder. It runs inside the Lutris Flatpak so we can use
# GTK without requiring extra host packages beyond what One-Click already uses.
cat > "$ACTION_GUI" <<'__ACTION_GUI_V67__'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk, Pango


def install_css():
    css = b"""
    window, dialog, .oneclick-root {
        background-color: #f6f7f9;
        color: #202124;
    }
    .headline { font-size: 16pt; font-weight: 700; color: #202124; }
    .subtitle { color: #70757a; font-size: 9.5pt; }
    .section { color: #6b7075; font-size: 8.5pt; font-weight: 700; letter-spacing: 0.7px; }
    .option-title { font-weight: 600; color: #202124; }
    .option-desc { color: #747983; font-size: 9pt; }
    .update-note {
        color: #6d5200; background-color: #fff4c2; border: 1px solid #ead58b;
        border-radius: 7px; padding: 7px;
    }
    entry {
        min-height: 34px; padding-left: 9px; padding-right: 9px;
        background-color: #ffffff; color: #202124;
        border: 1px solid #cfd3d8; border-radius: 7px;
    }
    entry:focus { border-color: #2f80ed; }
    combobox button {
        min-height: 40px; padding-left: 12px; padding-right: 12px;
        background-image: none; background-color: #ffffff; color: #202124;
        border: 1px solid #cfd3d8; border-radius: 7px; box-shadow: none;
    }
    button.primary {
        min-height: 36px; min-width: 112px; background-image: none;
        background-color: #2f80ed; color: #ffffff; border: 1px solid #2f80ed;
        border-radius: 7px; box-shadow: none; text-shadow: none; -gtk-icon-shadow: none;
    }
    button.primary label { color: #ffffff; text-shadow: none; }
    button.primary:hover { background-color: #1f6fd5; border-color: #1f6fd5; }
    button.secondary {
        min-height: 36px; min-width: 92px; background-image: none;
        background-color: #ffffff; color: #4b5156; border: 1px solid #cfd3d8;
        border-radius: 7px; box-shadow: none;
    }
    button.secondary:hover { background-color: #f0f2f4; }
    radiobutton { padding-top: 2px; padding-bottom: 2px; }
    """
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    screen = Gdk.Screen.get_default()
    if screen:
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def emit(value):
    print("ONECLICK_RESULT=" + json.dumps(value, ensure_ascii=False), flush=True)


def labeled_option(label, description, group=None):
    if group is None:
        radio = Gtk.RadioButton.new_with_label_from_widget(None, label)
    else:
        radio = Gtk.RadioButton.new_with_label_from_widget(group, label)
    radio.get_style_context().add_class("option-title")
    desc = Gtk.Label(label=description)
    desc.set_xalign(0)
    desc.set_line_wrap(True)
    desc.get_style_context().add_class("option-desc")
    desc.set_margin_start(24)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    box.pack_start(radio, False, False, 0)
    box.pack_start(desc, False, False, 0)
    return radio, box


def new_exe_dialog(exe_text, suggested, likely_update, default_backend="steam"):
    dlg = Gtk.Dialog(title="One-Click Game Installer")
    dlg.set_default_size(520, 360)
    dlg.set_resizable(False)
    dlg.set_position(Gtk.WindowPosition.CENTER)
    dlg.set_icon_name("net.lutris.Lutris")
    dlg.set_default_response(Gtk.ResponseType.OK)
    # We use our own centered footer instead of GTK's side-aligned dialog action area.
    dlg.get_action_area().set_no_show_all(True)
    dlg.get_action_area().hide()

    area = dlg.get_content_area()
    area.get_style_context().add_class("oneclick-root")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    box.set_border_width(18)
    area.pack_start(box, True, True, 0)

    top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    heading = Gtk.Label(label="What would you like to do?")
    heading.set_xalign(0)
    heading.set_hexpand(True)
    heading.get_style_context().add_class("headline")
    top_row.pack_start(heading, True, True, 0)

    backend_combo = Gtk.ComboBoxText()
    backend_combo.append("steam", "Steam / Proton")
    backend_combo.append("lutris", "Lutris / Wine")
    backend_combo.set_active_id(default_backend if default_backend in {"steam", "lutris"} else "steam")
    backend_combo.set_tooltip_text("Backend for this new installation only. Your Settings default is not changed.")
    top_row.pack_end(backend_combo, False, False, 0)
    box.pack_start(top_row, False, False, 0)

    file_label = Gtk.Label(label=Path(exe_text).name)
    file_label.set_xalign(0)
    file_label.set_ellipsize(Pango.EllipsizeMode.END)
    file_label.set_margin_top(4)
    file_label.set_margin_bottom(12)
    file_label.get_style_context().add_class("subtitle")
    box.pack_start(file_label, False, False, 0)

    name_label = Gtk.Label(label="GAME NAME")
    name_label.set_xalign(0)
    name_label.set_margin_bottom(5)
    name_label.get_style_context().add_class("section")
    box.pack_start(name_label, False, False, 0)

    entry = Gtk.Entry()
    entry.set_text(suggested)
    entry.set_activates_default(True)
    entry.set_margin_bottom(13)
    box.pack_start(entry, False, False, 0)

    if likely_update:
        note = Gtk.Label(label="This filename looks like an update or patch, so Update is selected automatically.")
        note.set_xalign(0)
        note.set_line_wrap(True)
        note.set_margin_bottom(10)
        note.get_style_context().add_class("update-note")
        box.pack_start(note, False, False, 0)

    install_radio, install_box = labeled_option(
        "Install as a new game",
        "Run this EXE as an installer using your selected One-Click backend.",
    )
    update_radio, update_box = labeled_option(
        "Update an installed game",
        "Run this EXE inside an existing game's current Steam Proton or Lutris prefix.",
        install_radio,
    )
    existing_radio, existing_box = labeled_option(
        "Add existing game to Steam (no install)",
        "Use an already-complete game EXE, create the Steam shortcut, and fetch artwork only.",
        install_radio,
    )
    for opt in (install_box, update_box, existing_box):
        opt.set_margin_bottom(7)
        box.pack_start(opt, False, False, 0)

    footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
    footer.set_halign(Gtk.Align.CENTER)
    footer.set_margin_top(8)
    cancel = Gtk.Button(label="Cancel")
    cancel.get_style_context().add_class("secondary")
    cancel.connect("clicked", lambda *_: dlg.response(Gtk.ResponseType.CANCEL))
    go = Gtk.Button(label="Continue")
    go.get_style_context().add_class("primary")
    go.connect("clicked", lambda *_: dlg.response(Gtk.ResponseType.OK))
    footer.pack_start(cancel, False, False, 0)
    footer.pack_start(go, False, False, 0)
    box.pack_start(footer, False, False, 0)
    entry.connect("activate", lambda *_: dlg.response(Gtk.ResponseType.OK))

    (update_radio if likely_update else install_radio).set_active(True)

    def sync_backend_sensitivity(*_args):
        backend_combo.set_sensitive(install_radio.get_active())
        if install_radio.get_active():
            backend_combo.set_tooltip_text("Backend for this new installation only. Your Settings default is not changed.")
        elif update_radio.get_active():
            backend_combo.set_tooltip_text("Updates automatically use the selected installed game's existing backend/prefix.")
        else:
            backend_combo.set_tooltip_text("Add existing game to Steam is always Steam-native.")

    for radio in (install_radio, update_radio, existing_radio):
        radio.connect("toggled", sync_backend_sensitivity)
    sync_backend_sensitivity()

    dlg.show_all()
    response = dlg.run()
    name = entry.get_text().strip()
    if response == Gtk.ResponseType.OK and name:
        action = "install"
        if update_radio.get_active():
            action = "update"
        elif existing_radio.get_active():
            action = "existing"
        emit({"action": action, "name": name, "backend": backend_combo.get_active_id() or default_backend})
    dlg.destroy()


def human_size(value):
    try:
        size = float(value)
    except Exception:
        return ""
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{int(size)} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return ""


def folder_dialog(folder_text, suggested, payload_text, purpose="existing"):
    install_mode = str(purpose).strip().lower() == "install"
    try:
        items = json.loads(payload_text)
    except Exception:
        items = []
    if not isinstance(items, list) or not items:
        return

    dlg = Gtk.Dialog(title="Find Game EXE" if install_mode else "Add Existing Game to Steam")
    dlg.set_default_size(610, 390)
    dlg.set_resizable(False)
    dlg.set_position(Gtk.WindowPosition.CENTER)
    dlg.set_icon_name("net.lutris.Lutris")
    cancel = dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    cancel.get_style_context().add_class("secondary")
    go = dlg.add_button("Continue" if install_mode else "Create Steam Shortcut", Gtk.ResponseType.OK)
    go.get_style_context().add_class("primary")
    dlg.set_default_response(Gtk.ResponseType.OK)

    area = dlg.get_content_area()
    area.get_style_context().add_class("oneclick-root")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    box.set_border_width(24)
    area.pack_start(box, True, True, 0)

    heading = Gtk.Label(label="Choose the EXE to open" if install_mode else "Add an already-complete game")
    heading.set_xalign(0)
    heading.get_style_context().add_class("headline")
    box.pack_start(heading, False, False, 0)

    sub = Gtk.Label(label=f"One-Click scanned: {folder_text}")
    sub.set_xalign(0)
    sub.set_ellipsize(Pango.EllipsizeMode.END)
    sub.set_margin_top(4)
    sub.set_margin_bottom(18)
    sub.get_style_context().add_class("subtitle")
    box.pack_start(sub, False, False, 0)

    name_label = Gtk.Label(label="GAME NAME")
    name_label.set_xalign(0)
    name_label.set_margin_bottom(5)
    name_label.get_style_context().add_class("section")
    box.pack_start(name_label, False, False, 0)
    entry = Gtk.Entry()
    entry.set_text(suggested)
    entry.set_margin_bottom(16)
    box.pack_start(entry, False, False, 0)
    name_state = {"manual": False, "internal": False}

    def mark_name_manual(*_args):
        if not name_state["internal"]:
            name_state["manual"] = True

    entry.connect("changed", mark_name_manual)

    exe_label = Gtk.Label(label="MAIN GAME EXE")
    exe_label.set_xalign(0)
    exe_label.set_margin_bottom(6)
    exe_label.get_style_context().add_class("section")
    box.pack_start(exe_label, False, False, 0)

    combo = Gtk.ComboBoxText()
    for idx, item in enumerate(items):
        label = str(item.get("label") or item.get("path") or "")
        size = human_size(item.get("size") or 0)
        if size:
            label += f"   ·   {size}"
        combo.append(str(idx), label)
    combo.set_active(0)
    box.pack_start(combo, False, False, 0)

    def sync_name_to_exe(*_args):
        if name_state["manual"]:
            return
        active = combo.get_active()
        if not (0 <= active < len(items)):
            return
        candidate_name = str(items[active].get("suggested_name") or "").strip()
        if candidate_name and candidate_name != entry.get_text():
            name_state["internal"] = True
            try:
                entry.set_text(candidate_name)
            finally:
                name_state["internal"] = False

    combo.connect("changed", sync_name_to_exe)
    sync_name_to_exe()

    hint = Gtk.Label(label=("Choose the EXE you want One-Click to handle. The game name is inferred from the selected EXE's folders; you can still edit it. Continue opens the normal Install / Update / Add Existing menu." if install_mode else "Candidates are ranked by game-name match, location and file size. The title follows the selected EXE unless you edit it manually. Setup, updater, redistributable and crash-helper EXEs are pushed down or hidden."))
    hint.set_xalign(0)
    hint.set_line_wrap(True)
    hint.set_margin_top(10)
    hint.get_style_context().add_class("option-desc")
    box.pack_start(hint, False, False, 0)

    dlg.show_all()
    response = dlg.run()
    if response == Gtk.ResponseType.OK:
        active = combo.get_active()
        name = entry.get_text().strip()
        if 0 <= active < len(items) and name:
            emit({"name": name, "exe": str(items[active].get("path") or "")})
    dlg.destroy()


def main():
    install_css()
    if len(sys.argv) < 2:
        return
    mode = sys.argv[1]
    if mode == "new-exe" and len(sys.argv) >= 5:
        default_backend = sys.argv[5] if len(sys.argv) >= 6 else "steam"
        new_exe_dialog(sys.argv[2], sys.argv[3], sys.argv[4] == "1", default_backend)
    elif mode == "folder" and len(sys.argv) >= 5:
        folder_dialog(sys.argv[2], sys.argv[3], sys.argv[4], "existing")
    elif mode == "folder-install" and len(sys.argv) >= 5:
        folder_dialog(sys.argv[2], sys.argv[3], sys.argv[4], "install")


if __name__ == "__main__":
    main()
__ACTION_GUI_V67__
chmod +x "$ACTION_GUI"

# Steam-facing launcher for Lutris-backed games. Steam itself can inject its
# runtime/Proton environment into child processes; that is useful for native
# Steam games but can confuse Lutris/UMU when Steam is only being used as a
# frontend. Keep SteamGameId/SteamAppId for UMU's Steam-mode window handling,
# while stripping the outer Steam compatibility/runtime variables before
# entering the Lutris Flatpak.
cat > "$LUTRIS_STEAM_WRAPPER" <<'__LUTRIS_STEAM_WRAPPER__'
#!/usr/bin/env bash
set -euo pipefail

GAME_ID="${1:-}"
if [[ -z "$GAME_ID" ]]; then
  exit 2
fi

STEAM_GAME_ID_VALUE="${SteamGameId:-${STEAM_GAME_ID:-}}"
STEAM_APP_ID_VALUE="${SteamAppId:-${STEAM_APP_ID:-}}"

export LC_ALL=C.UTF-8
export LANG="${LANG:-en_US.UTF-8}"

# Avoid leaking Steam's outer runtime/Proton state into Lutris/UMU. Do not
# unset SteamGameId/SteamAppId: current UMU uses them to identify a non-Steam
# shortcut when launched from Gaming Mode.
unset LD_PRELOAD || true
unset LD_LIBRARY_PATH || true
unset STEAM_RUNTIME || true
unset STEAM_RUNTIME_LIBRARY_PATH || true
unset STEAM_COMPAT_DATA_PATH || true
unset STEAM_COMPAT_CLIENT_INSTALL_PATH || true
unset STEAM_COMPAT_TOOL_PATHS || true
unset STEAM_COMPAT_MOUNTS || true
unset PROTONPATH || true
unset PROTON_VERB || true
unset WINEPREFIX || true
unset WINEDLLOVERRIDES || true

args=(run --env=LC_ALL=C.UTF-8)
if [[ -n "$STEAM_GAME_ID_VALUE" ]]; then
  args+=("--env=SteamGameId=$STEAM_GAME_ID_VALUE")
fi
if [[ -n "$STEAM_APP_ID_VALUE" ]]; then
  args+=("--env=SteamAppId=$STEAM_APP_ID_VALUE")
fi
args+=(net.lutris.Lutris "lutris:rungameid/$GAME_ID")

exec /usr/bin/flatpak "${args[@]}"
__LUTRIS_STEAM_WRAPPER__
chmod +x "$LUTRIS_STEAM_WRAPPER"

cat > "$TOOLS_GUI" <<'__TOOLS_GUI_4A91__'
#!/usr/bin/env python3

import json
import os
import re
import shutil
import shlex
import sqlite3
import ssl
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from difflib import SequenceMatcher
from pathlib import Path

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")

from gi.repository import Gtk, Gdk, GLib, GdkPixbuf, Gio

# Lutris imports must happen after forcing GTK 3.
sys.argv[0] = "/app/bin/lutris"

from lutris.game import Game
from lutris.util import resources
from lutris.util.steam import shortcut as steam_shortcut
from lutris.util.steam import vdf as steam_vdf

TOOL_VERSION = "6.7.17"


def install_steamos_safe_shortcut_generator():
    # Use a tiny host-side wrapper instead of launching the Lutris Flatpak
    # directly from Steam. The wrapper keeps SteamGameId for UMU/Gaming Mode
    # but strips Steam's outer runtime/Proton variables before starting Lutris.
    # We deliberately keep Lutris' original explicit shortcut AppID, so
    # existing artwork filenames remain stable after Repair.
    original = steam_shortcut.generate_shortcut
    if getattr(original, "_lutris_oneclick_steamos_safe", False):
        return

    def fixed_generate_shortcut(game, launch_config_name):
        shortcut = original(game, launch_config_name)
        exe = str(shortcut.get("Exe", "")).strip('\"')
        if exe == "/usr/bin/flatpak":
            host_wrapper = os.path.expanduser("~/.local/bin/oneclick-lutris-steam-launch")
            shortcut["Exe"] = '"' + host_wrapper + '"'
            shortcut["StartDir"] = '"' + os.path.expanduser("~") + '"'
            shortcut["LaunchOptions"] = str(game.id)
        return shortcut

    fixed_generate_shortcut._lutris_oneclick_steamos_safe = True
    steam_shortcut.generate_shortcut = fixed_generate_shortcut


install_steamos_safe_shortcut_generator()


APP_ID = "net.lutris.Lutris"
SGDB_BASE_URL = "https://www.steamgriddb.com/api/v2"
SGDB_USER_AGENT = "OneClick-Tools/6.7.9"
STEAM_STORE_SEARCH_URL = "https://store.steampowered.com/api/storesearch/"
STEAM_STORE_BROWSE_URL = "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/"
STEAM_ASSET_BASE_URL = "https://shared.steamstatic.com/store_item_assets/"
STEAM_LEGACY_ASSET_BASE_URL = "https://cdn.cloudflare.steamstatic.com/steam/apps"


def _xdg_dir(env_name, fallback_name):
    value = os.environ.get(env_name)
    if value:
        return Path(value)
    return Path.home() / fallback_name


SGDB_CONFIG_DIR = _xdg_dir("XDG_CONFIG_HOME", ".config") / "lutris-oneclick"
SGDB_CONFIG_FILE = SGDB_CONFIG_DIR / "steamgriddb.json"
SGDB_MATCH_OVERRIDES_FILE = SGDB_CONFIG_DIR / "steamgriddb-matches.json"
SETTINGS_FILE = SGDB_CONFIG_DIR / "settings.json"
STEAM_NATIVE_REGISTRY = Path.home() / ".local/share/oneclick-exe/steam-native-games.json"
DEFAULT_INSTALLER_BACKEND = "steam"
DEFAULT_STEAM_COMPAT_TOOL = "proton_experimental"


def load_oneclick_settings():
    try:
        data = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_oneclick_settings(settings):
    SGDB_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    temp = SETTINGS_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(settings, indent=2, sort_keys=True), encoding="utf-8")
    try:
        os.chmod(temp, 0o600)
    except OSError:
        pass
    temp.replace(SETTINGS_FILE)
    try:
        os.chmod(SETTINGS_FILE, 0o600)
    except OSError:
        pass


def load_installer_backend():
    value = str(load_oneclick_settings().get("installer_backend", DEFAULT_INSTALLER_BACKEND)).strip().lower()
    return value if value in {"steam", "lutris"} else DEFAULT_INSTALLER_BACKEND


def load_steam_native_registry():
    try:
        data = json.loads(STEAM_NATIVE_REGISTRY.read_text(encoding="utf-8"))
        games = data.get("games", {}) if isinstance(data, dict) else {}
        return games if isinstance(games, dict) else {}
    except Exception:
        return {}


def save_steam_native_registry(games):
    STEAM_NATIVE_REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    temp = STEAM_NATIVE_REGISTRY.with_suffix(".tmp")
    temp.write_text(json.dumps({"version": 1, "games": games}, indent=2, sort_keys=True), encoding="utf-8")
    temp.replace(STEAM_NATIVE_REGISTRY)


def update_steam_native_registry(appid, **updates):
    games = load_steam_native_registry()
    key = str(int(appid))
    entry = dict(games.get(key) or {})
    entry.update(updates)
    entry["appid"] = int(appid)
    games[key] = entry
    save_steam_native_registry(games)
    return entry


def delete_steam_native_registry(appid):
    games = load_steam_native_registry()
    games.pop(str(int(appid)), None)
    save_steam_native_registry(games)


def queue_steam_native_icon_refresh(appid, icon_path):
    """Persist the icon path and update shortcuts.vdf on Steam's next close.

    Steam does not reliably reload external shortcuts.vdf edits while running,
    so never force-close it here. The host helper already knows how to wait
    until Steam naturally stops (for example when entering Gaming Mode).
    """
    icon_path = str(icon_path or "").strip()
    if not icon_path or not Path(icon_path).is_file():
        return False
    games = load_steam_native_registry()
    key = str(int(appid))
    entry = dict(games.get(key) or {})
    if not entry.get("final_exe"):
        return False
    entry["icon"] = icon_path
    entry["status"] = "pending_steam"
    entry["updated_at"] = int(time.time())
    entry["appid"] = int(appid)
    games[key] = entry
    save_steam_native_registry(games)

    host_helper = Path.home() / ".local/bin/lutris-exe-helper"
    if not host_helper.is_file():
        return True
    try:
        spawn = shutil.which("flatpak-spawn")
        if spawn:
            subprocess.Popen(
                [spawn, "--host", str(host_helper), "finalize-pending-steam", str(int(appid))],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True,
            )
        else:
            subprocess.Popen(
                [str(host_helper), "finalize-pending-steam", str(int(appid))],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True,
            )
    except Exception:
        # The path is still saved; Repair or a future installer finalizer can
        # apply it later even if the host-spawn helper was unavailable.
        pass
    return True

SGDB_CACHE_ROOT = _xdg_dir("XDG_CACHE_HOME", ".cache") / "lutris-oneclick" / "steamgriddb"
# Keep failure windows short: all five artwork types run concurrently, so a
# flaky CDN should cost seconds, not minutes.
SGDB_API_TIMEOUT = 5
SGDB_IMAGE_TIMEOUT = 3
STEAM_API_TIMEOUT = 5
STEAM_IMAGE_TIMEOUT = 4
SGDB_CACHE_FRESH_SECONDS = 24 * 60 * 60
SGDB_CONFIG_LOCK = threading.Lock()


def load_sgdb_api_key():
    try:
        data = json.loads(SGDB_CONFIG_FILE.read_text(encoding="utf-8"))
        return str(data.get("api_key", "")).strip()
    except Exception:
        return ""


def load_sgdb_match_overrides():
    try:
        data = json.loads(SGDB_MATCH_OVERRIDES_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def get_sgdb_match_override(game_name):
    entry = load_sgdb_match_overrides().get(normalize_game_name(game_name))
    if isinstance(entry, dict) and entry.get("id") is not None:
        return entry
    return None


def save_sgdb_match_override(game_name, candidate):
    if not isinstance(candidate, dict) or candidate.get("id") is None:
        return False
    SGDB_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    data = load_sgdb_match_overrides()
    data[normalize_game_name(game_name)] = {
        "id": int(candidate["id"]),
        "name": str(candidate.get("name") or game_name),
        "types": candidate.get("types") or [],
        "verified": bool(candidate.get("verified")),
        "saved_at": int(time.time()),
    }
    temp = SGDB_MATCH_OVERRIDES_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    temp.replace(SGDB_MATCH_OVERRIDES_FILE)
    return True


def save_sgdb_api_key(api_key):
    # Batch artwork jobs can overlap, so serialize the tiny settings write.
    with SGDB_CONFIG_LOCK:
        SGDB_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        temp = SGDB_CONFIG_FILE.with_suffix(".tmp")
        temp.write_text(json.dumps({"api_key": api_key}, indent=2), encoding="utf-8")
        try:
            os.chmod(temp, 0o600)
        except OSError:
            pass
        temp.replace(SGDB_CONFIG_FILE)
        try:
            os.chmod(SGDB_CONFIG_FILE, 0o600)
        except OSError:
            pass


def _host_run(command, timeout=20):
    """Run a small command on the SteamOS host from the Lutris Flatpak."""
    return subprocess.run(
        ["flatpak-spawn", "--host", "sh", "-lc", command],
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def host_steam_is_running():
    try:
        result = _host_run("pgrep -x steam >/dev/null 2>&1", timeout=5)
        return result.returncode == 0
    except Exception:
        return False


def stop_host_steam(timeout=18):
    """Stop Steam cleanly so VDF edits cannot be overwritten by the client."""
    if not host_steam_is_running():
        return False
    try:
        _host_run("steam -shutdown >/dev/null 2>&1 || true", timeout=8)
    except Exception:
        pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not host_steam_is_running():
            return True
        time.sleep(0.4)
    return False


def start_host_steam():
    # Start Steam through its desktop identity and strip activation variables
    # inherited from the One-Click/Lutris Flatpak. This prevents KDE's screen
    # sharing portal from repeatedly labelling Steam's own capture request as
    # "One-Click Game Installer" after repairs/removals.
    command = (
        "unset GIO_LAUNCHED_DESKTOP_FILE GIO_LAUNCHED_DESKTOP_FILE_PID "
        "DESKTOP_STARTUP_ID XDG_ACTIVATION_TOKEN; "
        "if command -v gtk-launch >/dev/null 2>&1; then "
        "(gtk-launch steam.desktop >/dev/null 2>&1 || gtk-launch com.valvesoftware.Steam.desktop >/dev/null 2>&1) & "
        "else nohup steam -silent >/dev/null 2>&1 & fi"
    )
    try:
        _host_run(command, timeout=5)
        return True
    except Exception:
        return False


def steam_root_from_user_config(config_path):
    """Convert .../Steam/userdata/<uid>/config to the Steam install root."""
    path = Path(config_path).expanduser()
    for parent in (path, *path.parents):
        if parent.name == "userdata":
            return parent.parent
    # Normal Lutris/SteamOS layout fallback.
    try:
        return path.parents[2]
    except IndexError:
        return None


def _matching_brace(text, open_index):
    depth = 0
    quoted = False
    escaped = False
    for index in range(open_index, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return -1


def _find_vdf_named_block(text, name, start=0, end=None):
    limit = len(text) if end is None else min(len(text), end)
    match = re.search(r'"' + re.escape(str(name)) + r'"', text[start:limit], re.IGNORECASE)
    if not match:
        return None
    key_start = start + match.start()
    key_end = start + match.end()
    open_index = text.find("{", key_end, limit)
    if open_index < 0:
        return None
    close_index = _matching_brace(text, open_index)
    if close_index < 0 or close_index >= limit:
        return None
    return key_start, open_index, close_index


def remove_steam_compat_mapping(config_path, appid):
    """Remove Steam's forced-Proton mapping for this Lutris launcher shortcut."""
    steam_root = steam_root_from_user_config(config_path)
    if not steam_root:
        return False
    config_vdf = steam_root / "config" / "config.vdf"
    if not config_vdf.is_file():
        return False

    try:
        text = config_vdf.read_text(encoding="utf-8", errors="replace")
        outer = _find_vdf_named_block(text, "CompatToolMapping")
        if not outer:
            return False
        _, outer_open, outer_close = outer
        inner_start = outer_open + 1
        inner_end = outer_close
        entry = _find_vdf_named_block(text, str(appid), inner_start, inner_end)
        if not entry:
            return False
        key_start, _entry_open, entry_close = entry

        # Remove the complete entry including indentation and one trailing newline.
        line_start = text.rfind("\n", 0, key_start) + 1
        remove_end = entry_close + 1
        while remove_end < len(text) and text[remove_end] in " \t":
            remove_end += 1
        if remove_end < len(text) and text[remove_end] == "\r":
            remove_end += 1
        if remove_end < len(text) and text[remove_end] == "\n":
            remove_end += 1

        backup = config_vdf.with_name("config.vdf.lutris-oneclick.bak")
        if not backup.exists():
            shutil.copy2(config_vdf, backup)
        temp = config_vdf.with_suffix(".vdf.tmp")
        temp.write_text(text[:line_start] + text[remove_end:], encoding="utf-8")
        temp.replace(config_vdf)
        return True
    except Exception:
        return False


def remove_steam_launcher_compatdata(config_path, appid):
    """Delete only the Proton prefix Steam created around the Lutris launcher."""
    steam_root = steam_root_from_user_config(config_path)
    if not steam_root:
        return False
    path = steam_root / "steamapps" / "compatdata" / str(appid)
    try:
        if path.is_dir():
            shutil.rmtree(path)
            return True
    except Exception:
        return False
    return False


def remove_game_artwork_files(config_path, appid):
    """Remove Steam-applied artwork and our cached downloads for one shortcut."""
    removed = 0
    grid_dir = Path(config_path) / "grid"
    stems = (
        str(appid),
        f"{appid}p",
        f"{appid}_hero",
        f"{appid}_logo",
        f"{appid}_icon",
    )
    try:
        if grid_dir.is_dir():
            for stem in stems:
                for path in grid_dir.glob(stem + ".*"):
                    if path.is_file():
                        path.unlink()
                        removed += 1
    except Exception:
        pass

    try:
        cache_dir = SGDB_CACHE_ROOT / str(appid)
        if cache_dir.is_dir():
            shutil.rmtree(cache_dir)
            removed += 1
    except Exception:
        pass
    return removed


def steam_native_shortcut_exists(appid):
    appid_u = int(appid) & 0xffffffff
    try:
        for shortcut in steam_shortcut.get_shortcuts().values():
            try:
                sid = int(shortcut.get("appid", 0)) & 0xffffffff
            except Exception:
                sid = 0
            if sid == appid_u:
                return True
    except Exception:
        return False
    return False


def steam_native_upsert_shortcut(appid, game_name, exe_path, start_dir, icon_path=""):
    path = steam_shortcut.get_shortcuts_vdf_path()
    if not path:
        raise RuntimeError("Steam active-user shortcuts.vdf could not be located.")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        with open(path, "rb") as fh:
            root = steam_vdf.binary_loads(fh.read())
        current = list((root.get("shortcuts") or {}).values())
        backup = path + ".oneclick.bak"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
    else:
        current = []
    appid_u = int(appid) & 0xffffffff
    appid_s = appid_u if appid_u < 0x80000000 else appid_u - 0x100000000
    kept = []
    for shortcut in current:
        try:
            sid = int(shortcut.get("appid", 0)) & 0xffffffff
        except Exception:
            sid = 0
        if sid != appid_u:
            kept.append(shortcut)
    kept.append({
        "appid": appid_s,
        "AppName": str(game_name),
        "Exe": '"' + str(exe_path) + '"',
        "StartDir": '"' + str(start_dir) + '"',
        "icon": str(icon_path or ""),
        "ShortcutPath": "",
        "LaunchOptions": "",
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {},
    })
    updated = {"shortcuts": {str(index): item for index, item in enumerate(kept)}}
    with open(path, "wb") as fh:
        fh.write(steam_vdf.binary_dumps(updated))


def steam_native_remove_shortcut(appid):
    path = steam_shortcut.get_shortcuts_vdf_path()
    if not path or not os.path.exists(path):
        return False
    with open(path, "rb") as fh:
        root = steam_vdf.binary_loads(fh.read())
    current = list((root.get("shortcuts") or {}).values())
    appid_u = int(appid) & 0xffffffff
    kept = []
    removed = False
    for shortcut in current:
        try:
            sid = int(shortcut.get("appid", 0)) & 0xffffffff
        except Exception:
            sid = 0
        if sid == appid_u:
            removed = True
        else:
            kept.append(shortcut)
    if removed:
        updated = {"shortcuts": {str(index): item for index, item in enumerate(kept)}}
        with open(path, "wb") as fh:
            fh.write(steam_vdf.binary_dumps(updated))
    return removed


def steam_compat_mapping_exists(config_path, appid):
    steam_root = steam_root_from_user_config(config_path)
    if not steam_root:
        return False
    path = steam_root / "config" / "config.vdf"
    if not path.is_file():
        return False
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
        outer = _find_vdf_named_block(text, "CompatToolMapping")
        if not outer:
            return False
        _, open_i, close_i = outer
        return _find_vdf_named_block(text, str(int(appid)), open_i + 1, close_i) is not None
    except Exception:
        return False


def ensure_steam_compat_mapping(config_path, appid, tool=DEFAULT_STEAM_COMPAT_TOOL):
    if steam_compat_mapping_exists(config_path, appid):
        return False
    steam_root = steam_root_from_user_config(config_path)
    if not steam_root:
        raise RuntimeError("Steam installation folder could not be found.")
    path = steam_root / "config" / "config.vdf"
    text = path.read_text(encoding="utf-8", errors="replace")
    outer = _find_vdf_named_block(text, "CompatToolMapping")
    if not outer:
        raise RuntimeError("Steam CompatToolMapping section was not found.")
    _, _open_i, close_i = outer
    snippet = (
        f'\n\t\t\t\t\t\t"{int(appid)}"\n'
        '\t\t\t\t\t\t{\n'
        f'\t\t\t\t\t\t\t"name"\t\t"{tool}"\n'
        '\t\t\t\t\t\t\t"config"\t\t""\n'
        '\t\t\t\t\t\t\t"Priority"\t\t"250"\n'
        '\t\t\t\t\t\t}\n'
    )
    backup = path.with_name("config.vdf.oneclick.bak")
    if not backup.exists():
        shutil.copy2(path, backup)
    temp = path.with_suffix(".vdf.tmp")
    temp.write_text(text[:close_i] + snippet + text[close_i:], encoding="utf-8")
    temp.replace(path)
    return True


def build_ssl_context():
    candidates = [
        os.environ.get("SSL_CERT_FILE", ""),
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
        "/etc/pki/tls/certs/ca-bundle.crt",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            try:
                return ssl.create_default_context(cafile=candidate)
            except Exception:
                pass
    return ssl.create_default_context()


SGDB_SSL_CONTEXT = build_ssl_context()


def sgdb_error_text(payload):
    if not isinstance(payload, dict):
        return "Unknown SteamGridDB error."
    errors = payload.get("errors")
    if isinstance(errors, list) and errors:
        return ", ".join(str(x) for x in errors)
    if isinstance(errors, str) and errors:
        return errors
    return "Unknown SteamGridDB error."


def _sgdb_get_once(path, api_key, params=None):
    url = SGDB_BASE_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params)

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": SGDB_USER_AGENT,
        },
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=SGDB_API_TIMEOUT,
            context=SGDB_SSL_CONTEXT,
        ) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8", "replace"))
            detail = sgdb_error_text(payload)
        except Exception:
            detail = str(exc.reason or exc)

        if exc.code in (401, 403):
            raise RuntimeError(
                "SteamGridDB rejected the API key. Check that it was copied correctly."
            ) from exc
        if exc.code == 429:
            raise RuntimeError(
                "SteamGridDB rate limit reached. Wait a little and try again."
            ) from exc
        raise RuntimeError(f"SteamGridDB request failed ({exc.code}): {detail}") from exc
    except urllib.error.URLError as exc:
        reason = str(getattr(exc, "reason", exc))
        if "CERTIFICATE_VERIFY_FAILED" in reason:
            raise RuntimeError(
                "Could not verify SteamGridDB's HTTPS certificate. "
                "SteamOS/Lutris may need its certificate store refreshed."
            ) from exc
        raise RuntimeError(f"Could not reach SteamGridDB: {reason}") from exc
    except ssl.SSLError as exc:
        raise RuntimeError(f"SteamGridDB HTTPS check failed: {exc}") from exc
    except (TimeoutError, ConnectionError, OSError) as exc:
        raise RuntimeError(f"Could not reach SteamGridDB: {exc}") from exc

    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError("SteamGridDB returned an unreadable response.") from exc

    if not isinstance(payload, dict) or not payload.get("success"):
        raise RuntimeError(sgdb_error_text(payload))
    return payload.get("data")


def sgdb_get(path, api_key, params=None):
    """SteamGridDB request with one fast retry for transient network errors."""
    last_error = None
    for attempt in range(2):
        try:
            return _sgdb_get_once(path, api_key, params)
        except RuntimeError as exc:
            last_error = exc
            message = str(exc).lower()
            # Never retry credentials/rate-limit/client-side failures.
            if (
                "rejected the api key" in message
                or "rate limit" in message
                or "request failed (4" in message
            ):
                raise
            if attempt == 0:
                time.sleep(0.20)
    raise last_error


def get_json_url(url, timeout, label):
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": SGDB_USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=timeout,
            context=SGDB_SSL_CONTEXT,
        ) as response:
            raw = response.read()
    except Exception as exc:
        raise RuntimeError(f"Could not reach {label}: {exc}") from exc
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"{label} returned an unreadable response.") from exc

def normalize_game_name(text):
    text = unicodedata.normalize("NFKD", text or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = text.casefold().replace("&", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def _append_unique_title(values, text):
    text = re.sub(r"\s+", " ", str(text or "")).strip(" -_:")
    if not text:
        return
    norm = normalize_game_name(text)
    if not norm:
        return
    if all(normalize_game_name(existing) != norm for existing in values):
        values.append(text)


def game_title_variants(game_name, extra_hints=None):
    """Generate conservative search aliases without blindly shortening titles.

    This specifically handles common installer/library labels such as
    "Deadpool the Video Game" while retaining the original title as the
    highest-priority query. Folder/EXE hints are only used when they look like
    human game names rather than generic Windows directories.
    """
    variants = []
    _append_unique_title(variants, game_name)

    base = re.sub(r"\s+", " ", str(game_name or "")).strip()
    safe_suffixes = [
        r"\s*[-:–—]?\s*(?:the\s+)?video\s+game$",
        r"\s*[-:–—]?\s*pc\s+version$",
        r"\s*[-:–—]?\s*windows\s+version$",
    ]
    for pattern in safe_suffixes:
        shortened = re.sub(pattern, "", base, flags=re.IGNORECASE).strip(" -_:.()[]")
        if shortened and shortened != base:
            _append_unique_title(variants, shortened)

    # Mild bracket cleanup is useful for labels like "Game (2013)" or
    # "Game [x64]". Never remove an arbitrary subtitle here.
    bracket_raw = re.sub(
        r"\s*[\[(](?:(?:19|20)\d{2}|x64|x86|64[- ]?bit|32[- ]?bit|windows|pc)[\])]\s*$",
        "",
        base,
        flags=re.IGNORECASE,
    )
    if bracket_raw != base:
        bracket_clean = bracket_raw.strip(" -_:.()[]")
        if bracket_clean:
            _append_unique_title(variants, bracket_clean)

    generic_dirs = {
        "bin", "binaries", "binary", "win64", "win32", "x64", "x86",
        "game", "games", "program files", "program files x86", "drive c",
        "gog games", "steamapps", "common",
    }
    for hint in extra_hints or []:
        hint = str(hint or "").strip()
        if not hint:
            continue
        hint = re.sub(r"\.(?:exe|bat|cmd|lnk)$", "", hint, flags=re.IGNORECASE)
        hint = re.sub(r"[_]+", " ", hint)
        hint = re.sub(r"\s+", " ", hint).strip(" -_:.()[]")
        if not hint or normalize_game_name(hint) in generic_dirs:
            continue
        if len(normalize_game_name(hint)) < 3:
            continue
        _append_unique_title(variants, hint)

    return variants[:6]


def _result_types(item):
    raw = item.get("types") if isinstance(item, dict) else None
    if isinstance(raw, list):
        return {str(x).casefold() for x in raw}
    if raw:
        return {str(raw).casefold()}
    return set()


def choose_game_match(query, results, aliases=None):
    if not isinstance(results, list) or not results:
        raise RuntimeError(f'No SteamGridDB match was found for "{query}".')

    alias_values = game_title_variants(query, aliases)
    normalized_aliases = [normalize_game_name(x) for x in alias_values if normalize_game_name(x)]
    original = normalize_game_name(query)

    exact = []
    for item in results:
        candidate = normalize_game_name(str(item.get("name", "")))
        if candidate and candidate in normalized_aliases:
            alias_index = normalized_aliases.index(candidate)
            types = _result_types(item)
            exact.append((
                alias_index,
                0 if "steam" in types else 1,
                0 if item.get("verified") else 1,
                item,
            ))
    if exact:
        exact.sort(key=lambda row: row[:3])
        return exact[0][3]

    ranked = []
    console_types = {"nes", "snes", "n64", "switch", "ps1", "ps2", "ps3", "ps4", "ps5", "xbox", "wii", "wiiu"}
    for item in results:
        candidate = normalize_game_name(str(item.get("name", "")))
        if not candidate:
            continue
        candidate_tokens = set(candidate.split())
        best_score = 0.0
        for alias in normalized_aliases or [original]:
            alias_tokens = set(alias.split())
            score = SequenceMatcher(None, alias, candidate).ratio()
            if alias_tokens and candidate_tokens:
                overlap = len(alias_tokens & candidate_tokens) / max(len(alias_tokens), len(candidate_tokens))
                score = max(score, overlap)
                # A candidate with extra words is risky (e.g. Deadpool (NES)
                # when searching Deadpool), so penalize extra candidate tokens.
                extra_candidate = candidate_tokens - alias_tokens
                if extra_candidate:
                    score -= min(0.24, 0.08 * len(extra_candidate))
                # If the only extra words are harmless descriptive suffix words
                # in our query, reward the shorter canonical database title.
                extra_alias = alias_tokens - candidate_tokens
                harmless = {"the", "video", "game", "pc", "windows", "version"}
                if candidate_tokens and candidate_tokens.issubset(alias_tokens) and extra_alias <= harmless:
                    score += 0.16
            best_score = max(best_score, score)

        types = _result_types(item)
        if "steam" in types:
            best_score += 0.06
        elif types & console_types:
            best_score -= 0.10
        if item.get("verified"):
            best_score += 0.03
        ranked.append((best_score, item))

    ranked.sort(key=lambda pair: pair[0], reverse=True)
    score, best = ranked[0]
    if score < 0.76:
        suggestions = ", ".join(
            str(item.get("name", "")) for _score, item in ranked[:4]
        )
        raise RuntimeError(
            f'Could not confidently match "{query}" on SteamGridDB. '
            f"Closest results: {suggestions or 'none'}."
        )
    return best


def sgdb_candidate_options(game_name, api_key, extra_hints=None, limit=5):
    """Return a short ranked list for the rare manual ambiguity chooser."""
    variants = game_title_variants(game_name, extra_hints)
    gathered = {}
    for search_title in variants[:6]:
        try:
            results = sgdb_get(
                "/search/autocomplete/" + urllib.parse.quote(search_title, safe=""),
                api_key,
            )
        except Exception:
            continue
        for item in results or []:
            if isinstance(item, dict) and item.get("id") is not None:
                gathered[str(item["id"])] = item

    aliases = [normalize_game_name(x) for x in variants if normalize_game_name(x)]
    wanted = normalize_game_name(game_name)
    console_types = {"nes", "snes", "n64", "switch", "ps1", "ps2", "ps3", "ps4", "ps5", "xbox", "wii", "wiiu"}
    ranked = []
    for item in gathered.values():
        candidate = normalize_game_name(str(item.get("name") or ""))
        if not candidate:
            continue
        score = max([SequenceMatcher(None, alias, candidate).ratio() for alias in aliases] or [SequenceMatcher(None, wanted, candidate).ratio()])
        types = _result_types(item)
        if candidate in aliases:
            score += 0.40
        if "steam" in types:
            score += 0.12
        if types & console_types:
            score -= 0.12
        if item.get("verified"):
            score += 0.05
        ranked.append((score, item))
    ranked.sort(key=lambda pair: pair[0], reverse=True)
    return [dict(item) for _score, item in ranked[:max(3, min(5, int(limit)))]]


def search_sgdb_game(game_name, api_key, extra_hints=None):
    """Search original title first, then safe aliases, deduplicating results."""
    variants = game_title_variants(game_name, extra_hints)
    gathered = {}
    last_error = None

    for search_title in variants:
        try:
            search_path = "/search/autocomplete/" + urllib.parse.quote(search_title, safe="")
            results = sgdb_get(search_path, api_key)
            if isinstance(results, list):
                for item in results:
                    if isinstance(item, dict) and item.get("id") is not None:
                        gathered[str(item.get("id"))] = item
            if gathered:
                try:
                    match = choose_game_match(game_name, list(gathered.values()), aliases=variants)
                    return match, search_title
                except RuntimeError as exc:
                    last_error = exc
        except Exception as exc:
            last_error = exc

    if gathered:
        return choose_game_match(game_name, list(gathered.values()), aliases=variants), (variants[-1] if variants else game_name)
    if last_error:
        raise last_error
    raise RuntimeError(f'No SteamGridDB match was found for "{game_name}".')


def choose_steam_match(query, results, aliases=None):
    """Conservatively choose a Steam Store result from a title-only search."""
    if not isinstance(results, list) or not results:
        return None

    usable = []
    for item in results:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        item_type = str(item.get("type") or "app").lower()
        if item_type not in ("app", "game"):
            continue
        usable.append(item)
    if not usable:
        return None

    alias_values = game_title_variants(query, aliases)
    wanted_aliases = [normalize_game_name(x) for x in alias_values if normalize_game_name(x)]
    exact = [
        item for item in usable
        if normalize_game_name(str(item.get("name", ""))) in wanted_aliases
    ]
    if exact:
        exact.sort(key=lambda item: wanted_aliases.index(normalize_game_name(str(item.get("name", "")))))
        return exact[0]

    ranked = []
    for item in usable:
        candidate = normalize_game_name(str(item.get("name", "")))
        ratio = max(
            (SequenceMatcher(None, wanted, candidate).ratio() for wanted in wanted_aliases),
            default=0.0,
        ) if candidate else 0.0
        # Slightly reward containment, but remain conservative with editions/sequels.
        if candidate and any(wanted and (wanted in candidate or candidate in wanted) for wanted in wanted_aliases):
            ratio += 0.04
        ranked.append((ratio, item))
    ranked.sort(key=lambda pair: pair[0], reverse=True)
    if not ranked or ranked[0][0] < 0.82:
        return None
    return ranked[0][1]


def build_store_asset_url(asset_url_format, filename):
    asset_url_format = str(asset_url_format or "").strip()
    filename = str(filename or "").strip()
    if not asset_url_format or not filename:
        return ""
    return STEAM_ASSET_BASE_URL + asset_url_format.replace("${FILENAME}", filename)


def fetch_steam_store_item(appid):
    payload = {
        "ids": [{"appid": int(appid)}],
        "context": {
            "language": "english",
            "country_code": "US",
            "steam_realm": 1,
        },
        "data_request": {
            "include_basic_info": True,
            "include_assets": True,
        },
    }
    query = urllib.parse.urlencode({
        "input_json": json.dumps(payload, separators=(",", ":")),
    })
    data = get_json_url(
        STEAM_STORE_BROWSE_URL + "?" + query,
        STEAM_API_TIMEOUT,
        "Steam",
    )
    items = ((data or {}).get("response") or {}).get("store_items") or []
    for item in items:
        if isinstance(item, dict) and int(item.get("appid") or 0) == int(appid):
            return item
    return None


def resolve_steam_official(game_name, cached_appid=None, cached_name=None, search_hints=None):
    """Resolve a Steam AppID from the title, then fetch official asset metadata.

    Failure is intentionally non-fatal: SteamGridDB remains the primary source,
    and many GOG/Lutris titles may not have a Steam release at all.
    """
    appid = None
    matched_name = str(cached_name or "")
    if cached_appid:
        try:
            appid = int(cached_appid)
        except Exception:
            appid = None

    if appid is None:
        variants = game_title_variants(game_name, search_hints)
        gathered = {}
        match = None
        for search_title in variants[:4]:
            query = urllib.parse.urlencode({
                "term": search_title,
                "l": "english",
                "cc": "US",
            })
            data = get_json_url(
                STEAM_STORE_SEARCH_URL + "?" + query,
                STEAM_API_TIMEOUT,
                "Steam Store search",
            )
            for item in (data or {}).get("items") or []:
                if isinstance(item, dict) and item.get("id"):
                    gathered[str(item.get("id"))] = item
            match = choose_steam_match(game_name, list(gathered.values()), aliases=variants)
            if match is not None:
                break
        if match is None:
            return None
        appid = int(match["id"])
        matched_name = str(match.get("name") or game_name)

    store_item = None
    try:
        store_item = fetch_steam_store_item(appid)
        if isinstance(store_item, dict) and store_item.get("name"):
            matched_name = str(store_item.get("name"))
    except Exception:
        # Legacy direct CDN URLs below can still rescue header/logo on many apps.
        store_item = None

    return {
        "appid": appid,
        "name": matched_name or game_name,
        "item": store_item or {},
    }


def official_steam_urls(steam_info, spec_key):
    """Return deduplicated Valve-hosted candidates for one Steam artwork slot.

    Prefer the exact filenames returned by StoreBrowse when available.  Logo
    filenames are not currently exposed by StoreBrowse, so use Valve's normal
    unhashed/legacy library logo URLs as official candidates for that slot.
    """
    if not isinstance(steam_info, dict) or not steam_info.get("appid"):
        return []

    appid = int(steam_info["appid"])
    item = steam_info.get("item") or {}
    assets = item.get("assets") if isinstance(item, dict) else {}
    if not isinstance(assets, dict):
        assets = {}
    fmt = assets.get("asset_url_format")

    keys_by_type = {
        "capsule": ("library_capsule_2x", "library_capsule"),
        "wide_capsule": ("header_2x", "header"),
        "hero": ("library_hero_2x", "library_hero"),
        # StoreBrowse's Assets protobuf currently has no library-logo field.
        "logo": (),
        # community_icon is a SHA/hash, not a store_item_assets filename.
        "icon": (),
    }

    urls = []
    for key in keys_by_type.get(spec_key, ()):
        url = build_store_asset_url(fmt, assets.get(key))
        if url:
            urls.append(url)

    shared_unhashed = f"https://shared.steamstatic.com/store_item_assets/steam/apps/{appid}"
    legacy = f"{STEAM_LEGACY_ASSET_BASE_URL}/{appid}"

    if spec_key == "icon":
        icon_hash = str(assets.get("community_icon") or "").strip()
        if icon_hash:
            urls.extend([
                f"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{appid}/{icon_hash}.jpg",
                f"https://steamcdn-a.akamaihd.net/steamcommunity/public/images/apps/{appid}/{icon_hash}.jpg",
            ])
        # Some titles also publish direct icon assets. These are only tried
        # after the hash-based official community icon.
        urls.extend([
            f"{shared_unhashed}/icon.png",
            f"{shared_unhashed}/icon.ico",
            f"{legacy}/icon.png",
            f"{legacy}/icon.ico",
        ])
    elif spec_key == "logo":
        # Valve's traditional Steam library logo endpoints. logo_2x is tried
        # first, then the normal logo. Keep both CDN layouts for compatibility
        # with older and newer titles.
        urls.extend([
            f"{legacy}/logo_2x.png",
            f"{legacy}/logo.png",
            f"{shared_unhashed}/logo_2x.png",
            f"{shared_unhashed}/logo.png",
        ])
    elif spec_key == "capsule":
        urls.extend([
            f"{legacy}/library_600x900_2x.jpg",
            f"{legacy}/library_600x900.jpg",
        ])
    elif spec_key == "wide_capsule":
        urls.extend([
            f"{legacy}/header_2x.jpg",
            f"{legacy}/header.jpg",
        ])
    elif spec_key == "hero":
        urls.extend([
            f"{legacy}/library_hero_2x.jpg",
            f"{legacy}/library_hero.jpg",
        ])

    deduped = []
    seen = set()
    for url in urls:
        url = str(url or "").strip()
        if url and url not in seen:
            seen.add(url)
            deduped.append(url)
    return deduped


def asset_extension(url):
    suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
    if suffix == ".jpeg":
        return ".jpg"
    if suffix in {".png", ".jpg", ".webp", ".ico"}:
        return suffix
    return ".png"


def rank_assets(items, preferred_dimensions=()):
    """Return compatible SGDB assets from best to worst.

    Keeping the whole ranked list lets us fall back to the next-best artwork
    if the CDN download for the first choice times out or otherwise fails.
    """
    if not isinstance(items, list) or not items:
        return []

    dim_rank = {
        value: len(preferred_dimensions) - index
        for index, value in enumerate(preferred_dimensions)
    }

    def rank(item):
        dims = f"{item.get('width', '')}x{item.get('height', '')}"
        return (
            dim_rank.get(dims, 0),
            int(item.get("score") or 0),
            int(item.get("upvotes") or 0),
            int(item.get("width") or 0) * int(item.get("height") or 0),
        )

    return sorted(items, key=rank, reverse=True)


def remove_asset_siblings(grid_dir, stem, keep=None):
    for suffix in (".png", ".jpg", ".jpeg", ".webp", ".ico"):
        candidate = grid_dir / f"{stem}{suffix}"
        if keep is not None and candidate == keep:
            continue
        try:
            if candidate.exists():
                candidate.unlink()
        except OSError:
            pass


def download_file(url, target, timeout=SGDB_IMAGE_TIMEOUT):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": SGDB_USER_AGENT},
    )
    temp = target.with_suffix(target.suffix + ".part")
    try:
        with urllib.request.urlopen(
            request,
            timeout=timeout,
            context=SGDB_SSL_CONTEXT,
        ) as response, open(temp, "wb") as output:
            shutil.copyfileobj(response, output)
        if temp.stat().st_size <= 0:
            raise RuntimeError("downloaded file was empty")
        temp.replace(target)
    finally:
        try:
            if temp.exists():
                temp.unlink()
        except OSError:
            pass


def download_file_with_retry(url, target, timeout, attempts=1):
    last_error = None
    for attempt in range(max(1, int(attempts))):
        try:
            download_file(url, target, timeout=timeout)
            return
        except urllib.error.HTTPError as exc:
            last_error = exc
            # Missing/forbidden artwork will not improve on an immediate retry.
            if 400 <= int(exc.code) < 500:
                break
        except Exception as exc:
            last_error = exc
        if attempt + 1 < attempts:
            time.sleep(0.20)
    if last_error is not None:
        raise last_error
    raise RuntimeError("download failed")


def normalize_steam_icon_png(source, target):
    """Write a real PNG icon regardless of the downloaded source type."""
    source = Path(source)
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if source == target and target.suffix.lower() == ".png":
        return target
    temp = target.with_suffix(target.suffix + ".part.png")
    try:
        if source.suffix.lower() == ".png":
            shutil.copy2(source, temp)
        else:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(source))
            pixbuf.savev(str(temp), "png", [], [])
        temp.replace(target)
        return target
    finally:
        try:
            if temp.exists():
                temp.unlink()
        except OSError:
            pass


def apply_lutris_icon(source, lutris_icon_path):
    if not lutris_icon_path:
        return None
    try:
        source = Path(source)
        icon_target = Path(lutris_icon_path)
        icon_target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix.lower() == ".png":
            shutil.copy2(source, icon_target)
        else:
            # Steam's official community icon is commonly JPEG. Lutris points
            # the shortcut at a .png path, so convert rather than merely giving
            # JPEG bytes a misleading .png extension.
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(source))
            temp = icon_target.with_suffix(icon_target.suffix + ".part.png")
            pixbuf.savev(str(temp), "png", [], [])
            temp.replace(icon_target)
        return None
    except Exception as exc:
        return f"Steam shortcut icon path: {exc}"

def load_artwork_metadata(cache_dir):
    path = cache_dir / "metadata.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_artwork_metadata(cache_dir, metadata):
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / "metadata.json"
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
    temp.replace(path)


def download_and_apply_all_artwork(game_name, grid_id, grid_dir, api_key, lutris_icon_path=None, search_hints=None):
    """Fetch and apply all five artwork types, preferring official Steam art.

    Order per slot:
      1) fresh cached official Steam artwork
      2) fresh official Steam artwork
      3) stale cached official Steam artwork if Valve is temporarily unavailable
      4) fresh cached SteamGridDB artwork
      5) SteamGridDB best result
      6) SteamGridDB next-best result

    All five slots run concurrently. SteamGridDB title discovery is lazy: it is
    only performed if at least one slot actually needs a community fallback.
    """
    cache_dir = SGDB_CACHE_ROOT / str(grid_id)
    cache_dir.mkdir(parents=True, exist_ok=True)
    grid_dir.mkdir(parents=True, exist_ok=True)

    metadata = load_artwork_metadata(cache_dir)
    normalized_name = normalize_game_name(game_name)

    previous_assets = metadata.get("assets")
    if not isinstance(previous_assets, dict):
        previous_assets = {}

    cached_sgdb_id = None
    cached_steam_appid = None
    cached_steam_name = None
    if metadata.get("game_name_normalized") == normalized_name:
        try:
            cached_sgdb_id = int(metadata.get("sgdb_game_id"))
        except Exception:
            cached_sgdb_id = None
        try:
            cached_steam_appid = int(metadata.get("steam_appid"))
        except Exception:
            cached_steam_appid = None
        cached_steam_name = metadata.get("steam_game_name")

    # Steam is the primary source. Resolve it once up front so all five slots
    # can immediately try their official candidates in parallel.
    steam_info = None
    steam_resolve_error = None
    try:
        steam_info = resolve_steam_official(
            game_name,
            cached_steam_appid,
            cached_steam_name,
            search_hints,
        )
    except Exception as exc:
        steam_resolve_error = str(exc)

    steam_appid = None
    steam_game_name = None
    if isinstance(steam_info, dict) and steam_info.get("appid"):
        steam_appid = int(steam_info["appid"])
        steam_game_name = str(steam_info.get("name") or game_name)

    # SteamGridDB is now truly fallback-only. Multiple artwork threads may need
    # it at once, so resolve the title exactly once behind this lock.
    sgdb_lock = threading.Lock()
    sgdb_state = {
        "resolved": False,
        "id": None,
        "name": game_name,
        "query": game_name,
        "error": None,
    }

    def ensure_sgdb_match():
        if sgdb_state["resolved"]:
            return sgdb_state
        with sgdb_lock:
            if sgdb_state["resolved"]:
                return sgdb_state
            if not str(api_key or "").strip():
                sgdb_state["error"] = (
                    "No SteamGridDB API key is saved. Open Settings (gear icon) "
                    "to enable SteamGridDB fallback."
                )
                sgdb_state["resolved"] = True
                return sgdb_state
            try:
                override = get_sgdb_match_override(game_name)
                if override is not None:
                    match = dict(override)
                    sgdb_state["query"] = game_name
                elif cached_sgdb_id is not None:
                    match = {
                        "id": cached_sgdb_id,
                        "name": str(metadata.get("sgdb_game_name") or game_name),
                    }
                else:
                    match, matched_query = search_sgdb_game(game_name, api_key, search_hints)
                    sgdb_state["query"] = str(matched_query or game_name)
                if isinstance(match, dict) and match.get("id"):
                    sgdb_state["id"] = int(match["id"])
                    sgdb_state["name"] = str(match.get("name") or game_name)
                else:
                    sgdb_state["error"] = f'No SteamGridDB match was found for "{game_name}".'
            except Exception as exc:
                sgdb_state["error"] = str(exc)
            sgdb_state["resolved"] = True
        return sgdb_state

    specs = [
        {
            "key": "capsule",
            "label": "Capsule",
            "endpoint": "grids",
            "stem": f"{grid_id}p",
            "dimensions": ("600x900", "660x930", "342x482"),
            "mimes": "image/png,image/jpeg,image/webp",
        },
        {
            "key": "wide_capsule",
            "label": "Wide Capsule",
            "endpoint": "grids",
            "stem": str(grid_id),
            "dimensions": ("920x430", "460x215"),
            "mimes": "image/png,image/jpeg,image/webp",
        },
        {
            "key": "hero",
            "label": "Hero",
            "endpoint": "heroes",
            "stem": f"{grid_id}_hero",
            "dimensions": ("1920x620", "3840x1240", "1600x650"),
            "mimes": "image/png,image/jpeg,image/webp",
        },
        {
            "key": "logo",
            "label": "Logo",
            "endpoint": "logos",
            "stem": f"{grid_id}_logo",
            "dimensions": (),
            "mimes": "image/png,image/webp",
        },
        {
            "key": "icon",
            "label": "Icon",
            "endpoint": "icons",
            "stem": f"{grid_id}_icon",
            "dimensions": (),
            "mimes": "image/png,image/vnd.microsoft.icon",
        },
    ]

    try:
        cache_age = max(0, int(time.time()) - int(metadata.get("updated_at") or 0))
    except Exception:
        cache_age = SGDB_CACHE_FRESH_SECONDS + 1
    cache_is_fresh = cache_age <= SGDB_CACHE_FRESH_SECONDS
    saved_api_key = load_sgdb_api_key()

    def restore_cached(spec, provider_filter=None, allow_stale=False):
        if not allow_stale and not cache_is_fresh:
            return None
        old = previous_assets.get(spec["key"])
        if not isinstance(old, dict) or not old.get("id"):
            return None

        provider = str(old.get("provider") or "sgdb")
        if provider_filter and provider != provider_filter:
            return None
        # SGDB caches are tied to the user's API-backed provider state. Steam
        # official cache is independent of the SGDB key.
        if provider != "steam" and saved_api_key != api_key:
            return None

        old_cache_name = str(old.get("cache_file") or "")
        old_steam_name = str(old.get("steam_file") or "")
        old_cache = cache_dir / old_cache_name if old_cache_name else None
        old_target = grid_dir / old_steam_name if old_steam_name else None
        source = None
        if old_cache is not None and old_cache.is_file():
            source = old_cache
        elif old_target is not None and old_target.is_file():
            source = old_target
        if source is None or old_target is None:
            return None

        try:
            if source != old_target:
                shutil.copy2(source, old_target)
            icon_error = None
            if spec["key"] == "icon" and lutris_icon_path:
                icon_error = apply_lutris_icon(source, lutris_icon_path)
            if old_cache is not None and not old_cache.exists():
                shutil.copy2(old_target, old_cache)
            return {
                "key": spec["key"],
                "label": spec["label"],
                "api_ok": None,
                "selected": dict(old),
                "downloaded": False,
                "provider": provider,
                "fallback_rank": int(old.get("rank") or 1),
                "fresh_cache": not allow_stale,
                "icon_error": icon_error,
            }
        except Exception:
            return None

    def apply_source(spec, selected, source, cache_file, target, provider, downloaded, rank=1):
        try:
            # Steam's grid/_icon file alone is not enough for non-Steam
            # shortcuts. Normalize every icon to PNG so the shortcut can point
            # to a format Linux Steam renders reliably.
            if spec["key"] == "icon":
                png_cache = cache_dir / "icon.png"
                png_target = grid_dir / f'{spec["stem"]}.png'
                normalize_steam_icon_png(source, png_cache)
                source = png_cache
                cache_file = png_cache
                target = png_target

            remove_asset_siblings(cache_dir, spec["key"], keep=cache_file)
            remove_asset_siblings(grid_dir, spec["stem"], keep=target)
            if source != target:
                shutil.copy2(source, target)

            icon_error = None
            if spec["key"] == "icon" and lutris_icon_path:
                icon_error = apply_lutris_icon(source, lutris_icon_path)

            if source == target and not cache_file.exists():
                shutil.copy2(target, cache_file)

            selected_record = dict(selected)
            selected_record.update({
                "cache_file": cache_file.name,
                "steam_file": target.name,
                "provider": provider,
                "rank": int(rank or 1),
            })
            return {
                "key": spec["key"],
                "label": spec["label"],
                "api_ok": True if provider == "sgdb" else None,
                "selected": selected_record,
                "downloaded": bool(downloaded),
                "provider": provider,
                "fallback_rank": int(rank or 1),
                "icon_error": icon_error,
            }
        except Exception as exc:
            return {
                "key": spec["key"],
                "label": spec["label"],
                "api_ok": True if provider == "sgdb" else None,
                "failed": str(exc),
            }

    def process_spec(spec):
        # 1) Fresh official Steam cache always wins immediately.
        cached_official = restore_cached(spec, provider_filter="steam")
        if cached_official is not None:
            return cached_official

        errors = []
        api_ok = None

        # 2) Official Steam first. If the previous record is already official
        # and the currently-resolved URL is unchanged, a fresh cached copy is
        # reused rather than downloaded again.
        steam_urls = official_steam_urls(steam_info, spec["key"])
        for steam_rank, image_url in enumerate(steam_urls[:4], start=1):
            ext = asset_extension(image_url)
            candidate_cache = cache_dir / f'{spec["key"]}{ext}'
            candidate_target = grid_dir / f'{spec["stem"]}{ext}'

            candidate_source = None
            old = previous_assets.get(spec["key"])
            if (
                cache_is_fresh
                and isinstance(old, dict)
                and str(old.get("provider") or "") == "steam"
                and str(old.get("url") or "") == image_url
            ):
                old_file = old.get("cache_file")
                if old_file:
                    old_cache = cache_dir / str(old_file)
                    if old_cache.is_file():
                        candidate_source = old_cache
                if candidate_source is None and candidate_target.is_file():
                    candidate_source = candidate_target

            downloaded = False
            if candidate_source is None:
                try:
                    download_file_with_retry(
                        image_url,
                        candidate_cache,
                        STEAM_IMAGE_TIMEOUT,
                        attempts=1,
                    )
                    candidate_source = candidate_cache
                    downloaded = True
                except Exception as exc:
                    # 404 is normal for an asset a particular title does not
                    # publish. Move to the next official candidate immediately.
                    errors.append(f"Steam official #{steam_rank}: {exc}")
                    continue

            filename = Path(urllib.parse.urlparse(image_url).path).name
            return apply_source(
                spec,
                {
                    "id": f"steam:{steam_appid}:{filename}",
                    "url": image_url,
                    "score": 0,
                    "steam_appid": steam_appid,
                },
                candidate_source,
                candidate_cache,
                candidate_target,
                "steam",
                downloaded,
                steam_rank,
            )

        # If Valve is temporarily unreachable, prefer an older known-official
        # copy over replacing it with community art.
        stale_official = restore_cached(
            spec,
            provider_filter="steam",
            allow_stale=True,
        )
        if stale_official is not None:
            return stale_official

        # 3) Only now consider a fresh cached SGDB file.
        cached_sgdb = restore_cached(spec, provider_filter="sgdb")
        if cached_sgdb is not None:
            return cached_sgdb

        # 4/5) SteamGridDB is fallback-only. Resolve the title lazily, then try
        # the best result followed by one alternative. This avoids unnecessary
        # SGDB API work when Steam already supplied all five official assets.
        sgdb = ensure_sgdb_match()
        sgdb_game_id = sgdb.get("id")
        if sgdb_game_id is not None:
            params = {
                "types": "static",
                "nsfw": "false",
                "humor": "false",
                "mimes": spec["mimes"],
            }
            if spec["dimensions"]:
                params["dimensions"] = ",".join(spec["dimensions"])

            try:
                items = sgdb_get(
                    f'/{spec["endpoint"]}/game/{sgdb_game_id}',
                    api_key,
                    params,
                )
                api_ok = True
                candidates = rank_assets(items, spec["dimensions"])
            except Exception as exc:
                candidates = []
                errors.append(f"SteamGridDB: {exc}")

            for candidate_rank, candidate in enumerate(candidates[:2], start=1):
                asset_id = str(candidate.get("id", ""))
                image_url = str(candidate.get("url", ""))
                if not asset_id or not image_url:
                    continue
                ext = asset_extension(image_url)
                candidate_cache = cache_dir / f'{spec["key"]}{ext}'
                candidate_target = grid_dir / f'{spec["stem"]}{ext}'

                old = previous_assets.get(spec["key"])
                candidate_source = None
                if (
                    cache_is_fresh
                    and isinstance(old, dict)
                    and str(old.get("provider") or "sgdb") == "sgdb"
                    and str(old.get("id", "")) == asset_id
                ):
                    old_file = old.get("cache_file")
                    if old_file:
                        old_cache = cache_dir / str(old_file)
                        if old_cache.is_file():
                            candidate_source = old_cache
                    if candidate_source is None and candidate_target.is_file():
                        candidate_source = candidate_target

                downloaded = False
                if candidate_source is None:
                    try:
                        download_file_with_retry(
                            image_url,
                            candidate_cache,
                            SGDB_IMAGE_TIMEOUT,
                            attempts=2 if candidate_rank == 1 else 1,
                        )
                        candidate_source = candidate_cache
                        downloaded = True
                    except Exception as exc:
                        errors.append(f"SGDB choice #{candidate_rank}: {exc}")
                        continue

                return apply_source(
                    spec,
                    {
                        "id": asset_id,
                        "url": image_url,
                        "score": int(candidate.get("score") or 0),
                    },
                    candidate_source,
                    candidate_cache,
                    candidate_target,
                    "sgdb",
                    downloaded,
                    candidate_rank,
                )
        elif sgdb.get("error"):
            errors.append(f"SteamGridDB: {sgdb['error']}")

        if not errors and not steam_urls:
            return {
                "key": spec["key"],
                "label": spec["label"],
                "api_ok": api_ok,
                "missing": True,
            }

        detail = "; ".join(errors[-5:]) or "no compatible artwork found"
        return {
            "key": spec["key"],
            "label": spec["label"],
            "api_ok": api_ok,
            "failed": detail,
        }

    outcomes = {}
    with ThreadPoolExecutor(max_workers=len(specs)) as executor:
        future_map = {executor.submit(process_spec, spec): spec for spec in specs}
        for future in as_completed(future_map):
            spec = future_map[future]
            try:
                outcomes[spec["key"]] = future.result()
            except Exception as exc:
                outcomes[spec["key"]] = {
                    "key": spec["key"],
                    "label": spec["label"],
                    "api_ok": False,
                    "failed": str(exc),
                }

    if any(x.get("api_ok") is True for x in outcomes.values()):
        save_sgdb_api_key(api_key)

    new_assets = dict(previous_assets)
    downloaded = 0
    reused = 0
    applied = 0
    missing = []
    failed = []
    fallbacks = []
    provider_counts = {"sgdb": 0, "steam": 0}

    for spec in specs:
        outcome = outcomes.get(spec["key"], {})
        if outcome.get("missing"):
            missing.append(spec["label"])
            continue
        if outcome.get("failed"):
            failed.append(f'{spec["label"]}: {outcome["failed"]}')
            continue
        selected = outcome.get("selected")
        if not isinstance(selected, dict):
            failed.append(f'{spec["label"]}: no usable result')
            continue

        applied += 1
        if outcome.get("downloaded"):
            downloaded += 1
        else:
            reused += 1

        provider = str(outcome.get("provider") or selected.get("provider") or "sgdb")
        if provider in provider_counts:
            provider_counts[provider] += 1

        rank = int(outcome.get("fallback_rank") or 1)
        if provider == "sgdb":
            if rank > 1:
                fallbacks.append(f'{spec["label"]} fell back to SteamGridDB choice #{rank}')
            else:
                fallbacks.append(f'{spec["label"]} fell back to SteamGridDB')
        if outcome.get("icon_error"):
            failed.append(str(outcome["icon_error"]))

        new_assets[spec["key"]] = selected

    sgdb_game_id = sgdb_state.get("id") if sgdb_state.get("resolved") else cached_sgdb_id
    matched_name = sgdb_state.get("name") if sgdb_state.get("resolved") else str(metadata.get("sgdb_game_name") or game_name)

    # Remember any non-empty key after a successful artwork run, even when
    # official Steam supplied every slot and SteamGridDB did not need to be
    # contacted. Automatic post-install artwork can then use it later.
    if applied > 0 and str(api_key or "").strip():
        save_sgdb_api_key(str(api_key).strip())

    metadata = {
        "version": 6,
        "game_name": game_name,
        "game_name_normalized": normalized_name,
        "sgdb_game_id": sgdb_game_id,
        "sgdb_game_name": matched_name,
        "sgdb_search_query": sgdb_state.get("query") if sgdb_state.get("resolved") else metadata.get("sgdb_search_query"),
        "steam_appid": steam_appid,
        "steam_game_name": steam_game_name,
        "steam_grid_id": str(grid_id),
        "assets": new_assets,
        "updated_at": int(time.time()),
    }
    save_artwork_metadata(cache_dir, metadata)

    if applied == 0:
        detail = "; ".join(failed) if failed else "No compatible static artwork was found."
        if steam_resolve_error:
            detail += f" Steam lookup: {steam_resolve_error}"
        raise RuntimeError(detail)

    return {
        "matched_name": matched_name,
        "sgdb_search_query": sgdb_state.get("query") if sgdb_state.get("resolved") else metadata.get("sgdb_search_query"),
        "steam_appid": steam_appid,
        "steam_game_name": steam_game_name,
        "applied": applied,
        "downloaded": downloaded,
        "reused": reused,
        "missing": missing,
        "failed": failed,
        "fallbacks": fallbacks,
        "provider_counts": provider_counts,
        "icon_path": (
            str(grid_dir / str(new_assets.get("icon", {}).get("steam_file")))
            if isinstance(new_assets.get("icon"), dict) and new_assets.get("icon", {}).get("steam_file")
            else ""
        ),
    }


def database_path():
    candidates = [
        Path.home() / ".var/app/net.lutris.Lutris/data/lutris/pga.db",
        Path.home() / ".local/share/lutris/pga.db",
    ]
    for path in candidates:
        if path.exists():
            return path
    return None


def list_lutris_games():
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
        super().__init__(title="One-Click Tools")

        # IMPORTANT:
        # Do NOT use Gtk.HeaderBar / client-side decorations here.
        # SteamOS KDE/X11 can produce ugly drag ghosting with GTK3 CSD.
        # Let KWin draw the normal native title bar instead.
        self.set_default_size(540, 455)
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

        # Header area. Keep Settings out of the main workflow: one small gear
        # in the top-right opens persistent application settings.
        header_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        header_row.set_margin_bottom(4)
        body.pack_start(header_row, False, False, 0)

        title = Gtk.Label()
        title.set_markup(
            "<span size='x-large' weight='bold'>Manage your games</span>"
        )
        title.set_xalign(0)
        title.set_hexpand(True)
        header_row.pack_start(title, True, True, 0)

        self.settings_btn = Gtk.Button()
        self.settings_btn.set_tooltip_text("Settings")
        self.settings_btn.set_size_request(40, 38)
        settings_icon = Gtk.Image.new_from_icon_name(
            "preferences-system-symbolic", Gtk.IconSize.BUTTON
        )
        self.settings_btn.add(settings_icon)
        self.settings_btn.get_style_context().add_class("icon-button")
        self.settings_btn.connect("clicked", self.on_settings)
        header_row.pack_end(self.settings_btn, False, False, 0)

        subtitle = Gtk.Label(
            label="Install through Steam or Lutris, manage Steam shortcuts, fetch artwork, or remove games."
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

        # One selector, now with multi-select support. No extra main action
        # buttons are needed: check one or more games here and the existing
        # artwork button applies to every checked game.
        self.selector_button = Gtk.MenuButton()
        self.selector_button.set_hexpand(True)
        self.selector_button.set_size_request(-1, 42)
        self.selector_button.get_style_context().add_class("game-selector")

        selector_content = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.selector_summary = Gtk.Label(label="Select one or more games")
        self.selector_summary.set_xalign(0)
        self.selector_summary.set_hexpand(True)
        selector_arrow = Gtk.Image.new_from_icon_name(
            "pan-down-symbolic", Gtk.IconSize.BUTTON
        )
        selector_content.pack_start(self.selector_summary, True, True, 0)
        selector_content.pack_end(selector_arrow, False, False, 0)
        self.selector_button.add(selector_content)
        selector_row.pack_start(self.selector_button, True, True, 0)

        self.selector_popover = Gtk.Popover.new(self.selector_button)
        self.selector_popover.set_position(Gtk.PositionType.BOTTOM)
        popover_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        popover_box.set_border_width(10)

        popover_header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        popover_title = Gtk.Label(label="Select games")
        popover_title.set_xalign(0)
        popover_title.set_hexpand(True)
        popover_title.get_style_context().add_class("section-label")
        popover_header.pack_start(popover_title, True, True, 0)

        select_all = Gtk.Button(label="All")
        select_all.set_tooltip_text("Select all installed games")
        select_all.get_style_context().add_class("mini-button")
        select_all.connect("clicked", self.on_select_all_games)
        popover_header.pack_start(select_all, False, False, 0)

        clear_all = Gtk.Button(label="Clear")
        clear_all.set_tooltip_text("Clear game selection")
        clear_all.get_style_context().add_class("mini-button")
        clear_all.connect("clicked", self.on_clear_game_selection)
        popover_header.pack_start(clear_all, False, False, 0)
        popover_box.pack_start(popover_header, False, False, 0)

        game_scroll = Gtk.ScrolledWindow()
        game_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        game_scroll.set_size_request(420, 230)
        game_scroll.set_shadow_type(Gtk.ShadowType.IN)
        self.game_list = Gtk.ListBox()
        self.game_list.set_selection_mode(Gtk.SelectionMode.NONE)
        game_scroll.add(self.game_list)
        popover_box.pack_start(game_scroll, True, True, 0)

        # Explicit confirmation makes multi-selection feel finished instead of
        # leaving the popover open after the user has checked the games.
        popover_footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        popover_footer.set_halign(Gtk.Align.CENTER)
        popover_footer.set_margin_top(2)
        selector_ok = Gtk.Button(label="OK")
        selector_ok.set_size_request(96, 34)
        selector_ok.get_style_context().add_class("primary")
        selector_ok.connect("clicked", lambda *_: self.selector_popover.popdown())
        popover_footer.pack_start(selector_ok, False, False, 0)
        popover_box.pack_start(popover_footer, False, False, 0)

        self.selector_popover.add(popover_box)
        self.selector_button.set_popover(self.selector_popover)
        # Gtk.Popover is attached outside the normal window widget tree.
        # Mark its child hierarchy visible explicitly; otherwise GTK can show
        # only the tiny popover arrow/shell with no game list inside it.
        popover_box.show_all()

        self.refresh_btn = Gtk.Button()
        refresh = self.refresh_btn
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

        self.play_btn = Gtk.Button()
        self.play_btn.set_hexpand(True)
        self.play_btn.set_size_request(-1, 46)
        self.play_btn.get_style_context().add_class("play")
        self.play_btn.set_tooltip_text("Launch the selected game using its Steam or Lutris backend")
        self.play_btn.connect("clicked", self.on_play)

        play_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        play_box.set_halign(Gtk.Align.CENTER)
        play_icon = Gtk.Image.new_from_icon_name(
            "media-playback-start-symbolic", Gtk.IconSize.BUTTON
        )
        play_text = Gtk.Label(label="Play Game")
        play_text.get_style_context().add_class("button-label")
        play_box.pack_start(play_icon, False, False, 0)
        play_box.pack_start(play_text, False, False, 0)
        self.play_btn.add(play_box)
        actions_panel.pack_start(self.play_btn, False, False, 0)

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

        self.artwork_btn = Gtk.Button()
        self.artwork_btn.set_hexpand(True)
        self.artwork_btn.set_size_request(-1, 46)
        self.artwork_btn.get_style_context().add_class("secondary")
        self.artwork_btn.connect("clicked", self.on_artwork)

        artwork_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        artwork_box.set_halign(Gtk.Align.CENTER)
        artwork_icon = Gtk.Image.new_from_icon_name(
            "folder-download-symbolic", Gtk.IconSize.BUTTON
        )
        artwork_text = Gtk.Label(label="Download + Apply All Artworks")
        artwork_text.get_style_context().add_class("button-label")
        artwork_box.pack_start(artwork_icon, False, False, 0)
        artwork_box.pack_start(artwork_text, False, False, 0)
        self.artwork_btn.add(artwork_box)

        # Keep the main artwork action uncluttered, but provide one compact
        # folder button beside it for users who want to inspect/remove the
        # custom artwork files Steam is actually using.
        artwork_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        artwork_row.pack_start(self.artwork_btn, True, True, 0)

        self.artwork_folder_btn = Gtk.Button()
        self.artwork_folder_btn.set_size_request(48, 46)
        self.artwork_folder_btn.get_style_context().add_class("icon-button")
        self.artwork_folder_btn.set_tooltip_text("Open Steam artwork folder")
        self.artwork_folder_btn.connect("clicked", self.on_open_artwork_folder)
        folder_icon = Gtk.Image.new_from_icon_name(
            "folder-open-symbolic", Gtk.IconSize.BUTTON
        )
        self.artwork_folder_btn.add(folder_icon)
        artwork_row.pack_start(self.artwork_folder_btn, False, False, 0)
        actions_panel.pack_start(artwork_row, False, False, 0)

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
        # Gtk.Label can otherwise request its entire long status sentence as
        # one natural-width line, which makes a non-resizable GTK window grow
        # across the screen. Cap the natural width so the text wraps instead.
        self.status.set_max_width_chars(66)
        self.status.set_margin_top(16)
        self.status.get_style_context().add_class("status")
        body.pack_start(self.status, False, False, 0)

        self.games = {}
        self.selected_ids = set()
        self.game_checks = {}
        self.artwork_busy = False
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

        .api-hint {
            color: #7b8085;
            font-size: 9pt;
        }

        entry {
            min-height: 38px;
            padding-left: 10px;
            padding-right: 10px;
            background-color: #ffffff;
            color: #202124;
            border: 1px solid #cfd3d8;
            border-radius: 7px;
        }

        entry:focus {
            border-color: #2f80ed;
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

        button.game-selector {
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

        button.game-selector:hover {
            border-color: #aeb4ba;
            background-color: #ffffff;
        }

        button.mini-button {
            min-height: 26px;
            padding: 2px 9px;
            background-image: none;
            background-color: #ffffff;
            color: #2f6fbd;
            border: 1px solid #cfd3d8;
            border-radius: 5px;
            box-shadow: none;
        }

        button.mini-button:hover {
            background-color: #f3f8fd;
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

        button.play {
            min-height: 44px;
            background-image: none;
            background-color: #2e7d32;
            color: #ffffff;
            border: 1px solid #2e7d32;
            border-radius: 7px;
            box-shadow: none;
            text-shadow: none;
            -gtk-icon-shadow: none;
        }

        button.play label,
        button.play image {
            color: #ffffff;
            text-shadow: none;
            -gtk-icon-shadow: none;
            box-shadow: none;
        }

        button.play:hover {
            background-color: #256b2a;
            border-color: #256b2a;
        }

        button.play:active {
            background-color: #1f5d24;
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

    def selected_games(self):
        return sorted(
            (self.games[sid] for sid in self.selected_ids if sid in self.games),
            key=lambda item: item["name"].casefold(),
        )

    def selected_game(self):
        items = self.selected_games()
        return items[0] if len(items) == 1 else None

    def set_status(self, text, success=False):
        self.status.set_text(text)
        ctx = self.status.get_style_context()
        if success:
            ctx.add_class("success")
        else:
            ctx.remove_class("success")

    def _update_selector_summary(self):
        count = len(self.selected_ids)
        if count == 0:
            text = "Select one or more games"
        elif count == 1:
            sid = next(iter(self.selected_ids))
            text = self.games.get(sid, {}).get("name", "1 game selected")
        else:
            text = f"{count} games selected"
        self.selector_summary.set_text(text)

    def _update_action_sensitivity(self):
        count = len(self.selected_ids)
        available = bool(self.games) and not self.artwork_busy
        self.selector_button.set_sensitive(available)
        self.refresh_btn.set_sensitive(not self.artwork_busy)
        # Repair stays single-game, while artwork and complete removal support
        # every checked game (including the selector's All option).
        self.repair_btn.set_sensitive(available and count >= 1)
        # Play is intentionally single-game only. Steam-native entries that
        # have been detached from Steam cannot be launched until repaired.
        playable = False
        if available and count == 1:
            item = self.selected_game()
            playable = bool(item) and not (
                item.get("backend") == "steam" and item.get("status") == "detached"
            )
        self.play_btn.set_sensitive(playable)
        self.remove_btn.set_sensitive(available and count >= 1)
        self.artwork_btn.set_sensitive(available and count >= 1)
        self.artwork_folder_btn.set_sensitive(not self.artwork_busy)

    def _rebuild_game_checks(self):
        for child in self.game_list.get_children():
            self.game_list.remove(child)
        self.game_checks.clear()

        for sid, item in sorted(
            self.games.items(), key=lambda pair: pair[1]["name"].casefold()
        ):
            row = Gtk.ListBoxRow()
            row.set_activatable(False)
            row.set_selectable(False)
            check = Gtk.CheckButton(label=item["name"])
            check.set_active(sid in self.selected_ids)
            check.connect("toggled", self.on_game_toggled, sid)
            row.add(check)
            self.game_list.add(row)
            self.game_checks[sid] = check

        self.game_list.show_all()

    def on_game_toggled(self, check, sid):
        if check.get_active():
            self.selected_ids.add(sid)
        else:
            self.selected_ids.discard(sid)
        self._update_selector_summary()
        self._update_action_sensitivity()

    def on_select_all_games(self, _button):
        for check in self.game_checks.values():
            if not check.get_active():
                check.set_active(True)

    def on_clear_game_selection(self, _button):
        for check in self.game_checks.values():
            if check.get_active():
                check.set_active(False)

    def refresh_games(self, preferred_id=None):
        previous = set(self.selected_ids)
        if preferred_id:
            previous = {str(preferred_id)}
        self.games.clear()

        # Steam-native games installed by One-Click.
        native = load_steam_native_registry()
        for key, entry in native.items():
            if entry.get("status") not in {"installed", "detached", "pending_steam"}:
                continue
            try:
                appid = int(entry.get("appid", key))
            except Exception:
                continue
            sid = f"steam:{appid}"
            self.games[sid] = {
                "id": str(appid),
                "name": str(entry.get("name") or f"Steam game {appid}"),
                "directory": str(entry.get("compatdata") or ""),
                "runner": "steam-proton",
                "backend": "steam",
                "appid": appid,
                "final_exe": str(entry.get("final_exe") or ""),
                "start_dir": str(entry.get("start_dir") or ""),
                "status": str(entry.get("status") or "installed"),
            }

        # Existing Lutris games remain fully supported as the alternate backend.
        try:
            rows = list_lutris_games()
        except Exception as exc:
            rows = []
            if not self.games:
                self.set_status(f"Could not read Lutris library: {exc}")

        for game_id, name, directory, runner in rows:
            sid = f"lutris:{game_id}"
            self.games[sid] = {
                "id": str(game_id),
                "name": name,
                "directory": directory or "",
                "runner": runner or "",
                "backend": "lutris",
            }

        if not self.games:
            self.selected_ids.clear()
            self._rebuild_game_checks()
            self._update_selector_summary()
            self._update_action_sensitivity()
            self.set_status("No One-Click Steam or Lutris games were found.")
            return

        kept = {sid for sid in previous if sid in self.games}
        if kept:
            self.selected_ids = kept
        else:
            first_sid = min(
                self.games,
                key=lambda sid: self.games[sid]["name"].casefold(),
            )
            self.selected_ids = {first_sid}

        self._rebuild_game_checks()
        self._update_selector_summary()
        self._update_action_sensitivity()
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
                "Could not start the installer",
                str(exc),
                Gtk.MessageType.ERROR,
            )
            return

        self.set_status(
            f"Opening installer for {exe.name} using the saved backend…",
            success=True,
        )


    def on_play(self, _button):
        item = self.selected_game()
        if not item:
            return

        name = str(item.get("name") or "Selected game")
        backend = str(item.get("backend") or "")

        try:
            if backend == "steam":
                if str(item.get("status") or "") == "detached":
                    message(
                        self,
                        "Steam shortcut is not installed",
                        "Repair the Steam shortcut first, then try Play Game again.",
                        Gtk.MessageType.INFO,
                    )
                    return

                if not host_steam_is_running():
                    message(
                        self,
                        "Steam is not running",
                        "Open Steam first, then press Play Game again. One-Click will not start Steam automatically in Desktop Mode because current SteamOS builds can trigger KDE's Screen Sharing permission dialog when Steam is launched externally.",
                        Gtk.MessageType.INFO,
                    )
                    return

                appid = int(item.get("appid") or item.get("id"))
                big_picture_id = ((appid & 0xFFFFFFFF) << 32) | 0x02000000
                uri = f"steam://rungameid/{big_picture_id}"
                # Hand the URI to the already-running Steam client through the
                # desktop handler. Do NOT exec/start Steam here: current
                # SteamOS/KDE builds can show a ScreenCast permission dialog
                # whenever Steam itself is launched from Desktop Mode.
                result = _host_run(
                    f"xdg-open {shlex.quote(uri)} >/dev/null 2>&1",
                    timeout=8,
                )
                if result.returncode != 0:
                    raise RuntimeError("The running Steam client did not accept the game launch request.")
                self.set_status(f"Launching {name} through the running Steam client…", success=True)
            elif backend == "lutris":
                game_id = str(item.get("id") or "").strip()
                if not game_id:
                    raise RuntimeError("The Lutris game ID is missing.")
                wrapper = str(Path.home() / ".local/bin/oneclick-lutris-steam-launch")
                subprocess.Popen(
                    [
                        "flatpak-spawn",
                        "--host",
                        wrapper,
                        game_id,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                self.set_status(f"Launching {name} through Lutris…", success=True)
            else:
                raise RuntimeError("Unknown game backend.")
        except Exception as exc:
            message(
                self,
                "Game could not be launched",
                str(exc),
                Gtk.MessageType.ERROR,
            )


    def on_repair(self, _button):
        items = self.selected_games()
        if not items:
            return

        count = len(items)
        names = [item["name"] for item in items]
        preview = "\n".join(
            f"• {item['name']}  ({'Steam' if item.get('backend') == 'steam' else 'Lutris'})"
            for item in items[:10]
        )
        if count > 10:
            preview += f"\n• …and {count - 10} more"

        if not confirm(
            self,
            "Repair Steam shortcut?" if count == 1 else f"Repair {count} Steam shortcuts?",
            (
                f"{preview}\n\n"
                "Steam-native games are restored as direct Windows EXE shortcuts and keep your current Steam Proton choice. "
                "If no Proton mapping exists, Proton Experimental is assigned.\n\n"
                "Lutris games keep the V5.x Lutris launcher format and have accidental Steam-side Proton overrides cleared.\n\n"
                "Steam may close briefly and reopen automatically."
            ),
        ):
            return

        self.set_artwork_busy(True)
        self.set_status(
            f"Repairing Steam shortcut for {names[0]}…" if count == 1
            else f"Repairing {count} Steam shortcuts…"
        )
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)

        steam_was_running = host_steam_is_running()
        if steam_was_running and not stop_host_steam():
            self.set_artwork_busy(False)
            message(
                self,
                "Steam could not be closed",
                "Close Steam manually and press Repair Steam Shortcut again.",
                Gtk.MessageType.ERROR,
            )
            return

        repaired = []
        failed = []
        try:
            config_path = steam_shortcut.get_config_path()
            if not config_path:
                raise RuntimeError("Steam's active user/config folder could not be found.")

            for index, item in enumerate(items, start=1):
                if count > 1:
                    self.set_status(f"Repairing shortcuts: {index}/{count} — {item['name']}…")
                while Gtk.events_pending():
                    Gtk.main_iteration_do(False)
                try:
                    if item.get("backend") == "steam":
                        appid = int(item["appid"])
                        final_exe = Path(item.get("final_exe") or "")
                        if not final_exe.is_file():
                            raise RuntimeError(
                                "The installed game EXE is missing. If the game was moved, reinstall it or repair the registry entry."
                            )
                        start_dir = Path(item.get("start_dir") or final_exe.parent)
                        steam_native_upsert_shortcut(
                            appid,
                            item["name"],
                            final_exe,
                            start_dir,
                        )
                        ensure_steam_compat_mapping(config_path, appid)
                        update_steam_native_registry(
                            appid,
                            status="installed",
                            final_exe=str(final_exe),
                            start_dir=str(start_dir),
                        )
                    else:
                        game = Game(item["id"])
                        if not game.id or not game.is_installed:
                            raise RuntimeError("Lutris could not load this installed game.")
                        appid = steam_shortcut.generate_appid(game)
                        remove_steam_compat_mapping(config_path, appid)
                        remove_steam_launcher_compatdata(config_path, appid)
                        steam_shortcut.remove_shortcut(game)
                        steam_shortcut.create_shortcut(game, "")
                    repaired.append(item["name"])
                except Exception as exc:
                    failed.append({"name": item["name"], "error": str(exc)})
        except Exception as exc:
            failed.append({"name": "Steam", "error": str(exc)})
        finally:
            # Leave Steam closed. Current SteamOS/Steam-Jupiter builds can trigger
            # KDE's screen-sharing portal whenever Desktop Steam is relaunched.
            # The user can Return to Gaming Mode or start Steam manually afterwards.
            self.set_artwork_busy(False)

        if repaired:
            text = (
                f"Steam shortcut repaired for {repaired[0]}." if len(repaired) == 1
                else f"Repaired {len(repaired)}/{count} selected Steam shortcuts."
            )
            if any(item.get("backend") == "steam" for item in items):
                text += " Steam-native shortcuts can use Proton normally from Properties → Compatibility."
            if any(item.get("backend") == "lutris" for item in items):
                text += " Lutris shortcuts should keep Steam Compatibility OFF."
            if failed:
                text += "\nCould not repair: " + " | ".join(
                    f"{x['name']}: {x['error']}" for x in failed[:4]
                )
            self.set_status(text, success=True)
        else:
            message(
                self,
                "Steam shortcut repair failed",
                "\n".join(f"• {x['name']}: {x['error']}" for x in failed[:8]),
                Gtk.MessageType.ERROR,
            )
            self.set_status("Steam shortcut repair failed.")

    def set_artwork_busy(self, busy):
        self.artwork_busy = bool(busy)
        self._update_action_sensitivity()

    def on_settings(self, _button):
        dlg = Gtk.Dialog(
            title="Settings",
            transient_for=self,
            modal=True,
            destroy_with_parent=True,
        )
        dlg.set_default_size(480, 500)
        dlg.set_resizable(False)
        dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
        save_btn = dlg.add_button("Save", Gtk.ResponseType.OK)
        save_btn.get_style_context().add_class("suggested-action")
        dlg.set_default_response(Gtk.ResponseType.OK)

        area = dlg.get_content_area()
        settings_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        settings_box.set_border_width(22)
        area.pack_start(settings_box, True, True, 0)

        installer_heading = Gtk.Label(label="INSTALLER BACKEND")
        installer_heading.set_xalign(0)
        installer_heading.set_margin_bottom(7)
        installer_heading.get_style_context().add_class("section-label")
        settings_box.pack_start(installer_heading, False, False, 0)

        installer_desc = Gtk.Label(
            label=(
                "Steam is recommended and is the default. It installs Windows games directly into a Steam Proton prefix, "
                "so you can later choose Proton Experimental, GE-Proton or another compatibility tool from the game's Steam Properties. "
                "Lutris keeps the previous V5.x workflow available for games that need it."
            )
        )
        installer_desc.set_xalign(0)
        installer_desc.set_line_wrap(True)
        installer_desc.set_max_width_chars(62)
        installer_desc.set_margin_bottom(10)
        installer_desc.get_style_context().add_class("subtitle")
        settings_box.pack_start(installer_desc, False, False, 0)

        backend_combo = Gtk.ComboBoxText()
        backend_combo.append("steam", "Steam / Proton (default)")
        backend_combo.append("lutris", "Lutris / Wine")
        backend_combo.set_active_id(load_installer_backend())
        settings_box.pack_start(backend_combo, False, False, 0)

        proton_hint = Gtk.Label(
            label="New Steam installs initially use Proton Experimental. After installation you can change Proton normally in Gaming Mode."
        )
        proton_hint.set_xalign(0)
        proton_hint.set_line_wrap(True)
        proton_hint.set_max_width_chars(62)
        proton_hint.set_margin_top(7)
        proton_hint.set_margin_bottom(20)
        proton_hint.get_style_context().add_class("api-hint")
        settings_box.pack_start(proton_hint, False, False, 0)

        heading = Gtk.Label(label="STEAMGRIDDB")
        heading.set_xalign(0)
        heading.set_margin_bottom(7)
        heading.get_style_context().add_class("section-label")
        settings_box.pack_start(heading, False, False, 0)

        description = Gtk.Label(
            label=(
                "Used only when official Steam artwork is unavailable. The saved key is also reused by automatic background artwork after installs."
            )
        )
        description.set_xalign(0)
        description.set_line_wrap(True)
        description.set_max_width_chars(62)
        description.set_margin_bottom(10)
        description.get_style_context().add_class("subtitle")
        settings_box.pack_start(description, False, False, 0)

        key_label = Gtk.Label(label="STEAMGRIDDB API KEY")
        key_label.set_xalign(0)
        key_label.set_margin_bottom(6)
        key_label.get_style_context().add_class("section-label")
        settings_box.pack_start(key_label, False, False, 0)

        api_entry = Gtk.Entry()
        api_entry.set_visibility(True)
        api_entry.set_placeholder_text("Paste your personal SteamGridDB API key")
        api_entry.set_text(load_sgdb_api_key())
        api_entry.set_activates_default(True)
        settings_box.pack_start(api_entry, False, False, 0)

        saved_hint = Gtk.Label(label="Saved persistently on this SteamOS user account.")
        saved_hint.set_xalign(0)
        saved_hint.set_margin_top(7)
        saved_hint.get_style_context().add_class("api-hint")
        settings_box.pack_start(saved_hint, False, False, 0)

        storage_heading = Gtk.Label(label="STORAGE")
        storage_heading.set_xalign(0)
        storage_heading.set_margin_top(20)
        storage_heading.set_margin_bottom(7)
        storage_heading.get_style_context().add_class("section-label")
        settings_box.pack_start(storage_heading, False, False, 0)

        storage_desc = Gtk.Label(
            label="Failed Steam-native installers can leave temporary Proton prefixes. One-Click cleans new failures automatically. This also finds older One-Click prefixes from V6.0-V6.3 using One-Click logs/markers, while preserving active Steam shortcuts."
        )
        storage_desc.set_xalign(0)
        storage_desc.set_line_wrap(True)
        storage_desc.set_max_width_chars(62)
        storage_desc.set_margin_bottom(8)
        storage_desc.get_style_context().add_class("subtitle")
        settings_box.pack_start(storage_desc, False, False, 0)

        open_game_folder_btn = Gtk.Button(label="Open Selected Game Folder")
        open_game_folder_btn.set_tooltip_text("Open the actual folder for the currently selected game")
        settings_box.pack_start(open_game_folder_btn, False, False, 0)

        def open_selected_game_folder(_button):
            item = self.selected_game()
            if not item:
                message(
                    self,
                    "Select one game first",
                    "Close Settings, select exactly one game in One-Click Tools, then open Settings again and press Open Selected Game Folder.",
                    Gtk.MessageType.INFO,
                )
                return

            try:
                if item.get("backend") == "steam":
                    final_exe = str(item.get("final_exe") or "").strip()
                    if final_exe and Path(final_exe).is_file():
                        folder = Path(final_exe).parent
                    else:
                        compatdata = str(item.get("directory") or "").strip()
                        if not compatdata:
                            raise RuntimeError("One-Click could not determine this Steam game's install folder.")
                        folder = Path(compatdata)
                else:
                    directory = str(item.get("directory") or "").strip()
                    if not directory:
                        raise RuntimeError("Lutris did not provide an install folder for this game.")
                    folder = Path(os.path.expanduser(directory))

                if not folder.exists():
                    raise RuntimeError(f"The game folder no longer exists:\n\n{folder}")

                try:
                    opened = Gio.AppInfo.launch_default_for_uri(folder.resolve().as_uri(), None)
                    if not opened:
                        raise RuntimeError("No default file manager accepted the folder URI.")
                except Exception:
                    subprocess.Popen(
                        ["xdg-open", str(folder)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                self.set_status(f"Opened game folder for {item['name']}.")
            except Exception as exc:
                message(
                    self,
                    "Game folder could not be opened",
                    str(exc),
                    Gtk.MessageType.ERROR,
                )

        open_game_folder_btn.connect("clicked", open_selected_game_folder)

        cleanup_btn = Gtk.Button(label="Clean Failed Steam Installs")
        cleanup_btn.set_margin_top(8)
        settings_box.pack_start(cleanup_btn, False, False, 0)

        def clean_failed(_button):
            helper = Path.home() / ".local/bin/lutris-exe-helper"
            try:
                result = subprocess.run(
                    ["flatpak-spawn", "--host", str(helper), "cleanup-failed"],
                    text=True, capture_output=True, timeout=120,
                )
                if result.returncode != 0:
                    raise RuntimeError((result.stderr or result.stdout or "Cleanup failed").strip())
                data = json.loads((result.stdout or "{}").strip().splitlines()[-1])
                count = int(data.get("removed_count") or 0)
                freed = int(data.get("bytes") or 0)
                units = ["B", "KB", "MB", "GB", "TB"]
                value = float(freed)
                unit = units[0]
                for unit in units:
                    if value < 1024 or unit == units[-1]:
                        break
                    value /= 1024
                size_text = f"{int(value)} {unit}" if unit == "B" else f"{value:.1f} {unit}"
                if count:
                    message(self, "Failed installs cleaned", f"Removed {count} failed Steam prefix(es) and freed about {size_text}.", Gtk.MessageType.INFO)
                else:
                    message(self, "Nothing to clean", "No orphaned One-Click Steam-native prefixes could be safely removed. Active Steam shortcuts and successful installs are always preserved.", Gtk.MessageType.INFO)
            except Exception as exc:
                message(self, "Cleanup failed", str(exc), Gtk.MessageType.ERROR)

        cleanup_btn.connect("clicked", clean_failed)

        # Keep version information at the very bottom of Settings so it does
        # not interrupt the Storage controls above.
        about_heading = Gtk.Label(label="ABOUT")
        about_heading.set_xalign(0)
        about_heading.set_margin_top(20)
        about_heading.set_margin_bottom(7)
        about_heading.get_style_context().add_class("section-label")
        settings_box.pack_start(about_heading, False, False, 0)

        version_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        version_label = Gtk.Label(label="One-Click EXE")
        version_label.set_xalign(0)
        version_value = Gtk.Label(label=f"Version {TOOL_VERSION}")
        version_value.set_xalign(1)
        version_value.get_style_context().add_class("subtitle")
        version_row.pack_start(version_label, True, True, 0)
        version_row.pack_end(version_value, False, False, 0)
        settings_box.pack_start(version_row, False, False, 0)

        settings_box.show_all()
        response = dlg.run()
        if response == Gtk.ResponseType.OK:
            api_key = api_entry.get_text().strip()
            backend = backend_combo.get_active_id() or DEFAULT_INSTALLER_BACKEND
            try:
                save_sgdb_api_key(api_key)
                settings = load_oneclick_settings()
                settings["installer_backend"] = backend
                save_oneclick_settings(settings)
                if load_sgdb_api_key() != api_key or load_installer_backend() != backend:
                    raise RuntimeError("The saved settings could not be read back.")
                backend_label = "Steam / Proton" if backend == "steam" else "Lutris / Wine"
                self.set_status(
                    f"Settings saved. Installer backend: {backend_label}."
                    + (" SteamGridDB fallback is ready." if api_key else " SteamGridDB fallback is disabled until an API key is added."),
                    success=True,
                )
            except Exception as exc:
                dlg.destroy()
                message(self, "Settings could not be saved", str(exc), Gtk.MessageType.ERROR)
                return
        dlg.destroy()

    def on_open_artwork_folder(self, _button):
        """Open Steam's active custom artwork folder in the file manager.

        This is deliberately the applied Steam grid folder, not our download
        cache, so deleting files here removes the custom artwork Steam shows.
        """
        try:
            config_path = steam_shortcut.get_config_path()
            if not config_path:
                raise RuntimeError(
                    "Steam's active user/config folder could not be found. "
                    "Start Steam once in Desktop Mode and try again."
                )

            grid_dir = Path(config_path) / "grid"
            grid_dir.mkdir(parents=True, exist_ok=True)

            # Gio normally routes the file:// URI through the desktop/Flatpak
            # portal and opens the user's normal file manager (Dolphin on
            # SteamOS). Keep xdg-open as a fallback for older portal setups.
            try:
                opened = Gio.AppInfo.launch_default_for_uri(grid_dir.as_uri(), None)
                if not opened:
                    raise RuntimeError("No default file manager accepted the folder URI.")
            except Exception:
                subprocess.Popen(
                    ["xdg-open", str(grid_dir)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            self.set_status(
                "Opened Steam artwork folder. Deleting files there removes "
                "the custom artwork Steam is currently using."
            )
        except Exception as exc:
            message(
                self,
                "Steam artwork folder could not be opened",
                str(exc),
                Gtk.MessageType.ERROR,
            )

    def on_artwork(self, _button):
        items = self.selected_games()
        if not items:
            return

        # The API key lives in Settings and is persisted immediately when the
        # user presses Save. Official Steam artwork can work without a key;
        # SteamGridDB simply becomes unavailable as a fallback if none is saved.
        api_key = load_sgdb_api_key()

        try:
            config_path = steam_shortcut.get_config_path()
            if not config_path:
                raise RuntimeError(
                    "Steam's active user/config folder could not be found. Start Steam once in Desktop Mode and try again."
                )
            grid_dir = Path(config_path) / "grid"
        except Exception as exc:
            message(
                self,
                "Artwork could not be prepared",
                str(exc),
                Gtk.MessageType.ERROR,
            )
            return

        jobs = []
        preparation_failures = []
        for item in items:
            try:
                if item.get("backend") == "steam":
                    appid = int(item["appid"])
                    if not steam_native_shortcut_exists(appid):
                        raise RuntimeError(
                            "No Steam shortcut was found. Use Repair Steam Shortcut first."
                        )
                    hints = []
                    final_exe = str(item.get("final_exe") or "")
                    if final_exe:
                        fp = Path(final_exe)
                        hints.extend([fp.parent.name, fp.stem])
                        if fp.parent.parent != fp.parent:
                            hints.append(fp.parent.parent.name)
                    jobs.append({
                        "name": item["name"],
                        "backend": "steam",
                        "appid": appid,
                        "grid_id": str(appid),
                        "grid_dir": grid_dir,
                        "lutris_icon_path": None,
                        "search_hints": hints,
                    })
                else:
                    game = Game(item["id"])
                    if not game.id or not game.is_installed:
                        raise RuntimeError("Lutris could not load this installed game.")
                    if not steam_shortcut.shortcut_exists(game):
                        raise RuntimeError(
                            "No Steam shortcut was found. Use Repair Steam Shortcut first."
                        )
                    hints = []
                    directory = str(item.get("directory") or "")
                    if directory:
                        dp = Path(directory)
                        hints.extend([dp.name, dp.parent.name])
                    if getattr(game, "slug", None):
                        hints.append(str(game.slug).replace("-", " "))
                    jobs.append({
                        "name": item["name"],
                        "backend": "lutris",
                        "grid_id": steam_shortcut.generate_appid(game),
                        "grid_dir": grid_dir,
                        "lutris_icon_path": Path(resources.get_icon_path(game.slug)),
                        "search_hints": hints,
                    })
            except Exception as exc:
                preparation_failures.append({"name": item["name"], "error": str(exc)})

        if not jobs:
            details = "\n".join(
                f"• {entry['name']}: {entry['error']}"
                for entry in preparation_failures
            )
            message(
                self,
                "Artwork could not be prepared",
                details or "No selected game could be prepared.",
                Gtk.MessageType.ERROR,
            )
            return

        self.set_artwork_busy(True)
        selected_count = len(items)
        if selected_count == 1:
            self.set_status(f"Finding artwork for {items[0]['name']}…")
        else:
            self.set_status(
                f"Downloading artwork for {selected_count} selected games… "
                "Artwork types are fetched in parallel."
            )

        worker = threading.Thread(
            target=self._artwork_batch_worker,
            args=(jobs, api_key, preparation_failures),
            daemon=True,
        )
        worker.start()

    def _artwork_batch_worker(self, jobs, api_key, preparation_failures):
        results = list(preparation_failures)

        def run_job(job):
            result = download_and_apply_all_artwork(
                job["name"],
                job["grid_id"],
                job["grid_dir"],
                api_key,
                job["lutris_icon_path"],
                job.get("search_hints"),
            )
            if job.get("backend") == "steam" and result.get("icon_path"):
                queue_steam_native_icon_refresh(job["appid"], result["icon_path"])
            return {"name": job["name"], "result": result, "job": job}

        # Up to two games at once. Each game itself fetches its five artwork
        # types concurrently. Two is a deliberate ceiling so batch mode feels
        # fast without creating an excessive burst of SGDB/CDN requests.
        max_games = min(2, len(jobs))
        completed = 0
        with ThreadPoolExecutor(max_workers=max_games) as executor:
            future_map = {executor.submit(run_job, job): job for job in jobs}
            for future in as_completed(future_map):
                job = future_map[future]
                try:
                    results.append(future.result())
                except Exception as exc:
                    failed_entry = {"name": job["name"], "error": str(exc), "job": job}
                    # Only prepare the one-time chooser after a complete
                    # artwork failure. Partial 1-4/5 results never prompt.
                    if api_key and get_sgdb_match_override(job["name"]) is None:
                        try:
                            candidates = sgdb_candidate_options(
                                job["name"], api_key, job.get("search_hints"), 5
                            )
                            if candidates:
                                failed_entry["sgdb_candidates"] = candidates
                        except Exception:
                            pass
                    results.append(failed_entry)
                completed += 1
                GLib.idle_add(
                    self._artwork_batch_progress,
                    completed,
                    len(jobs),
                    job["name"],
                )

        GLib.idle_add(self._artwork_batch_finished, results)

    def _artwork_batch_progress(self, completed, total, game_name):
        if total > 1:
            self.set_status(
                f"Artwork progress: {completed}/{total} finished. Latest: {game_name}."
            )
        return False

    def _choose_sgdb_match_dialog(self, game_name, candidates):
        candidates = [x for x in (candidates or []) if isinstance(x, dict) and x.get("id") is not None][:5]
        if not candidates:
            return None

        dialog = Gtk.Dialog(
            title="Which game is this?",
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
        )
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        dialog.add_button("Use selected game", Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.set_resizable(False)

        area = dialog.get_content_area()
        area.set_spacing(12)
        area.set_margin_top(16)
        area.set_margin_bottom(16)
        area.set_margin_start(18)
        area.set_margin_end(18)

        label = Gtk.Label()
        label.set_xalign(0)
        label.set_line_wrap(True)
        label.set_max_width_chars(56)
        label.set_text(
            f'One-Click could not find any usable artwork for "{game_name}" automatically.\n\n'
            "Choose the correct SteamGridDB entry once. This choice will be remembered and you should not be asked again for this game."
        )
        area.pack_start(label, False, False, 0)

        combo = Gtk.ComboBoxText()
        for item in candidates:
            types = item.get("types") or []
            if not isinstance(types, list):
                types = [types]
            type_text = ", ".join(str(x) for x in types[:3] if x)
            flags = []
            if item.get("verified"):
                flags.append("verified")
            if type_text:
                flags.append(type_text)
            suffix = f"  —  {' / '.join(flags)}" if flags else ""
            combo.append(str(item["id"]), f'{item.get("name") or game_name}{suffix}')
        combo.set_active(0)
        area.pack_start(combo, False, False, 0)

        dialog.show_all()
        response = dialog.run()
        selected_id = combo.get_active_id() if response == Gtk.ResponseType.OK else None
        dialog.destroy()
        if not selected_id:
            return None
        for item in candidates:
            if str(item.get("id")) == str(selected_id):
                return item
        return None

    def _artwork_batch_finished(self, entries):
        self.set_artwork_busy(False)

        successes = [entry for entry in entries if isinstance(entry.get("result"), dict)]
        errors = [entry for entry in entries if entry.get("error")]

        # Rare one-time ambiguity fallback. Never show this for partial artwork:
        # it is only reached when a game got absolutely 0/5. Background
        # post-install artwork also never opens UI; the chooser appears only
        # after the user manually presses Download + Apply All Artworks.
        for failed_entry in errors:
            candidates = failed_entry.get("sgdb_candidates") or []
            if candidates and get_sgdb_match_override(failed_entry.get("name", "")) is None:
                choice = self._choose_sgdb_match_dialog(failed_entry.get("name", "Game"), candidates)
                if choice is not None:
                    save_sgdb_match_override(failed_entry.get("name", "Game"), choice)
                    self.set_status(
                        f"Remembered SteamGridDB match: {choice.get('name')}. Retrying artwork…"
                    )
                    GLib.idle_add(self.on_artwork, None)
                    return False
                break

        # Preserve the more detailed single-game result users already know.
        if len(entries) == 1 and successes:
            entry = successes[0]
            game_name = entry["name"]
            result = entry["result"]
            parts = [
                f"Applied {result['applied']}/5 artworks for {game_name}.",
                f"Downloaded {result['downloaded']} new file(s); reused {result['reused']} cached file(s).",
            ]
            if result.get("matched_name") and result["matched_name"] != game_name:
                query_used = str(result.get("sgdb_search_query") or game_name)
                if normalize_game_name(query_used) != normalize_game_name(game_name):
                    parts.append(f"SteamGridDB match: {result['matched_name']} (searched as {query_used}).")
                else:
                    parts.append(f"SteamGridDB match: {result['matched_name']}.")
            if result.get("steam_appid"):
                steam_label = result.get("steam_game_name") or game_name
                parts.append(f"Steam match: {steam_label} (AppID {result['steam_appid']}).")
            counts = result.get("provider_counts") or {}
            steam_count = int(counts.get("steam") or 0)
            sgdb_count = int(counts.get("sgdb") or 0)
            if steam_count or sgdb_count:
                source_bits = []
                if steam_count:
                    source_bits.append(f"Official Steam {steam_count}/5")
                if sgdb_count:
                    source_bits.append(f"SteamGridDB {sgdb_count}/5")
                parts.append("Sources: " + ", ".join(source_bits) + ".")
            if result.get("fallbacks"):
                parts.append("Fallback: " + ", ".join(result["fallbacks"]) + ".")
            if result.get("missing"):
                parts.append("Not available: " + ", ".join(result["missing"]) + ".")
            if result.get("failed"):
                parts.append("Some types failed: " + " | ".join(result["failed"]) + ".")
            parts.append("Return to Gaming Mode / reload Steam to see any artwork Steam has not hot-reloaded yet.")
            self.set_status("\n".join(parts), success=True)
            return False

        if len(entries) == 1 and errors:
            self.set_status("Artwork download failed.")
            message(
                self,
                "Artwork could not be applied",
                errors[0]["error"],
                Gtk.MessageType.ERROR,
            )
            return False

        complete = 0
        partial = []
        downloaded = 0
        reused = 0
        for entry in successes:
            result = entry["result"]
            downloaded += int(result.get("downloaded") or 0)
            reused += int(result.get("reused") or 0)
            if int(result.get("applied") or 0) == 5:
                complete += 1
            else:
                partial.append(f"{entry['name']} {result.get('applied', 0)}/5")

        parts = [
            f"Artwork finished for {len(entries)} games: {complete} complete, {len(partial)} partial, {len(errors)} failed.",
            f"Downloaded {downloaded} new file(s); reused {reused} cached file(s).",
        ]
        if partial:
            parts.append("Partial: " + ", ".join(partial) + ".")
        if errors:
            parts.append(
                "Failed: " + " | ".join(
                    f"{entry['name']}: {entry['error']}" for entry in errors[:4]
                ) + (" …" if len(errors) > 4 else ".")
            )
        parts.append("Return to Gaming Mode / reload Steam when the batch is finished.")
        self.set_status("\n".join(parts), success=bool(successes))
        return False

    def on_remove(self, _button):
        items = self.selected_games()
        if not items:
            return

        prepared = []
        validation_errors = []
        for item in items:
            try:
                path_text = item.get("directory") or ""
                if item.get("backend") == "steam" and not path_text:
                    config_path = steam_shortcut.get_config_path()
                    steam_root = steam_root_from_user_config(config_path) if config_path else None
                    if steam_root:
                        path_text = str(steam_root / "steamapps" / "compatdata" / str(int(item["appid"])))
                game_path = safe_game_directory(path_text)
                prepared.append({"item": item, "path": game_path})
            except Exception as exc:
                validation_errors.append(f"• {item['name']}: {exc}")

        if validation_errors:
            message(
                self,
                "Selected games cannot be removed safely",
                "Nothing was removed.\n\n" + "\n".join(validation_errors[:8])
                + ("\n…" if len(validation_errors) > 8 else ""),
                Gtk.MessageType.ERROR,
            )
            return

        count = len(prepared)
        preview = "\n".join(
            f"• {entry['item']['name']}  ({'Steam' if entry['item'].get('backend') == 'steam' else 'Lutris'})"
            for entry in prepared[:10]
        )
        if count > 10:
            preview += f"\n• …and {count - 10} more"

        if not confirm(
            self,
            f"Remove {prepared[0]['item']['name']}?" if count == 1 else f"Remove {count} selected games?",
            (
                f"{preview}\n\n"
                "This removes the Steam shortcut, custom artwork/cache and compatibility mapping. "
                "For Lutris games it also removes the Lutris library/config entry.\n\n"
                "The actual game files/prefixes are not deleted until the second confirmation."
            ),
        ):
            return

        self.remove_btn.set_sensitive(False)
        self.repair_btn.set_sensitive(False)
        self.artwork_btn.set_sensitive(False)
        self.selector_button.set_sensitive(False)
        self.refresh_btn.set_sensitive(False)
        self.set_status(
            f"Removing {prepared[0]['item']['name']}…" if count == 1
            else f"Removing {count} selected games…"
        )

        steam_was_running = host_steam_is_running()
        if steam_was_running and not stop_host_steam():
            self._update_action_sensitivity()
            message(
                self,
                "Steam could not be closed",
                "Nothing was removed. Close Steam manually and try again.",
                Gtk.MessageType.ERROR,
            )
            return

        removed = []
        failed = []
        cleanup_count = 0
        try:
            config_path = steam_shortcut.get_config_path()
            if not config_path:
                raise RuntimeError("Steam's active user/config folder could not be found.")

            for index, entry in enumerate(prepared, start=1):
                item = entry["item"]
                name = item["name"]
                if count > 1:
                    self.set_status(f"Removing games: {index}/{count} — {name}…")
                while Gtk.events_pending():
                    Gtk.main_iteration_do(False)

                try:
                    if item.get("backend") == "steam":
                        appid = int(item["appid"])
                        steam_native_remove_shortcut(appid)
                        remove_steam_compat_mapping(config_path, appid)
                        cleanup_count += remove_game_artwork_files(config_path, appid)
                        # Keep a detached registry entry until files are either
                        # permanently deleted or the user repairs/re-adds it.
                        update_steam_native_registry(appid, status="detached")
                    else:
                        game = Game(item["id"])
                        appid = steam_shortcut.generate_appid(game)
                        steam_shortcut.remove_shortcut(game)
                        remove_steam_compat_mapping(config_path, appid)
                        # This compatdata belongs only to Steam wrapping the
                        # Lutris Linux launcher, not the real Lutris prefix.
                        remove_steam_launcher_compatdata(config_path, appid)
                        cleanup_count += remove_game_artwork_files(config_path, appid)
                        if game.is_installed:
                            game.uninstall(delete_files=False)
                        if game.id is not None:
                            game.delete()
                    removed.append(entry)
                except Exception as exc:
                    failed.append({"name": name, "error": str(exc)})
        except Exception as exc:
            failed.append({"name": "Steam cleanup", "error": str(exc)})
        finally:
            # Do not auto-relaunch Desktop Steam after removal; this avoids the
            # current KDE/Steam PipeWire screen-share prompt.
            pass

        if not removed:
            self.refresh_games()
            message(
                self,
                "The selected games could not be removed",
                "No game files were permanently deleted.\n\n"
                + "\n".join(f"• {x['name']}: {x['error']}" for x in failed[:8]),
                Gtk.MessageType.ERROR,
            )
            return

        existing = [entry for entry in removed if entry["path"].exists()]
        deleted = []
        kept_files = list(existing)
        delete_failures = []

        if existing:
            folder_preview = "\n".join(
                f"• {entry['item']['name']}: {entry['path']}"
                for entry in existing[:8]
            )
            if len(existing) > 8:
                folder_preview += f"\n• …and {len(existing) - 8} more"
            if confirm(
                self,
                "Permanently delete game files?" if len(existing) == 1 else f"Permanently delete files for {len(existing)} games?",
                folder_preview + "\n\nThis permanently deletes the listed folders/prefixes and cannot be undone.",
                destructive=True,
            ):
                kept_files = []
                for entry in sorted(existing, key=lambda x: len(x["path"].parts), reverse=True):
                    try:
                        shutil.rmtree(entry["path"])
                        deleted.append(entry)
                        if entry["item"].get("backend") == "steam":
                            delete_steam_native_registry(entry["item"]["appid"])
                    except Exception as exc:
                        delete_failures.append({
                            "name": entry["item"]["name"],
                            "path": entry["path"],
                            "error": str(exc),
                        })
                        kept_files.append(entry)

        # If a Steam-native compatdata folder was already missing, its detached
        # registry entry can be removed now too.
        for entry in removed:
            if entry["item"].get("backend") == "steam" and not entry["path"].exists():
                delete_steam_native_registry(entry["item"]["appid"])

        self.refresh_games()

        parts = []
        if count == 1 and removed:
            name = removed[0]["item"]["name"]
            if deleted:
                parts.append(f"{name} was completely removed.")
            elif kept_files:
                parts.append(f"{name} was removed from Steam/library, but its game files were kept.")
            else:
                parts.append(f"{name} was removed.")
        else:
            parts.append(f"Removed {len(removed)}/{count} selected games from their libraries/Steam shortcuts.")
            if deleted:
                parts.append(f"Deleted game folders/prefixes for {len(deleted)} game(s).")
            if kept_files:
                parts.append(f"Kept game files for {len(kept_files)} game(s).")
        if cleanup_count:
            parts.append("Steam artwork/cache and compatibility leftovers were cleaned up.")
        if failed:
            parts.append(
                "Could not remove: "
                + " | ".join(f"{x['name']}: {x['error']}" for x in failed[:4])
                + (" …" if len(failed) > 4 else "")
            )
        if delete_failures:
            parts.append(
                "Could not delete folders: "
                + " | ".join(f"{x['name']}: {x['error']}" for x in delete_failures[:4])
            )
        self.set_status("\n".join(parts), success=bool(removed))



def run_background_artwork(game_id, supplied_name=""):
    """Silently fetch/apply artwork for a freshly installed game.

    This is intentionally UI-free. It uses the exact same official-Steam-first
    engine as the manual button and writes a short result to stdout/stderr so
    the host watcher log remains useful for diagnostics.
    """
    try:
        game = Game(str(game_id))
        if not game.id or not game.is_installed:
            raise RuntimeError("Lutris could not load the newly installed game.")
        if not steam_shortcut.shortcut_exists(game):
            raise RuntimeError("The Steam shortcut is not available yet.")

        config_path = steam_shortcut.get_config_path()
        if not config_path:
            raise RuntimeError("Steam's active user/config folder could not be found.")

        game_name = str(supplied_name or game.name or game.slug or "Installed game")
        api_key = load_sgdb_api_key()
        hints = []
        try:
            if getattr(game, "directory", None):
                dp = Path(str(game.directory))
                hints.extend([dp.name, dp.parent.name])
        except Exception:
            pass
        if getattr(game, "slug", None):
            hints.append(str(game.slug).replace("-", " "))
        result = download_and_apply_all_artwork(
            game_name,
            steam_shortcut.generate_appid(game),
            Path(config_path) / "grid",
            api_key,
            Path(resources.get_icon_path(game.slug)),
            hints,
        )
        print(json.dumps({
            "game": game_name,
            "applied": result.get("applied"),
            "downloaded": result.get("downloaded"),
            "reused": result.get("reused"),
            "providers": result.get("provider_counts"),
        }, sort_keys=True))
        return 0
    except Exception as exc:
        print(f"Background artwork failed for {supplied_name or game_id}: {exc}", file=sys.stderr)
        return 1



def run_background_steam_artwork(appid, supplied_name=""):
    try:
        config_path = steam_shortcut.get_config_path()
        if not config_path:
            raise RuntimeError("Steam's active user/config folder could not be found.")
        appid = int(appid)
        registry = load_steam_native_registry()
        entry = registry.get(str(appid)) or {}
        game_name = str(supplied_name or entry.get("name") or f"Steam game {appid}")
        api_key = load_sgdb_api_key()
        hints = []
        final_exe = str(entry.get("final_exe") or "")
        if final_exe:
            fp = Path(final_exe)
            hints.extend([fp.parent.name, fp.stem])
            if fp.parent.parent != fp.parent:
                hints.append(fp.parent.parent.name)
        result = download_and_apply_all_artwork(
            game_name,
            str(appid),
            Path(config_path) / "grid",
            api_key,
            None,
            hints,
        )
        if result.get("icon_path"):
            queue_steam_native_icon_refresh(appid, result["icon_path"])
        update_steam_native_registry(appid, artwork_pending=False)
        print(json.dumps({
            "game": game_name,
            "appid": appid,
            "applied": result.get("applied"),
            "downloaded": result.get("downloaded"),
            "reused": result.get("reused"),
            "providers": result.get("provider_counts"),
        }, sort_keys=True))
        return 0
    except Exception as exc:
        try:
            update_steam_native_registry(int(appid), artwork_pending=False)
        except Exception:
            pass
        print(f"Background Steam artwork failed for {supplied_name or appid}: {exc}", file=sys.stderr)
        return 1


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--background-artwork":
        if len(sys.argv) < 3:
            sys.exit(2)
        supplied_name = sys.argv[3] if len(sys.argv) >= 4 else ""
        sys.exit(run_background_artwork(sys.argv[2], supplied_name))

    if len(sys.argv) >= 2 and sys.argv[1] == "--background-steam-artwork":
        if len(sys.argv) < 3:
            sys.exit(2)
        supplied_name = sys.argv[3] if len(sys.argv) >= 4 else ""
        sys.exit(run_background_steam_artwork(sys.argv[2], supplied_name))

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
Name=One-Click Game Installer
Comment=Install Windows EXE games through Steam Proton or Lutris
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
Name=Run as game update / patch
Icon=net.lutris.Lutris
Exec=$HELPER existing %f
__SERVICEMENU_D58F__

chmod +x "$SERVICE_DESKTOP"

cat > "$FOLDER_SERVICE_DESKTOP" <<__FOLDER_SERVICE_V67__
[Desktop Entry]
Type=Service
MimeType=inode/directory;
Actions=oneclickAddExistingFolder;
X-KDE-Priority=TopLevel

[Desktop Action oneclickAddExistingFolder]
Name=Find Game EXE + Add to Steam
Icon=folder-symbolic
Exec=$HELPER add-folder %f
__FOLDER_SERVICE_V67__
chmod +x "$FOLDER_SERVICE_DESKTOP"

cat > "$FOLDER_INSTALL_SERVICE_DESKTOP" <<__FOLDER_INSTALL_SERVICE_V6711__
[Desktop Entry]
Type=Service
MimeType=inode/directory;
Actions=oneclickFindExeInstall;
X-KDE-Priority=TopLevel

[Desktop Action oneclickFindExeInstall]
Name=Find Game EXE + Install
Icon=system-run-symbolic
Exec=$HELPER find-install-folder %f
__FOLDER_INSTALL_SERVICE_V6711__
chmod +x "$FOLDER_INSTALL_SERVICE_DESKTOP"

# Remove legacy standalone launchers from older versions.
rm -f "$REMOVE_APP_DESKTOP" "$STEAM_REPAIR_DESKTOP" "$REMOVE_HELPER"

cat > "$TOOLS_DESKTOP" <<__TOOLS_DESKTOP_7B31__
[Desktop Entry]
Type=Application
Version=1.0
Name=One-Click Tools
GenericName=Steam and Lutris Game Tools
Comment=Install games through Steam or Lutris, manage shortcuts, artwork and removal
Icon=net.lutris.Lutris
Exec=$HELPER tools $TOOLS_GUI
TryExec=$HELPER
Terminal=false
NoDisplay=false
Categories=Game;Utility;
Keywords=Steam;Proton;Lutris;SteamGridDB;Artwork;Shortcut;Repair;Remove;Uninstall;Games;
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
echo " One-Click EXE V6.7.17 installed successfully!"
echo "============================================================"
echo
echo "NEW GAME:"
echo "  Double-click any .exe -> One-Click Game Installer"
echo "  Default backend: Steam / Proton (changeable in One-Click Tools -> Settings)."
echo "  Steam backend launches the installer directly with Proton Experimental"
echo "  inside the exact Steam compatdata prefix reserved for the final game shortcut."
echo "  Steam stays open during installation and One-Click never restarts it. Final shortcut integration waits for your next manual Steam close/restart or Return to Gaming Mode."
echo "  Failed new Steam installs are cleaned automatically, detailed Proton logs are kept, and Lutris + System Wine 11.0 is offered as a fallback."
echo "  Artwork is downloaded/applied automatically in the background."
echo "  After install, change Proton normally from Steam Properties -> Compatibility."
echo
echo "SMART DOUBLE-CLICK:"
echo "  Double-click any .exe -> choose Install, Update existing game, or Add existing game to Steam (no install)."
echo "  Update/patch filenames are detected and preselected automatically."
echo
echo "EXISTING GAME FOLDER:"
echo "  Right-click a folder -> Find Game EXE + Add to Steam"
echo "  Right-click a folder -> Find Game EXE + Install"
echo "  The first creates a shortcut directly; the second scans for EXEs and then opens the normal One-Click Install / Update / Add Existing dialog."
echo
echo "UPDATE / PATCH:"
echo "  Right-click update.exe -> Run as game update / patch"
echo "  Steam backend runs the updater directly in the SAME Steam Proton prefix without restarting Steam; Lutris backend uses the Lutris prefix."
echo
echo "ONE-CLICK TOOLS:"
echo "  Application Launcher -> One-Click Tools"
echo "  One clean native KDE-framed window for:"
echo "    - Install Game"
echo "    - Settings: Steam (default) or Lutris backend + SteamGridDB API key + safe failed-install cleanup"
echo "    - Repair Steam Shortcut (Steam-native + Lutris)"
echo "    - Download + Apply All Artworks (Official Steam first, SteamGridDB fallback, multi-select; also automatic after install)"
echo "    - Small folder button opens Steam custom artwork folder"
echo "    - Complete Game Removal (Steam-native + Lutris; single, multiple, or All)"
echo "  The window stays open after removal so you can continue managing games."
echo
echo "Close all Dolphin windows and open Dolphin again once."
echo
echo "To remove this integration later:"
echo "  bash \"$0\" --uninstall"
echo
