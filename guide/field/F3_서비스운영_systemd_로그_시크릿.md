# F3. 서비스 운영 — systemd, 로그 저장소, 시크릿, 업데이트

> 🧪 = VM 에서 실습 가능, 📖 = 개념. 미션 제출을 **모두 마친 뒤** 진행하세요. (1장 실습은 앱 실행 방식을 바꿉니다.)

---

## 1. 🧪 tmux 대신 systemd 서비스로 앱 운영하기

05장에서는 tmux 안에서 앱을 띄웠습니다. 현장 로봇에서는 이렇게 하지 않습니다.

| | tmux 수동 실행 | systemd 서비스 |
|---|---|---|
| 재부팅 후 | 사람이 다시 띄워야 함 | 자동 시작 |
| 앱이 죽으면 | 죽은 채로 방치 | **자동 재시작** |
| 로그 | 터미널 스크롤 | `journalctl -u` 로 수집·보존 |
| 환경 변수 | 로그인 셸에 의존 | `EnvironmentFile=` 로 명시 |
| 보안 | 사용자 권한 그대로 | **샌드박스**(파일시스템 읽기 전용, 권한 상승 금지 등) |
| 자원 제한 | 없음 | `MemoryMax=`, `CPUQuota=` |

### 1-1. 설치

```bash
# tmux 의 앱을 먼저 종료 (포트 15034 충돌 방지)
ops@vm$ tmux attach -t agent        # Ctrl+C → exit → exit

ops@vm$ sudo install -m 644 $REPO/config/systemd/agent-app.service /etc/systemd/system/
ops@vm$ sudo sed -i "s|agent-app-linux-x86|$APP_BIN|" /etc/systemd/system/agent-app.service
ops@vm$ grep ExecStart /etc/systemd/system/agent-app.service

ops@vm$ sudo systemctl daemon-reload
ops@vm$ sudo systemctl enable --now agent-app
ops@vm$ systemctl status agent-app --no-pager
ops@vm$ journalctl -u agent-app -n 30 --no-pager      # Boot Sequence 5단계가 journald 에 기록됨
```

unit 파일의 주요 항목은 [`config/systemd/agent-app.service`](../../config/systemd/agent-app.service) 주석을 참고하세요. 핵심만 보면:

```ini
User=agent-admin                          # 일반 계정으로 실행 (root 금지)
EnvironmentFile=/etc/agent-app/agent.env  # 05장의 단일 환경 파일 재사용
Restart=on-failure                        # 비정상 종료 시 재시작
NoNewPrivileges=yes                       # setuid 등으로 권한 상승 불가
ProtectSystem=strict                      # / 전체를 읽기 전용으로
ReadWritePaths=/var/log/agent-app ...     # 쓰기가 필요한 곳만 예외
MemoryMax=512M                            # 폭주해도 로봇 전체 메모리를 잡아먹지 못함
```

### 1-2. 자동 복구 확인

```bash
ops@vm$ sudo systemctl kill -s KILL agent-app       # 앱을 강제로 죽인다 (크래시 흉내)
ops@vm$ sleep 7; systemctl status agent-app --no-pager | head -n 5
# Active: active (running) since ... 몇 초 전    ← 5초 후 스스로 다시 떴다
ops@vm$ sudo tail -n 5 /var/log/agent-app/monitor.log   # 그 사이 monitor.sh 가 [ERROR] 를 남겼을 수도
```

monitor.sh 는 프로세스 이름(`agent-app-linux`)으로 찾기 때문에 **수정 없이 그대로 동작**합니다.

### 1-3. 보안 점수 확인

```bash
ops@vm$ systemd-analyze security agent-app
# → Overall exposure level for agent-app.service: 4.x MEDIUM
```

