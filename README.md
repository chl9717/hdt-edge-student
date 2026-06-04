# HDT Empty Student Agent

**빈 깡통(Empty Agent)** 라즈베리파이 MCP 서버.  
도메인 지식은 Host + Librarian이 OTA로 `packages/`에 넣습니다.

**권장: Conda 환경 `hdt-student` (Python 3.11)** — Pi OS Trixie처럼 apt에 3.11이 없어도 MediaPipe pose OTA 가능.

---

## 빠른 설치 (Raspberry Pi)

### 1) clone

```bash
git clone https://github.com/chl9717/hdt-edge-student.git
cd hdt-edge-student
```

### 2) conda (기본, 권장)

**Miniforge가 없을 때 (한 번에):**

```bash
chmod +x install.sh
./install.sh --install-miniforge --systemd
```

**이미 conda/miniforge 있을 때:**

```bash
./install.sh --systemd
```

### 3) 확인

```bash
cat .runtime-python
# ~/miniforge3/envs/hdt-student/bin/python

conda activate hdt-student
python --version    # 3.11.x

systemctl status hdt-student
```

수동 실행:

```bash
conda activate hdt-student
python server_student.py
```

---

## 설치 옵션

| 옵션 | 설명 |
|------|------|
| (기본) | `environment.yml` → conda env `hdt-student` |
| `--install-miniforge` | `~/miniforge3` 설치 후 conda env 생성 |
| `--systemd` | 부팅 시 자동 실행 |
| `--venv` | 예전 방식 (apt python3.11 필요) |
| `--allow-313` | `--venv` + 시스템 3.13 (pose mediapipe 비권장) |

---

## Python / pose

| 방식 | Pi OS Trixie (3.13) | pose (mediapipe) |
|------|---------------------|------------------|
| **conda (기본)** | OK | OK (env 3.11) |
| venv + Bookworm apt 3.11 | OK | OK |
| venv + `--allow-313` | MCP만 | 실패 가능 |

---

## 3-agent 흐름

1. **Host** — 사용자 「자세 추정 필요」
2. **Librarian** — `hdt-edge-pose` → zip URL
3. **Student** — `install_module_from_url` → `activate_module` → `start_pose_inference`

PC Host `.env`: `STUDENT_MCP_URL=http://<pi-ip>:8100/mcp`

---

## MCP 도구 (Empty shell)

| Tool | 설명 |
|------|------|
| `health_check` | 생존 확인 |
| `get_device_info` | 하드웨어 스냅샷 |
| `install_module_from_url` | Librarian zip OTA |
| `activate_module` | hot-load |
| `list_installed_modules` | 설치 목록 |

---

## GitHub에 올릴 파일

- `environment.yml` — conda 3.11
- `install.sh` — conda 기본
- `server_student.py`, `module_loader.py`, `requirements.txt`
- `systemd/hdt-student.service` — `@PYTHON_EXEC@` 치환

이 Pi에 `mediapipe`를 **미리** apt/pip 하지 마세요. OTA 후 expert 패키지 `pip_deps`로 설치합니다.

