"""Install GameCube / Wii disc images onto a USB Loader GX + Nintendont drive.

GameCube (.rvz .iso .gcm .gcz .wia .ciso)  ->  <drive>/games/<Title> [ID]/game.iso
                                               (disc2.iso for "(Disc 2)" files)
Wii (.wbfs, incl. split .wbf1/.wbf2 parts)  ->  <drive>/wbfs/<Title> [ID]/<ID>.wbfs
Wii .iso/.rvz are not supported: the loader drives are FAT32 (4 GB file limit),
so Wii games must already be .wbfs.

Uses DolphinTool (from Dolphin) to read the game ID and to convert GameCube
images to plain ISO, which is what Nintendont needs. Games already installed
(same folder + same size) are skipped. Sources are never modified.

Usage:
    python wii_install.py FILE [FILE ...] [--drive L:]
    python wii_install.py --list LISTFILE [--drive L:]     (Double Commander %L)
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GC_EXT = {".rvz", ".iso", ".gcm", ".gcz", ".wia", ".ciso"}
WII_EXT = {".wbfs"}
GC_ISO_SIZE = 1459978240


def load_settings() -> dict:
    data = {
        "dolphin_tool": r"C:\development\wii\tools\Dolphin-x64\DolphinTool.exe",
        "drive": "L:",
    }
    cfg = HERE / "actions.json"
    if cfg.exists():
        data.update(json.loads(cfg.read_text(encoding="utf-8")).get("wii", {}))
    return data


def safe_name(s: str) -> str:
    s = re.sub(r'[\\/:*?"<>|]', " -", s)
    s = re.sub(r"\s+", " ", s).replace(" - -", " -")
    return s.strip(" .")


def title_from_file(p: Path) -> str:
    stem = p.stem
    stem = re.sub(r"\s*[\(\[].*?[\)\]]", "", stem)  # drop (USA) (Rev 1) [GW7E69] ...
    return safe_name(stem) or p.stem


def disc_number(p: Path) -> int:
    m = re.search(r"\(Disc\s*(\d)\)", p.name, re.I)
    return int(m.group(1)) if m else 1


def game_id(tool: str, p: Path) -> str:
    out = subprocess.run([tool, "header", "-i", str(p)], capture_output=True, text=True, errors="replace")
    m = re.search(r"Game ID:\s*([A-Z0-9]{6})", out.stdout + out.stderr)
    if not m:
        raise RuntimeError(f"could not read the game ID ({(out.stdout + out.stderr).strip()[:200]})")
    return m.group(1)


def free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def install_gc(tool: str, src: Path, root: Path) -> str:
    gid = game_id(tool, src)
    folder = root / "games" / f"{title_from_file(src)} [{gid}]"
    n = disc_number(src)
    target = folder / ("game.iso" if n == 1 else f"disc{n}.iso")
    if target.exists() and target.stat().st_size == GC_ISO_SIZE:
        return f"already installed: {folder.name}/{target.name}"
    existing = [d for d in (root / "games").glob(f"*[[]{gid}[]]") if (d / target.name).exists()]
    if existing:
        return f"already installed as {existing[0].name}"
    if free_bytes(root) < GC_ISO_SIZE + 2 * 1024**3:
        raise RuntimeError(f"not enough free space on {root}")
    folder.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".partial")
    if src.suffix.lower() in (".iso", ".gcm") and src.stat().st_size == GC_ISO_SIZE:
        shutil.copyfile(src, tmp)
    else:
        r = subprocess.run([tool, "convert", "-i", str(src), "-o", str(tmp), "-f", "iso"])
        if r.returncode != 0:
            tmp.unlink(missing_ok=True)
            raise RuntimeError("DolphinTool conversion failed")
    if tmp.stat().st_size < 100 * 1024**2:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("converted file is too small, removed")
    if game_id(tool, tmp) != gid:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("game ID check failed after conversion, removed")
    tmp.replace(target)
    return f"OK -> {folder.name}/{target.name}"


def install_wii(tool: str, src: Path, root: Path) -> str:
    gid = game_id(tool, src)
    folder = root / "wbfs" / f"{title_from_file(src)} [{gid}]"
    parts = [src] + sorted(src.parent.glob(src.stem + ".wbf[0-9]"))
    existing = [d for d in (root / "wbfs").glob(f"*[[]{gid}[]]") if (d / f"{gid}.wbfs").exists()]
    if existing:
        return f"already installed as {existing[0].name}"
    need = sum(p.stat().st_size for p in parts)
    if free_bytes(root) < need + 1024**3:
        raise RuntimeError(f"not enough free space on {root}")
    folder.mkdir(parents=True, exist_ok=True)
    for p in parts:
        dest = folder / (gid + p.suffix.lower())
        tmp = dest.with_name(dest.name + ".partial")
        shutil.copyfile(p, tmp)
        if tmp.stat().st_size != p.stat().st_size:
            tmp.unlink(missing_ok=True)
            raise RuntimeError(f"size mismatch copying {p.name}")
        tmp.replace(dest)
    return f"OK -> {folder.name}/{gid}.wbfs" + (f" (+{len(parts) - 1} parts)" if len(parts) > 1 else "")


def pause_if_console():
    if sys.stdin and sys.stdin.isatty():
        try:
            input("\nPress Enter to close...")
        except EOFError:
            pass


def main() -> int:
    s = load_settings()
    ap = argparse.ArgumentParser(description="Install GameCube/Wii images for USB Loader GX + Nintendont.")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--list")
    ap.add_argument("--drive", default=s["drive"], help="loader drive or folder (default %(default)s)")
    a = ap.parse_args()

    names = list(a.files)
    if a.list:
        names += [l.strip() for l in Path(a.list).read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    tool = s["dolphin_tool"]
    if not Path(tool).exists():
        print(f"DolphinTool not found: {tool} (set wii.dolphin_tool in actions.json)")
        return 1
    root = Path(a.drive if a.drive.endswith(("/", "\\")) else a.drive + "/")
    if not root.exists():
        print(f"Loader drive {a.drive} is not connected.")
        return 1

    ok = fail = 0
    for i, n in enumerate(names, 1):
        p = Path(n)
        ext = p.suffix.lower()
        print(f"[{i}/{len(names)}] {p.name}")
        try:
            if p.is_dir():
                print("  skipped: folder (select the disc image files)")
                continue
            if ext in WII_EXT:
                msg = install_wii(tool, p, root)
            elif ext in GC_EXT:
                gid = game_id(tool, p)
                if gid[0] in "RS":  # Wii disc IDs start with R or S
                    print("  skipped: Wii game in ISO/RVZ form - convert it to .wbfs first (FAT32 4 GB limit)")
                    continue
                msg = install_gc(tool, p, root)
            else:
                print("  skipped: not a GameCube/Wii image")
                continue
            print("  " + msg)
            if msg.startswith("OK"):
                ok += 1
        except Exception as e:
            print(f"  FAILED: {e}")
            fail += 1
    print(f"\nDone: {ok} ok, {fail} failed. Destination: {root}")
    if ok:
        print("Tip: rerun C:\\development\\wii\\make_categories.ps1 to refresh USB Loader GX categories.")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    code = main()
    pause_if_console()
    sys.exit(code)
