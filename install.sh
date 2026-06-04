#!/usr/bin/env bash
# HDT Empty Student Agent — install (conda recommended on Pi OS Trixie / Python 3.13).
#
#   git clone https://github.com/chl9717/hdt-edge-student.git
#   cd hdt-edge-student
#   ./install.sh --systemd
#
# Conda not installed yet:
#   ./install.sh --install-miniforge --systemd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INSTALL_SYSTEMD=0
RUN_APT=1
USE_VENV=0
ALLOW_313=0
INSTALL_MINIFORGE=0
CONDA_ENV_NAME="${CONDA_ENV_NAME:-hdt-student}"
MINIFORGE_DIR="${MINIFORGE_DIR:-$HOME/miniforge3}"

for arg in "$@"; do
  case "$arg" in
    --systemd) INSTALL_SYSTEMD=1 ;;
    --no-apt) RUN_APT=0 ;;
    --venv) USE_VENV=1 ;;
    --allow-313) ALLOW_313=1 ;;
    --install-miniforge) INSTALL_MINIFORGE=1 ;;
    -h|--help)
      echo "Usage: ./install.sh [options]"
      echo "  (default)     conda env from environment.yml (Python 3.11)"
      echo "  --systemd     Enable and start hdt-student.service"
      echo "  --install-miniforge   Install Miniforge to ~/miniforge3 first"
      echo "  --venv        Use python venv instead of conda"
      echo "  --allow-313   With --venv only: allow system Python 3.13"
      echo "  --no-apt      Skip apt packages"
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
  sudo apt-get install -y git curl v4l-utils \
    || true
  if [[ $USE_VENV -eq 1 ]]; then
    sudo apt-get install -y python3.11 python3.11-venv 2>/dev/null \
      || sudo apt-get install -y python3 python3-venv python3-pip
  fi
fi

PYTHON_EXEC=""

install_miniforge() {
  if [[ -x "$MINIFORGE_DIR/bin/conda" ]]; then
    echo "-> Miniforge already at $MINIFORGE_DIR"
    return 0
  fi
  arch="$(uname -m)"
  case "$arch" in
    aarch64|arm64) installer="Miniforge3-Linux-aarch64.sh" ;;
    armv7l|armv6l) installer="Miniforge3-Linux-armv7l.sh" ;;
    x86_64|amd64) installer="Miniforge3-Linux-x86_64.sh" ;;
    *)
      echo "Error: unsupported arch for Miniforge: $arch"
      exit 1
      ;;
  esac
  url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer}"
  tmp="$(mktemp /tmp/miniforge.XXXXXX.sh)"
  echo "-> Downloading $url"
  curl -fsSL "$url" -o "$tmp"
  bash "$tmp" -b -p "$MINIFORGE_DIR"
  rm -f "$tmp"
}

