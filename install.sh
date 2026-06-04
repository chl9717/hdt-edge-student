#!/usr/bin/env bash
# One-shot setup for HDT Empty Student Agent (Raspberry Pi).
# Usage:
#   git clone https://github.com/chl9717/hdt-edge-student.git && cd hdt-edge-student
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

echo "=== HDT Student Agent - install ==="
echo "Directory: $SCRIPT_DIR"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Warning: this script targets Raspberry Pi OS (Linux)."
fi

if [[ $RUN_APT -eq 1 ]] && command -v apt-get >/dev/null 2>&1; then
  echo "-> Installing system packages (sudo)..."
  sudo apt-get update -qq
  sudo apt-get install -y python3.11 python3.11-venv python3-pip git curl v4l-utils \
    || sudo apt-get install -y python3 python3-venv python3-pip git curl v4l-utils
fi

# Pose expert (mediapipe) needs Python 3.11 — not 3.12+
PYTHON_BIN=""
for candidate in python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    minor="$("$candidate" -c 'import sys; print(sys.version_info.minor)')"
    major="$("$candidate" -c 'import sys; print(sys.version_info.major)')"
    if [[ "$major" == "3" && "$minor" == "11" ]]; then
      PYTHON_BIN="$candidate"
      break
    fi
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python 3.11 required (mediapipe on student after OTA)."
  echo "  sudo apt install python3.11 python3.11-venv"
  echo "  Or re-flash Pi OS that ships 3.11 as default."
  exit 1
fi

PYVER="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "-> Using $PYTHON_BIN ($PYVER)"

if [[ -d .venv ]]; then
  venv_py="$(.venv/bin/python -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "")"
  if [[ "$venv_py" != "11" ]]; then
    echo "-> Removing old .venv (not Python 3.11)"
    rm -rf .venv
  fi
fi

if [[ ! -d .venv ]]; then
  echo "-> Creating virtualenv .venv with $PYTHON_BIN"
  "$PYTHON_BIN" -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip -q
if ! pip install -r requirements.txt -q; then
  echo "-> pip install failed; retrying once..."
  pip install -r requirements.txt
fi

write_default_env() {
  cat > .env << 'EOF'
MCP_HOST=0.0.0.0
MCP_PORT=8100
PACKAGES_DIR=./packages
STUDENT_ID=hdt-student-01
EOF
}

if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    echo "-> Created .env from .env.example"
  elif [[ -f env.example ]]; then
    cp env.example .env
    echo "-> Created .env from env.example"
  else
    write_default_env
    echo "-> Created .env with defaults (.env.example not in repo)"
  fi
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
  echo "-> Installing systemd unit (user: ${USER})..."
  sudo sed -e "s|@INSTALL_DIR@|$SCRIPT_DIR|g" -e "s|@INSTALL_USER@|$USER|g" \
    "$SERVICE_SRC" | sudo tee "$SERVICE_DST" >/dev/null
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
