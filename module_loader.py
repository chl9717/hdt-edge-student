"""Expert knowledge packages: install, list, uninstall (OTA / local path)."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import traceback
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

_activated_ids: set[str] = set()
_install_lock = threading.Lock()
_runtime_by_module: dict[str, Any] = {}

DOMAIN_TO_PACKAGE = {
    "pose": "pose-estimation-v1",
    "emotion": "emotion-recognition-v1",
}


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
            loaded = child.name in _activated_ids
            flag = child / ".loaded"
            if not loaded and flag.is_file():
                loaded = flag.read_text(encoding="utf-8").strip() == "active"
            out.append(
                {
                    "id": manifest.get("id", child.name),
                    "domain": manifest.get("domain"),
                    "version": manifest.get("version"),
                    "path": str(child),
                    "loaded": loaded,
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


def _verify_package_dir(target: Path) -> dict[str, Any] | None:
    """Return error dict if install result is unusable."""
    if not target.is_dir():
        return {"ok": False, "error": f"Package directory missing: {target}"}
    files = sorted(p.name for p in target.iterdir() if p.is_file())
    if not files:
        return {
            "ok": False,
            "error": "Package directory is empty after install",
            "path": str(target),
        }
    if "module.py" not in files or MANIFEST_NAME not in files:
        return {
            "ok": False,
            "error": "Incomplete package (need module.py and manifest.json)",
            "path": str(target),
            "files": files,
        }
    return None


def install_from_path(source: str) -> dict[str, Any]:
    """
    Install a package from a local directory or .zip file on the Pi.
    Host OTA will copy/upload here first, then call install_module via MCP.
    """
    src = Path(source).expanduser().resolve()
    if not src.exists():
        return {"ok": False, "error": f"Source not found: {source}"}

    with _install_lock:
        return _install_from_path_locked(src)


def _install_from_path_locked(src: Path) -> dict[str, Any]:
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

        bad = _verify_package_dir(target)
        if bad:
            shutil.rmtree(target, ignore_errors=True)
            bad["pkg_root"] = str(pkg_root)
            bad["source"] = str(src)
            _log(f"install rejected: {bad.get('error')} files={bad.get('files')}")
            return bad

        (target / ".loaded").write_text("installed\n", encoding="utf-8")
        file_count = sum(1 for p in target.rglob("*") if p.is_file())
        _log(f"install ok id={pkg_id} files={file_count} path={target}")

        return {
            "ok": True,
            "id": pkg_id,
            "domain": manifest.get("domain"),
            "version": manifest.get("version"),
            "path": str(target),
            "file_count": file_count,
            "note": "Package stored. Call activate_module to hot-load MCP tools.",
        }
    except Exception as e:
        _log(f"install exception: {e}")
        return {"ok": False, "error": str(e)}
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def _log(msg: str) -> None:
    sys.stderr.write(f"[Student/loader] {msg}\n")
    sys.stderr.flush()


def install_from_url(package_url: str) -> dict[str, Any]:
    """Download a zip package from the Host PC (or any HTTP URL) and install."""
    root = packages_root()
    tmp = root / "_download.zip"
    try:
        _log(f"download {package_url} -> {tmp}")
        urllib.request.urlretrieve(package_url, tmp)
        out = install_from_path(str(tmp))
        if out.get("ok"):
            _log(f"installed id={out.get('id')} path={out.get('path')}")
        else:
            _log(f"install failed: {out.get('error')}")
        return out
    except Exception as e:
        return {"ok": False, "error": str(e), "url": package_url}
    finally:
        if tmp.is_file():
            tmp.unlink(missing_ok=True)


def install_pip_deps(module_id: str) -> dict[str, Any]:
    """Install manifest pip_deps into the Student conda env (same python as MCP server)."""
    pkg_dir = packages_root() / module_id
    manifest = _read_manifest(pkg_dir)
    if not manifest:
        return {"ok": False, "error": f"Module not installed or missing manifest: {module_id}"}

    deps = manifest.get("pip_deps") or []
    if not deps:
        return {"ok": True, "id": module_id, "installed": [], "note": "no pip_deps in manifest"}

    cmd = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--upgrade",
        *deps,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=int(os.getenv("PIP_INSTALL_TIMEOUT", "900")),
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "pip install timed out", "deps": deps}

    ok = proc.returncode == 0
    return {
        "ok": ok,
        "id": module_id,
        "deps": deps,
        "returncode": proc.returncode,
        "stdout_tail": (proc.stdout or "")[-1500:],
        "stderr_tail": (proc.stderr or "")[-1500:],
    }


def run_domain_action(domain: str, action: str) -> dict[str, Any]:
    """
    Start/stop/status via activated expert runtime.
    Stable MCP entrypoint — Host does not need to refresh tools after activate.
    """
    domain = domain.lower().strip()
    module_id = DOMAIN_TO_PACKAGE.get(domain)
    if not module_id:
        return {"ok": False, "error": f"Unknown domain: {domain}"}

    if module_id not in _activated_ids:
        return {
            "ok": False,
            "error": f"Module not active: {module_id}. Call activate_module first.",
            "domain": domain,
        }

    rt = _runtime_by_module.get(module_id)
    if rt is None:
        return {
            "ok": False,
            "error": f"Runtime not ready for {module_id}. Call activate_module again.",
            "domain": domain,
        }

    action = action.lower().strip()
    try:
        if action == "start":
            return {"ok": True, "domain": domain, **rt.start()}
        if action == "stop":
            return {"ok": True, "domain": domain, **rt.stop()}
        if action == "status":
            return {
                "ok": True,
                "domain": domain,
                "inference_running": rt.is_running,
                **rt.monitor.get_status(),
            }
        return {"ok": False, "error": f"Unknown action: {action}"}
    except Exception as e:
        _log(f"run_domain_action {domain}/{action} error: {e}")
        return {"ok": False, "error": str(e), "domain": domain, "action": action}


def activate(mcp, module_id: str, *, install_deps: bool = True) -> dict[str, Any]:
    """Hot-load expert module.py and register domain MCP tools on this server."""
    if module_id in _activated_ids and module_id in _runtime_by_module:
        return {"ok": True, "id": module_id, "already_active": True}

    pkg_dir = packages_root() / module_id
    if not pkg_dir.is_dir():
        return {"ok": False, "error": f"Module not installed: {module_id}"}

    module_py = pkg_dir / "module.py"
    if not module_py.is_file():
        return {"ok": False, "error": f"Missing module.py in {pkg_dir}"}

    if install_deps:
        _log(f"activate {module_id}: pip install (may take several minutes on Pi)...")
        pip_out = install_pip_deps(module_id)
        if not pip_out.get("ok"):
            _log(f"pip failed: {pip_out.get('stderr_tail', pip_out)}")
            return {
                "ok": False,
                "error": "pip dependency install failed",
                "pip": pip_out,
            }
        _log(f"pip ok deps={pip_out.get('deps') or []}")

    pkg_path = str(pkg_dir)
    if pkg_path not in sys.path:
        sys.path.insert(0, pkg_path)

    try:
        spec = importlib.util.spec_from_file_location(
            f"hdt_expert_{module_id}", module_py
        )
        if spec is None or spec.loader is None:
            return {"ok": False, "error": "Could not load module spec"}

        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        if not hasattr(mod, "register"):
            return {"ok": False, "error": "module.py must define register(mcp)"}

        mod.register(mcp)
        _activated_ids.add(module_id)
        if hasattr(mod, "_rt"):
            _runtime_by_module[module_id] = mod._rt()
        (pkg_dir / ".loaded").write_text("active\n", encoding="utf-8")
        _log(f"activated {module_id} domain={(_read_manifest(pkg_dir) or {}).get('domain')}")
        return {
            "ok": True,
            "id": module_id,
            "domain": (_read_manifest(pkg_dir) or {}).get("domain"),
            "hot_loaded": True,
            "pip_deps_installed": install_deps,
            "runtime_ready": module_id in _runtime_by_module,
        }
    except Exception as e:
        _log(f"activate error: {e}\n{traceback.format_exc()}")
        return {"ok": False, "error": str(e)}
    finally:
        if pkg_path in sys.path:
            sys.path.remove(pkg_path)


def uninstall(module_id: str) -> dict[str, Any]:
    root = packages_root()
    target = root / module_id
    if not target.is_dir():
        return {"ok": False, "error": f"Module not installed: {module_id}"}
    _activated_ids.discard(module_id)
    _runtime_by_module.pop(module_id, None)
    shutil.rmtree(target)
    return {"ok": True, "id": module_id, "removed": True}
