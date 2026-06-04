#!/usr/bin/env bash
# One-shot setup for HDT Empty Student Agent (Raspberry Pi).
# Usage:
#   git clone <repo-url> hdt-edge-student && cd hdt-edge-student
#   ./install.sh
#   ./install.sh --systemd
#   ./install.sh --no-apt    # skip apt packages (venv/pip only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_SYSTEMD=0
RUN_APT=1

for arg in "$@"; do
  case "$arg" in
    --systemd) INSTALL_SYSTEMD=1 ;;
    --no-apt) RUN_APT=0 ;;
    -h|--help)
      echo "Usage: ./install.sh [--systemd] [--no-apt]"
      echo "  --systemd  Register and start hdt-student.service"
      echo "  --no-apt   Skip apt packages (python3-venv, v4l-utils)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)"
      exit 1
      ;;
  esac
done

echo "=== HDT Student Agent — install ==="
echo "Directory: $SCRIPT_DIR"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Warning: this script targets Raspberry Pi OS (Linux)."
fi

if [[ $RUN_APT -eq 1 ]] && command -v apt-get >/dev/null 2>&1; then
  echo "-> Installing system packages (sudo)..."
  sudo apt-get update -qq
  sudo apt-get install -y python3 python3-venv python3-pip git curl v4l-utils
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found."
  exit 1
fi

PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "-> Python $PYVER"

if [[ ! -d .venv ]]; then
  echo "-> Creating virtualenv .venv"
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "-> Created .env from .env.example"
else
  echo "-> Keeping existing .env"
fi

mkdir -p packages

chmod +x install.sh 2>/dev/null || true

if [[ $INSTALL_SYSTEMD -eq 1 ]]; then
  SERVICE_SRC="$SCRIPT_DIR/systemd/hdt-student.service"
  SERVICE_DST="/etc/systemd/system/hdt-student.service"
  if [[ ! -f "$SERVICE_SRC" ]]; then
    echo "Error: missing $SERVICE_SRC"
    exit 1
  fi
  echo "-> Installing systemd unit..."
  sudo sed "s|@INSTALL_DIR@|$SCRIPT_DIR|g" "$SERVICE_SRC" | sudo tee "$SERVICE_DST" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable hdt-student.service
  sudo systemctl restart hdt-student.service
  echo "-> hdt-student.service enabled and started"
  sudo systemctl --no-pager status hdt-student.service || true
else
  echo ""
  echo "Manual run:"
  echo "  cd $SCRIPT_DIR"
  echo "  source .venv/bin/activate"
  echo "  python server_student.py"
fi

# Firewall hint (ufw)
if command -v ufw >/dev/null 2>&1; then
  PORT="$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 8100)"
  if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! sudo ufw status | grep -q "${PORT}/tcp"; then
      echo ""
      echo "Tip: allow MCP port for PC Host:"
      echo "  sudo ufw allow ${PORT}/tcp"
    fi
  fi
fi

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}')"
PORT="$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 8100)"
echo ""
echo "=== Done ==="
echo "MCP URL (from PC):  http://${IP_HINT:-<pi-ip>}:${PORT}/mcp"
echo "Set STUDENT_ID in .env if this device has a custom name."
echo "Do NOT install mediapipe/pose/emotion here — Host provisions packages later."
