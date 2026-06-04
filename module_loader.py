"""Expert knowledge packages: install, list, uninstall (OTA / local path)."""

from __future__ import annotations

import json
import os
import shutil
import zipfile
from pathlib import Path
from typing import Any


MANIFEST_NAME = "manifest.json"


def packages_root() -> Path:
    raw = os.getenv("PACKAGES_DIR", "./packages")
    path = Path(raw)
    if not path.is_absolute():
        path = Path(__file__).resolve().parent / path
    path.mkdir(parents=True, exist_ok=True)
    return path


def _read_manifest(pkg_dir: Path) -> dict[str, Any] | None:
    manifest_path = pkg_dir / MANIFEST_NAME
    if not manifest_path.is_file():
        return None
    with manifest_path.open(encoding="utf-8") as f:
        return json.load(f)


def list_installed() -> list[dict[str, Any]]:
    root = packages_root()
    out: list[dict[str, Any]] = []
    for child in sorted(root.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        manifest = _read_manifest(child)
        if manifest:
            out.append(
                {
                    "id": manifest.get("id", child.name),
                    "domain": manifest.get("domain"),
                    "version": manifest.get("version"),
                    "path": str(child),
                    "loaded": (child / ".loaded").is_file(),
                }
            )
        else:
            out.append({"id": child.name, "path": str(child), "manifest": False})
    return out


def _extract_zip(archive: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "r") as zf:
        zf.extractall(dest)


def _find_package_root(extracted: Path) -> Path:
    """Return directory that contains manifest.json (top or one level down)."""
    if (extracted / MANIFEST_NAME).is_file():
        return extracted
    for child in extracted.iterdir():
        if child.is_dir() and (child / MANIFEST_NAME).is_file():
            return child
    return extracted


def install_from_path(source: str) -> dict[str, Any]:
    """
    Install a package from a local directory or .zip file on the Pi.
    Host OTA will copy/upload here first, then call install_module via MCP.
    """
    src = Path(source).expanduser().resolve()
    if not src.exists():
        return {"ok": False, "error": f"Source not found: {source}"}

    root = packages_root()
    staging = root / "_staging"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    try:
        if src.is_dir():
            shutil.copytree(src, staging / "payload", dirs_exist_ok=True)
            pkg_root = _find_package_root(staging / "payload")
        elif src.suffix.lower() == ".zip":
            _extract_zip(src, staging / "payload")
            pkg_root = _find_package_root(staging / "payload")
        else:
            return {"ok": False, "error": "Source must be a directory or .zip file"}

        manifest = _read_manifest(pkg_root)
        if not manifest:
            return {"ok": False, "error": f"Missing {MANIFEST_NAME} in package"}

        pkg_id = manifest.get("id") or pkg_root.name
        target = root / pkg_id
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(pkg_root, target)

        # Mark installed; dynamic import/hot-load is Phase 2.
        (target / ".loaded").write_text("pending\n", encoding="utf-8")

        return {
            "ok": True,
            "id": pkg_id,
            "domain": manifest.get("domain"),
            "version": manifest.get("version"),
            "path": str(target),
            "note": "Package stored. Runtime tool injection (hot-load) is Phase 2.",
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def uninstall(module_id: str) -> dict[str, Any]:
    root = packages_root()
    target = root / module_id
    if not target.is_dir():
        return {"ok": False, "error": f"Module not installed: {module_id}"}
    shutil.rmtree(target)
    return {"ok": True, "id": module_id, "removed": True}