항목별로 무엇이 열려 있는지 보여줍니다. unit 에 `ProtectKernelLogs=yes`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service` 등을 더하며 점수를 낮춰 보세요. (하나씩 추가하고 앱이 정상 부팅하는지 확인 — **샌드박스는 과하면 앱이 죽습니다.**)

### 1-4. 원래대로 되돌리기

```bash
ops@vm$ sudo systemctl disable --now agent-app
# 다시 05장 방식(tmux)으로 실행
```

📖 **로봇에서의 자원 격리** — 이 앱처럼 CPU/메모리를 많이 쓰는 부가 기능이 **주행 제어 루프**를 굶기면 로봇이 멈칫하거나 충돌할 수 있습니다. 현장에서는 `Nice=`, `CPUQuota=`, `CPUAffinity=`(제어 루프와 다른 코어에 배치), `MemoryMax=` 로 격리하고, 제어 프로세스는 실시간(RT) 우선순위를 줍니다.

---

## 2. 📖🧪 로그 저장소 — 플래시 수명과 디스크 가득 참

로봇은 SSD 대신 **eMMC, SD 카드** 같은 플래시를 많이 씁니다. 플래시는 **쓰기 횟수에 수명이 있어서**, 매초 로그를 쓰면 수년 안에 저장장치가 고장 납니다.

| 대책 | 방법 |
|---|---|
| journald 크기 상한 | 아래 🧪 |
| 불필요한 쓰기 줄이기 | 마운트 옵션 `noatime`(읽을 때마다 접근 시각 기록 안 함) |
| 자주 쓰는 로그는 RAM 에 | `tmpfs` 에 쓰고 주기적으로 요약/압축만 저장 (예: log2ram) |
| 로그 레벨 관리 | 운영 중 DEBUG 로그 끄기 |
| 중앙 전송 | 로봇에는 짧게, 중앙에는 길게 보관 |

🧪 journald 크기 제한:

```bash
ops@vm$ journalctl --disk-usage
ops@vm$ sudo mkdir -p /etc/systemd/journald.conf.d
ops@vm$ sudo tee /etc/systemd/journald.conf.d/robot.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemKeepFree=1G
MaxRetentionSec=1month
EOF
ops@vm$ sudo systemctl restart systemd-journald
ops@vm$ journalctl --disk-usage
```

> 07장에서 cron 출력을 `logger` 로 journald 에 보낸 이유가 여기서 완성됩니다. **한 곳(journald)의 정책**으로 크기·보존 기간을 통제할 수 있습니다.

---

## 3. 📖 시크릿(비밀 값) 관리

이 미션의 `api_keys/` 는 "파일 권한으로 보호된 평문 키"입니다. 현장에서는 여기에 여러 겹을 더합니다.

| 단계 | 방법 | 막는 것 |
|---|---|---|
| 1. 파일 권한 | `0440`, 전용 그룹 (04장) | 같은 기기의 다른 사용자 |
| 2. 기기별 키 | 로봇마다 다른 키/인증서 발급 | 한 대 탈취 → 전체 플릿 피해 |
| 3. 짧은 수명 + 교체 | 키 유효기간, 자동 교체(rotation) | 유출된 키의 장기 악용 |
| 4. 디스크 암호화 | LUKS + TPM 자동 잠금 해제 (`systemd-cryptenroll --tpm2-device=auto`) | **로봇 도난** 후 디스크 분리 |
| 5. 하드웨어 보관 | TPM/보안칩 안에 개인키 (밖으로 못 꺼냄) | 파일 복사 자체 |
| 6. 서비스 전용 전달 | systemd `LoadCredential=` → 서비스만 볼 수 있는 임시 경로에 키 제공 | 다른 프로세스·사용자의 접근 |

**하지 말아야 할 것**
- 키를 **명령줄 인자**로 전달 (`ps` 로 모두에게 보임)
- 키 **값**을 환경 변수로 전달 (`/proc/<PID>/environ`, 크래시 덤프)
- 키를 **셸 히스토리·로그·지원 티켓**에 남김 (05장 현장 노트, 09장 6절)
- 키를 **Git 저장소**에 커밋 (한 번 커밋되면 히스토리에 영원히 남음 → 키 폐기가 유일한 해결책)

---

## 4. 📖 업데이트 전략

| 과제 | 현장 방식 |
|---|---|
| 보안 패치는 빨리 | `unattended-upgrades` 로 **보안 업데이트만** 자동 적용 |
| 영업 중 재부팅 금지 | `Automatic-Reboot "false"`, 재부팅은 **충전 도킹 중·영업 종료 후** 유지보수 창에서 |
| 업데이트 실패 = 벽돌 | **A/B 파티션 OTA**(Mender, RAUC, SWUpdate 등): 새 파티션에 설치 → 부팅 실패 시 이전 파티션으로 자동 복귀 |
| 수천 대 동시 업데이트 | 단계적 배포(카나리), 사내 패키지 미러, 버전 고정 |
| 재부팅 없이 커널 패치 | Canonical Livepatch (Ubuntu Pro) |

```bash
# 참고: 현재 자동 업데이트 설정 확인
cat /etc/apt/apt.conf.d/20auto-upgrades
systemctl list-timers apt-daily-upgrade.timer
```

---

## 5. 📖 워치독(Watchdog)

- **소프트웨어**: systemd `Restart=` 는 "죽은 것"은 살리지만 **"멈춘(hang) 것"** 은 모릅니다. 앱이 `sd_notify("WATCHDOG=1")` 로 주기적 신호를 보내게 하고 `WatchdogSec=` 를 설정하면, 신호가 끊겼을 때 재시작합니다. — 06장 monitor.sh 의 "프로세스는 있는데 포트가 닫힘" 검사가 바로 hang 탐지의 한 형태입니다.
- **하드웨어**: OS 전체가 멈추면 소프트웨어는 아무것도 못 합니다. 보드의 하드웨어 워치독에 systemd 가 주기적으로 신호를 주게 하면(`/etc/systemd/system.conf` 의 `RuntimeWatchdogSec=`), OS 가 멈췄을 때 보드가 **강제 재부팅**합니다. 무인 로봇에서는 거의 필수입니다.

---

## 🧠 생각해 볼 질문

1. `Restart=on-failure` 만으로는 부족하고 monitor.sh 같은 외부 감시가 여전히 필요한 이유는?
2. SD 카드를 쓰는 로봇에서 monitor.log 를 매초 기록하도록 바꾸면 어떤 문제가 생기는가?
3. 로봇 한 대를 도난당했다. 이 미션의 설정만으로는 API 키를 보호할 수 없는 이유와, 필요한 추가 조치는?

⬅️ 이전: [F2_원격접속과_네트워크](F2_원격접속과_네트워크.md) | ➡️ 다음: [F4_온디바이스_하드닝_체크리스트](F4_온디바이스_하드닝_체크리스트.md)
