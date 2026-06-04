# HDT Empty Student Agent

**빈 깡통(Empty Agent)** 라즈베리파이용 MCP 서버입니다.  
도메인 지식(pose, emotion)은 설치하지 않고, Host가 나중에 `packages/`에 OTA로 넣습니다.

GitHub 프로젝트처럼 **clone → install 한 번**으로 세팅합니다.

---

## 빠른 설치 (Raspberry Pi)

### 1) 저장소 받기

```bash
git clone https://github.com/chl9717/hdt-edge-student.git
cd hdt-edge-student
```

### 2) 한 번에 설치

```bash
chmod +x install.sh
./install.sh --systemd
```

| 옵션 | 설명 |
|------|------|
| (없음) | venv + pip + `.env` 생성, 수동 실행 안내 |
| `--systemd` | 부팅 시 자동 실행 (`hdt-student.service`) |
| `--no-apt` | apt 생략 (이미 python3-venv 등 설치된 경우) |

### 3) 확인

```bash
source .venv/bin/activate
python server_student.py
# 다른 터미널 또는 PC에서:
curl -s http://<pi-ip>:8100/mcp
```

PC Host `.env` 예시 (추후 `host_mcp.py` 연동):

```env
STUDENT_MCP_URL=http://192.168.0.120:8100/mcp
```

`.env`에서 `STUDENT_ID=hdt-student-01` 로 장치 이름을 구분합니다.

---

## 이 Pi에 넣지 말 것

- `hdt-edge-pose` / `hdt-edge-emotion` 전체 복사
- `mediapipe`, emotion TFLite 등 **도메인** pip 패키지
- `server_pose.py` / `server_emotion.py`

---

## MCP 도구 (기본 Shell)

| Tool | 설명 |
|------|------|
| `health_check` | 생존 확인 |
| `get_device_info` | CPU/메모리/Python/카메라(v4l2) |
| `list_installed_modules` | `packages/` 설치 목록 |
| `install_module` | 로컬 경로의 zip/폴더 패키지 설치 |
| `uninstall_module` | 패키지 제거 |

| Resource | 설명 |
|----------|------|
| `student://status` | 에이전트 상태 |
| `student://modules` | 설치된 모듈 목록 |

**Phase 2:** `install_module` 후 `importlib`로 MCP 도구 hot-load → Host 세션 재연결.

---

## 패키지 설치 흐름 (Host → Student)

1. Host가 expert `.zip`을 Pi에 전송 (`scp`, `rsync`, HTTP 업로드 등).
2. Pi에서 MCP `install_module` 호출:

   ```json
   { "source_path": "/home/pi/incoming/pose-estimation-v1.zip" }
   ```

3. `packages/<id>/` 아래에 `manifest.json` 기준으로展開.

패키지 `manifest.json` 최소 예:

```json
{
  "id": "pose-estimation-v1",
  "domain": "pose",
  "version": "1.0.0"
}
```

---

## 수동 실행

```bash
cd ~/hdt-edge-student
source .venv/bin/activate
python server_student.py
```

포트: **8100** (`MCP_HOST=0.0.0.0`, `MCP_PORT=8100`)

```bash
sudo ufw allow 8100/tcp
```

---

## systemd

```bash
./install.sh --systemd
sudo systemctl status hdt-student
journalctl -u hdt-student -f
```

서비스는 `User=pi`, `WorkingDirectory`는 `install.sh`가 치환합니다.  
다른 사용자면 `systemd/hdt-student.service`의 `User=`를 수정한 뒤 재설치하세요.

---

## 디렉터리

```
hdt-edge-student/
├── install.sh           # Pi 원클릭 설치
├── server_student.py    # Empty MCP server
├── module_loader.py     # packages/ install/list/uninstall
├── packages/            # OTA 지식 패키지 (git 제외)
├── requirements.txt
├── .env.example
└── systemd/
    └── hdt-student.service
```
