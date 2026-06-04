#!/usr/bin/env bash
# Remove HDT Student Agent install (service, OTA packages, conda env, local config).
#
#   cd ~/hdt-edge-student
#   chmod +x uninstall.sh
#   ./uninstall.sh              # keep repo + Miniforge, wipe runtime
#   ./uninstall.sh --purge-repo # delete entire ~/hdt-edge-student directory
#   ./uninstall.sh --remove-miniforge  # also remove ~/miniforge3 (slow, large)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PURGE_REPO=0
REMOVE_MINIFORGE=0
CONDA_ENV_NAME="${CONDA_ENV_NAME:-hdt-student}"
MINIFORGE_DIR="${MINIFORGE_DIR:-$HOME/miniforge3}"
SERVICE_NAME="hdt-student.service"

for arg in "$@"; do
  case "$arg" in
    --purge-repo) PURGE_REPO=1 ;;
    --remove-miniforge) REMOVE_MINIFORGE=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [options]"
      echo "  (default)            Stop service, remove packages, conda env hdt-student, .env"
      echo "  --purge-repo         Delete whole repo directory (run from parent after)"
      echo "  --remove-miniforge   Remove $MINIFORGE_DIR (only if you want full Python wipe)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      exit 1
      ;;
  esac
done

echo "=== HDT Student Agent - uninstall ==="
echo "Directory: $SCRIPT_DIR"

if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
  echo "-> Stopping and disabling ${SERVICE_NAME}..."
  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
fi
if [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]]; then
  echo "-> Removing systemd unit..."
  sudo rm -f "/etc/systemd/system/${SERVICE_NAME}"
  sudo systemctl daemon-reload
fi

if [[ -d packages ]]; then
  echo "-> Removing OTA packages (packages/)..."
  rm -rf packages/*
  mkdir -p packages
  touch packages/.gitkeep 2>/dev/null || true
fi

rm -rf .venv __pycache__ .pytest_cache 2>/dev/null || true
find . -maxdepth 2 -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
rm -f .runtime-python .env 2>/dev/null || true

conda_remove_env() {
  if [[ -f "$MINIFORGE_DIR/etc/profile.d/conda.sh" ]]; then
    # shellcheck disable=SC1091
    source "$MINIFORGE_DIR/etc/profile.d/conda.sh"
  elif command -v conda >/dev/null 2>&1; then
    local base
    base="$(conda info --base 2>/dev/null || echo "")"
    if [[ -n "$base" && -f "$base/etc/profile.d/conda.sh" ]]; then
      # shellcheck disable=SC1091
      source "$base/etc/profile.d/conda.sh"
    fi
  else
    return 0
  fi
  if conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV_NAME"; then
    echo "-> Removing conda env: $CONDA_ENV_NAME"
    conda env remove -n "$CONDA_ENV_NAME" -y
  else
    echo "-> Conda env not found: $CONDA_ENV_NAME (skip)"
  fi
}

conda_remove_env

if [[ $REMOVE_MINIFORGE -eq 1 ]]; then
  echo "-> Removing Miniforge at $MINIFORGE_DIR ..."
  rm -rf "$MINIFORGE_DIR"
fi

if [[ $PURGE_REPO -eq 1 ]]; then
  PARENT="$(dirname "$SCRIPT_DIR")"
  NAME="$(basename "$SCRIPT_DIR")"
  echo "-> Purging repo directory: $SCRIPT_DIR"
  cd "$PARENT"
  rm -rf "$NAME"
  echo "=== Removed $PARENT/$NAME ==="
  echo "Re-install: git clone https://github.com/chl9717/hdt-edge-student.git && cd hdt-edge-student && ./install.sh --systemd"
  exit 0
fi

echo ""
echo "=== Uninstall done (repo kept) ==="
echo "OTA packages, .env, conda env '$CONDA_ENV_NAME', and systemd service removed."
echo ""
echo "Fresh install:"
echo "  cd $SCRIPT_DIR"
echo "  ./install.sh --systemd"
echo "  # or: ./install.sh --install-miniforge --systemd"
