"""Build the desktop console as a Windows application.

Writes a self-contained folder to build/windows/dist: the executable, its
Python runtime and the data files it reads (bands.json, plmns.json, the icon).

The .iss in desktop/ packages the Flutter app, not this console: the console
ships as the desktop zip, and this script is how to make a console exe by hand.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

DESKTOP = Path(__file__).resolve().parent
ROOT = DESKTOP.parent
BUILD = ROOT / "build" / "windows"
NAME = "Sector Scout Desktop"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-bleak",
        action="store_true",
        help="leave Bluetooth support out (smaller build, buttons disabled)",
    )
    args = parser.parse_args()

    shutil.rmtree(BUILD, ignore_errors=True)
    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--windowed",
        "--name",
        NAME,
        "--icon",
        str(DESKTOP / "sector_scout.ico"),
        "--distpath",
        str(BUILD / "dist"),
        "--workpath",
        str(BUILD / "work"),
        "--specpath",
        str(BUILD),
        "--add-data",
        f"{ROOT / 'bands.json'}{';'}{'.'}",
        "--add-data",
        f"{ROOT / 'plmns.json'}{';'}{'.'}",
        "--add-data",
        f"{DESKTOP / 'sector_scout.ico'}{';'}{'.'}",
        "--hidden-import",
        "tkinter",
    ]
    if not args.no_bleak:
        # Bluetooth is optional, but an installed app has no way to pip install
        # it later, so it is bundled when it is present.
        command += ["--collect-all", "bleak"]
    command.append(str(DESKTOP / "sector_scout_desktop.py"))

    print("building:", " ".join(command[:8]), "...")
    result = subprocess.run(command, cwd=ROOT)
    exe = BUILD / "dist" / NAME / f"{NAME}.exe"
    if result.returncode != 0 or not exe.is_file():
        print("build failed", file=sys.stderr)
        return 1
    print(f"built {exe} ({exe.stat().st_size / 1048576:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