conda_activate() {
  if [[ -f "$MINIFORGE_DIR/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
  elif [[ -f "$HOME/anaconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/anaconda3/etc/profile.d/conda.sh"
  elif [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HOME/miniconda3/etc/profile.d/conda.sh"
  elif command -v conda >/dev/null 2>&1; then
    local conda_base
    conda_base="$(conda info --base 2>/dev/null || echo "")"
    if [[ -n "$conda_base" && -f "$conda_base/etc/profile.d/conda.sh" ]]; then
      # shellcheck disable=SC1091
      source "$conda_base/etc/profile.d/conda.sh"
    fi
  else
    return 1
  fi
  return 0
}

setup_conda_env() {
  if [[ $INSTALL_MINIFORGE -eq 1 ]]; then
    install_miniforge
  fi
  if ! conda_activate; then
    echo "Error: conda not found."
    echo "  ./install.sh --install-miniforge --systemd"
    echo "  or install Miniforge: https://github.com/conda-forge/miniforge"
    exit 1
  fi

  if [[ ! -f environment.yml ]]; then
    echo "Error: environment.yml not found"
    exit 1
  fi

  if conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV_NAME"; then
    echo "-> Updating conda env: $CONDA_ENV_NAME"
    conda env update -n "$CONDA_ENV_NAME" -f environment.yml --prune -y
  else
    echo "-> Creating conda env: $CONDA_ENV_NAME (Python 3.11)"
    conda env create -f environment.yml -y
  fi

  PYTHON_EXEC="$MINIFORGE_DIR/envs/$CONDA_ENV_NAME/bin/python"
  if [[ ! -x "$PYTHON_EXEC" ]]; then
    PYTHON_EXEC="$(conda run -n "$CONDA_ENV_NAME" which python)"
  fi
}

setup_venv() {
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
    if [[ $ALLOW_313 -eq 1 ]] && command -v python3 >/dev/null 2>&1; then
      PYTHON_BIN="python3"
      echo "-> WARNING: venv with $(python3 --version) — mediapipe pose may fail"
    else
      echo "Error: Python 3.11 not found. Use default conda install instead:"
      echo "  ./install.sh --systemd"
      echo "  ./install.sh --install-miniforge --systemd"
      exit 1
    fi
  fi

  if [[ -d .venv ]]; then
    rm -rf .venv
  fi
  echo "-> Creating .venv with $PYTHON_BIN"
  "$PYTHON_BIN" -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --upgrade pip -q
  pip install -r requirements.txt -q
  PYTHON_EXEC="$SCRIPT_DIR/.venv/bin/python"
}

if [[ $USE_VENV -eq 1 ]]; then
  echo "-> Mode: venv"
  setup_venv
else
  echo "-> Mode: conda (recommended)"
  setup_conda_env
fi

if [[ ! -x "$PYTHON_EXEC" ]]; then
  echo "Error: Python not executable: $PYTHON_EXEC"
  exit 1
fi

PYVER="$("$PYTHON_EXEC" --version)"
echo "-> Runtime: $PYTHON_EXEC ($PYVER)"
echo "$PYTHON_EXEC" > "$SCRIPT_DIR/.runtime-python"

write_default_env() {
  cat > .env << EOF
MCP_HOST=0.0.0.0
MCP_PORT=8100
PACKAGES_DIR=./packages
STUDENT_ID=hdt-student-01
CONDA_ENV_NAME=$CONDA_ENV_NAME
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
    echo "-> Created .env with defaults"
  fi
else
  echo "-> Keeping existing .env"
fi

mkdir -p packages
chmod +x install.sh 2>/dev/null || true

if [[ $INSTALL_SYSTEMD -eq 1 ]]; then
  SERVICE_DST="/etc/systemd/system/hdt-student.service"
  echo "-> Installing systemd unit (user: ${USER})..."
  # Write unit directly so old GitHub templates (.venv) cannot break conda installs.
  sudo tee "$SERVICE_DST" >/dev/null <<EOF
[Unit]
Description=HDT Empty Student MCP Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${SCRIPT_DIR}
EnvironmentFile=-${SCRIPT_DIR}/.env
ExecStart=${PYTHON_EXEC} ${SCRIPT_DIR}/server_student.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  echo "-> systemd ExecStart: $PYTHON_EXEC"
  sudo systemctl daemon-reload
  sudo systemctl enable hdt-student.service
  sudo systemctl restart hdt-student.service
  sudo systemctl --no-pager status hdt-student.service || true
else
  echo ""
  echo "Manual run:"
  echo "  $PYTHON_EXEC $SCRIPT_DIR/server_student.py"
  echo "  # or: conda activate $CONDA_ENV_NAME && python server_student.py"
fi

if command -v ufw >/dev/null 2>&1; then
  PORT="$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 8100)"
  if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! sudo ufw status | grep -q "${PORT}/tcp"; then
      echo "Tip: sudo ufw allow ${PORT}/tcp"
    fi
  fi
fi

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}')"
PORT="$(grep -E '^MCP_PORT=' .env 2>/dev/null | cut -d= -f2 || echo 8100)"
echo ""
echo "=== Done ==="
echo "MCP URL: http://${IP_HINT:-<pi-ip>}:${PORT}/mcp"
echo "Python:  $PYTHON_EXEC"
