"""
Empty Student Agent — MCP Server on Raspberry Pi.

Expose base tools only; expert modules are installed OTA into ./packages.

  http://<student-pi-ip>:8100/mcp
"""

import json
import os
import platform
import subprocess
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from dotenv import load_dotenv
from mcp.server.fastmcp import Context, FastMCP

import module_loader

load_dotenv()

HOST = os.getenv("MCP_HOST", "0.0.0.0")
PORT = int(os.getenv("MCP_PORT", "8100"))
STUDENT_ID = os.getenv("STUDENT_ID", "hdt-student-01")


@asynccontextmanager
async def student_lifespan(_app: FastMCP):
    sys.stderr.write(
        f"[Student] Empty agent starting id={STUDENT_ID} "
        f"packages={module_loader.packages_root()}\n"
    )
    yield
    sys.stderr.write("[Student] Shutting down.\n")


mcp = FastMCP(
    "HDT_Student_Server",
    instructions=(
        "Empty HDT student device. Install expert knowledge packages via install_module; "
        "domain tools appear after hot-load (Phase 2)."
    ),
    host=HOST,
    port=PORT,
    lifespan=student_lifespan,
)


def _device_info() -> dict:
    info: dict = {
        "student_id": STUDENT_ID,
        "hostname": platform.node(),
        "system": platform.system(),
        "machine": platform.machine(),
        "python": sys.version.split()[0],
        "packages_dir": str(module_loader.packages_root()),
        "installed_modules": module_loader.list_installed(),
    }
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    info["mem_total_kb"] = line.split()[1]
                    break
    except OSError:
        pass
    try:
        proc = subprocess.run(
            ["v4l2-ctl", "--list-devices"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            info["cameras_v4l2"] = proc.stdout.strip()[:2000]
        else:
            info["cameras_v4l2"] = None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        info["cameras_v4l2"] = None
    return info


@mcp.resource("student://status")
def student_status_resource() -> str:
    data = {
        "role": "empty_agent",
        "student_id": STUDENT_ID,
        "mcp_port": PORT,
        **{k: v for k, v in _device_info().items() if k != "installed_modules"},
        "module_count": len(module_loader.list_installed()),
    }
    return json.dumps(data, ensure_ascii=False, indent=2)


@mcp.resource("student://modules")
def student_modules_resource() -> str:
    return json.dumps(module_loader.list_installed(), ensure_ascii=False, indent=2)


@mcp.tool()
async def health_check() -> str:
    """Return student agent liveness and identity."""
    return json.dumps(
        {"ok": True, "student_id": STUDENT_ID, "role": "empty_agent"},
        ensure_ascii=False,
    )


@mcp.tool()
async def get_device_info(ctx: Context) -> str:
    """Hardware/software snapshot for Host provisioning decisions."""
    return json.dumps(_device_info(), ensure_ascii=False, indent=2)


@mcp.tool()
async def list_installed_modules(ctx: Context) -> str:
    """List expert packages installed under PACKAGES_DIR."""
    return json.dumps(module_loader.list_installed(), ensure_ascii=False, indent=2)


@mcp.tool()
async def install_module(ctx: Context, source_path: str) -> str:
    """
    Install an expert package from a path on this device (folder or .zip).
    Host typically uploads to the Pi first, then calls this with the local path.
    """
    result = module_loader.install_from_path(source_path)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def install_module_from_url(ctx: Context, package_url: str) -> str:
    """Download and install an expert package zip from the Host PC HTTP server."""
    result = module_loader.install_from_url(package_url)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def install_package_dependencies(ctx: Context, module_id: str) -> str:
    """pip install deps from package manifest (opencv, mediapipe, etc.)."""
    result = module_loader.install_pip_deps(module_id)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def activate_module(ctx: Context, module_id: str) -> str:
    """Install pip deps from manifest, hot-load package, register pose/emotion MCP tools."""
    result = module_loader.activate(mcp, module_id, install_deps=True)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def start_domain_inference(ctx: Context, domain: str) -> str:
    """Start pose or emotion inference on an activated expert module (pose | emotion)."""
    result = module_loader.run_domain_action(domain, "start")
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def stop_domain_inference(ctx: Context, domain: str) -> str:
    """Stop pose or emotion inference (pose | emotion)."""
    result = module_loader.run_domain_action(domain, "stop")
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def get_domain_inference_status(ctx: Context, domain: str) -> str:
    """Status for activated pose or emotion module (pose | emotion)."""
    result = module_loader.run_domain_action(domain, "status")
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.tool()
async def uninstall_module(ctx: Context, module_id: str) -> str:
    """Remove an installed expert package by id."""
    result = module_loader.uninstall(module_id)
    return json.dumps(result, ensure_ascii=False, indent=2)


@mcp.prompt()
def student_provisioning_workflow() -> str:
    return """
    Empty student provisioning workflow:
    1. Call get_device_info to check camera, memory, Python version.
    2. Transfer expert package (.zip or folder) to the Pi (scp/rsync).
    3. Call install_module with the local path on the Pi.
    4. Call list_installed_modules to verify manifest id and version.
    5. Call activate_module then start_domain_inference(domain) or legacy start_* tools.
    """


if __name__ == "__main__":
    mcp.run(transport="streamable-http")

