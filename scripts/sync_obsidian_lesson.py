#!/usr/bin/env python3
"""
Syncs live lesson content into an Obsidian vault and opens the note via URI protocol.
Cross-platform support for Windows, macOS, and Linux.
"""

import argparse
import json
import os
import platform
import re
import secrets
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path


def get_default_vault_path() -> Path:
    env_vault = os.environ.get("OBSIDIAN_VAULT_PATH")
    if env_vault:
        return Path(env_vault).expanduser().resolve()

    if platform.system() == "Windows":
        # Check standard Documents folder
        user_profile = os.environ.get("USERPROFILE", str(Path.home()))
        return (Path(user_profile) / "Documents" / "ObsidianVault").resolve()
    else:
        return (Path.home() / "Documents" / "ObsidianVault").resolve()


def get_obsidian_config_path() -> Path:
    system = platform.system()
    if system == "Windows":
        app_data = os.environ.get("APPDATA")
        if app_data:
            return Path(app_data) / "obsidian" / "obsidian.json"
        return Path.home() / "AppData" / "Roaming" / "obsidian" / "obsidian.json"
    elif system == "Darwin":
        return Path.home() / "Library" / "Application Support" / "obsidian" / "obsidian.json"
    else:
        config_home = os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
        return Path(config_home) / "obsidian" / "obsidian.json"


def sanitize_filename(name: str) -> str:
    if name.endswith(".md"):
        name = name[:-3]
    # Replace invalid filesystem characters
    name = re.sub(r'[\\/*?:"<>|]', "_", name).strip()
    return name or "Untitled_Lesson"


def register_vault_if_needed(vault_path: Path):
    config_file = get_obsidian_config_path()
    config_file.parent.mkdir(parents=True, exist_ok=True)

    config_data = {}
    if config_file.exists():
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                config_data = json.load(f)
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to parse {config_file}: {e}\n")

    vaults = config_data.get("vaults", {})
    resolved_target = str(vault_path.resolve())

    # Check if target already present
    for vault_info in vaults.values():
        if isinstance(vault_info, dict) and vault_info.get("path"):
            existing = str(Path(vault_info["path"]).resolve())
            if existing.lower() == resolved_target.lower():
                return

    # Add new vault entry
    vault_id = secrets.token_hex(8)
    vaults[vault_id] = {
        "path": resolved_target,
        "ts": int(time.time() * 1000),
        "open": True,
    }
    config_data["vaults"] = vaults

    try:
        with open(config_file, "w", encoding="utf-8") as f:
            json.dump(config_data, f, indent=2)
        print(f"Registered vault '{resolved_target}' in {config_file}")
    except Exception as e:
        sys.stderr.write(f"Warning: Failed to write {config_file}: {e}\n")


def open_obsidian_uri(vault_name: str, file_path_rel: str):
    escaped_vault = urllib.parse.quote(vault_name)
    escaped_file = urllib.parse.quote(file_path_rel)
    uri = f"obsidian://open?vault={escaped_vault}&file={escaped_file}"

    system = platform.system()
    try:
        if system == "Windows":
            # Attempt direct execution of Obsidian executable if found
            local_app = os.environ.get("LOCALAPPDATA", "")
            candidates = [
                Path(local_app) / "Programs" / "Obsidian" / "Obsidian.exe",
                Path(local_app) / "Obsidian" / "Obsidian.exe",
                Path("C:/Program Files/Obsidian/Obsidian.exe"),
            ]
            exe_found = next((p for p in candidates if p.exists()), None)
            if exe_found:
                subprocess.Popen([str(exe_found), uri])
            else:
                os.startfile(uri)
        elif system == "Darwin":
            subprocess.Popen(["open", uri])
        else:
            subprocess.Popen(["xdg-open", uri])
        print(f"Opened Obsidian URI: {uri}")
    except Exception as e:
        sys.stderr.write(f"Warning: Could not open Obsidian URI {uri}: {e}\n")


def main():
    parser = argparse.ArgumentParser(description="Sync Socrathinks lesson note to Obsidian.")
    parser.add_argument("-t", "--topic", required=True, help="Lesson topic name")
    parser.add_argument("-c", "--content", default="", help="Raw markdown content to write or append")
    parser.add_argument("-f", "--content-file", help="Path to markdown file to sync from")
    parser.add_argument("-v", "--vault-path", help="Root path to Obsidian vault")
    parser.add_argument("-a", "--append", action="store_true", help="Append content rather than overwrite")
    parser.add_argument("-o", "--open", action="store_true", help="Launch or focus Obsidian note")

    args = parser.parse_args()

    vault_path = Path(args.vault_path).expanduser().resolve() if args.vault_path else get_default_vault_path()
    dot_obsidian = vault_path / ".obsidian"
    lessons_dir = vault_path / "Lessons"
    assets_dir = lessons_dir / "assets" / "circuits"

    vault_path.mkdir(parents=True, exist_ok=True)
    dot_obsidian.mkdir(parents=True, exist_ok=True)
    lessons_dir.mkdir(parents=True, exist_ok=True)
    assets_dir.mkdir(parents=True, exist_ok=True)

    # Initialize app.json if missing
    app_json = dot_obsidian / "app.json"
    if not app_json.exists():
        try:
            with open(app_json, "w", encoding="utf-8") as f:
                json.dump({"showLineNumber": True, "livePreview": True}, f, indent=2)
        except Exception:
            pass

    register_vault_if_needed(vault_path)

    clean_topic = sanitize_filename(args.topic)
    note_file = lessons_dir / f"{clean_topic}.md"

    text_to_write = ""
    if args.content_file:
        source_path = Path(args.content_file).expanduser().resolve()
        if source_path.exists():
            text_to_write = source_path.read_text(encoding="utf-8")
        else:
            sys.stderr.write(f"Warning: Content file not found: {source_path}\n")

    if args.content:
        if text_to_write:
            text_to_write = f"{text_to_write}\n\n{args.content}"
        else:
            text_to_write = args.content

    if not text_to_write and not note_file.exists():
        text_to_write = f"# {clean_topic}\n\n"

    if text_to_write:
        if args.append and note_file.exists():
            with open(note_file, "a", encoding="utf-8") as f:
                f.write(f"\n\n{text_to_write}")
            print(f"Appended content to {note_file}")
        else:
            note_file.write_text(text_to_write, encoding="utf-8")
            print(f"Saved lesson note to {note_file}")

    if args.open:
        open_obsidian_uri(vault_path.name, f"Lessons/{clean_topic}")


if __name__ == "__main__":
    main()
