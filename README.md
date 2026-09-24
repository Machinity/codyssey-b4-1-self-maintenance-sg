# B4-1. 컴퓨터가 알아서 자기 상태를 점검하게 만들기

> **실습 시나리오** — 여러분은 식당·병원·물류센터 등 **현장에 배치된 서비스 로봇**의 온디바이스 Ubuntu 22.04(Jammy Jellyfish)를 맡은 운영 엔지니어입니다.
> 로봇 위에서는 `agent-app` 이 돌고 있고, 원격으로만 관리할 수 있습니다.
> 여러분이 할 일은 이 로봇을 **안전하게 잠그고(SSH·방화벽·권한)**, **스스로 상태를 기록하게(monitor.sh + cron)** 만드는 것입니다.

이 저장소의 가이드를 **00번부터 순서대로** 따라가면 다음이 끝납니다.

- 미션의 모든 기능 요구사항 수행
- 제출물 2종: ① 요구사항 수행 내역서 ② `monitor.sh` 소스코드
- 과제 목표 6개를 "스스로 설명"할 수 있는 개념 학습
- 서비스 로봇 온디바이스 환경을 기준으로 한 **현업 보안 운영 방식** 학습

---

## 1. 로드맵

| 순서 | 가이드 | 하는 일 | 미션 요구사항 | 증거 파일 | 예상 시간 |
|---|---|---|---|---|---|
| 0 | [00_환경준비](guide/00_환경준비.md) | VM 설치, 저장소 복사, 작업 규칙 | 개발 환경 | `00_system.txt` | 1~2h |
| 1 | [01_SSH_보안설정](guide/01_SSH_보안설정.md) | 포트 20022, root 원격 로그인 차단 | 4-1 SSH | `01_ssh.txt` | 2~3h |
| 2 | [02_방화벽_UFW](guide/02_방화벽_UFW.md) | 20022/tcp, 15034/tcp 만 허용 | 4-1 방화벽 | `02_firewall.txt` | 2~3h |
| 3 | [03_계정과_그룹](guide/03_계정과_그룹.md) | agent-admin/dev/test, agent-common/core | 4-2 계정/그룹 | `03_accounts.txt` | 2h |
| 4 | [04_디렉토리_권한_ACL](guide/04_디렉토리_권한_ACL.md) | 공유/보안 디렉토리 분리, setgid, ACL | 4-2 디렉토리/권한 | `04_dirs_acl.txt` | 3~4h |
| 5 | [05_환경변수와_앱실행](guide/05_환경변수와_앱실행.md) | AGENT_* 환경 변수, 키 파일, Boot 5단계 | 4-3 앱 실행 | `05_env_app.txt`, `05_app_boot.txt` | 3~4h |
| 6 | [06_monitor_sh_구현](guide/06_monitor_sh_구현.md) | Health Check, 자원 수집, 경고, 로그, 로테이션 | 4-4 monitor.sh | `06_monitor_run.txt`, `07_monitor_log.txt` | 8~10h |
| 7 | [07_cron_자동화](guide/07_cron_자동화.md) | agent-admin crontab 매분 실행 | 4-5 cron | `08_cron.txt` | 2~3h |
| 8 | [08_보너스_리포트와_보존정책](guide/08_보너스_리포트와_보존정책.md) | report.sh, log_retention.sh | 5. 보너스 | `09_bonus.txt` | 4~6h |
| 9 | [09_제출물_정리](guide/09_제출물_정리.md) | 증거 일괄 수집, 수행 내역서 완성, 자기 점검 | 2. 최종 결과물 | 전체 | 2~3h |

**현업 심화(필수 아님, 강력 권장)** — 각 장 끝의 `🤖 현장 노트`와 함께 읽으세요.

| 문서 | 내용 |
|---|---|
| [F1_서비스로봇_위협모델](guide/field/F1_서비스로봇_위협모델.md) | 현장 로봇은 서버와 무엇이 다른가, 위협과 자산, 미션 항목 ↔ 현업 통제 매핑 |
| [F2_원격접속과_네트워크](guide/field/F2_원격접속과_네트워크.md) | 공개키 인증, VPN 뒤로 숨기기, 인터페이스별 방화벽, Docker·ROS 2 함정, 원격 변경 절차 |
| [F3_서비스운영_systemd_로그_시크릿](guide/field/F3_서비스운영_systemd_로그_시크릿.md) | systemd 서비스화·샌드박스, journald와 플래시 수명, 시크릿 관리, 업데이트 전략 |
| [F4_온디바이스_하드닝_체크리스트](guide/field/F4_온디바이스_하드닝_체크리스트.md) | 출하 전/현장 점검용 체크리스트 |

---

## 2. 저장소 구조

```
.
├── README.md                     ← 지금 읽는 문서 (로드맵)
├── b4-1_미션 - AI 도구 학습.pdf   ← 미션 원문
├── agent-app/                    ← 제공 앱 (PyInstaller 로 패키징된 실행 파일)
│   ├── agent-app-linux-x86         x86_64 VM 용
│   └── agent-app-linux-arm64       Apple Silicon(UTM) 등 aarch64 VM 용
├── guide/                        ← 단계별 가이드 (00 → 09)
│   └── field/                    ← 현업 심화 (서비스 로봇 온디바이스 보안)
├── scripts/                      ← 완성본 스크립트 (가이드에서 단계별로 직접 작성, 막히면 참고)
│   ├── monitor.sh                  ★ 제출물: 시스템 상태 수집·로깅
│   ├── report.sh                   보너스 1: 통계 리포트
│   ├── log_retention.sh            보너스 2: 압축/아카이브/삭제
│   └── collect_evidence.sh         제출용 증거 자동 수집
├── config/                       ← VM 에 설치할 설정 파일 원본
│   ├── ssh/10-agent-hardening.conf    → /etc/ssh/sshd_config.d/
│   ├── env/agent.env                  → /etc/agent-app/agent.env
│   ├── env/agent-app-profile.sh       → /etc/profile.d/agent-app.sh
│   ├── sudoers/agent-monitor          → /etc/sudoers.d/agent-monitor
│   ├── cron/agent-admin.crontab       → agent-admin 의 crontab
│   ├── logrotate/agent-app            → /etc/logrotate.d/ (비교 학습용, 선택)
│   └── systemd/agent-app.service      → /etc/systemd/system/ (현업 확장, 선택)
└── submission/                   ← 제출물
    ├── 수행내역서.md                ★ 제출물: 요구사항 수행 내역서 (템플릿을 채워 완성)
    └── evidence/                   증거 텍스트 (collect_evidence.sh 가 생성)
```

---

## 3. 최종 구성도 (완성 후 모습)

```
                 (현장 Wi-Fi / 사내망)
   운영자 PC ──── TCP 20022 (SSH) ────┐
   관제/클라이언트 ── TCP 15034 (APP) ─┤
   그 외 모든 인바운드 ──────── ✗ DROP │  UFW: default deny incoming
                                      ▼
 ┌──────────────────────── Ubuntu 22.04 (로봇 온디바이스) ────────────────────────┐
 │ sshd :20022  (PermitRootLogin no)                                            │
 │                                                                              │
 │ agent-admin ── 실행 ──▶ agent-app-linux-*  :15034  ── 로그 ─▶ /var/log/agent-app/│
 │     │                     ▲ 환경변수: /etc/agent-app/agent.env                 │
 │     │ crontab (* * * * *) │                                                  │
 │     └──▶ $AGENT_HOME/bin/monitor.sh (agent-dev:agent-core 750)               │
 │              ├ 프로세스·포트 Health Check (실패 시 exit 1)                      │
 │              ├ 방화벽 상태 (sudo 'ufw status' 만 허용)                          │
 │              ├ CPU / MEM / DISK 수집 + 임계값 경고                               │
 │              └ monitor.log 기록 (10MB × 10개 로테이션)                          │
 │                                                                              │
 │ $AGENT_HOME (/home/agent-admin/agent-app)                                    │
 │   ├ upload_files/  agent-common(admin·dev·test) R/W   ← 공유 디렉토리            │
 │   ├ api_keys/      agent-core(admin·dev)      R/W   ← 보안 디렉토리            │
 │   └ bin/           agent-dev 작성, agent-core 실행                              │
 └──────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 먼저 알아둘 것 — ⚠️ 명세와 실제 앱 동작의 차이

제공된 **x86 바이너리의 부팅 검사 로직을 분석**한 결과, 미션 PDF와 다른 점이 있습니다.

| 항목 | 미션 PDF | 실제 x86 앱이 검사하는 값 |
|---|---|---|
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys/t_secret.key` (파일) | `$AGENT_HOME/api_keys` (**디렉토리**) |
| 키 파일 이름 | `t_secret.key` | `secret.key` |
| 앱 프로세스 이름 | `agent_app.py` | `agent-app-linux` (실행 파일명, 15자로 잘림) |

arm64 바이너리는 내부 버전(`v2`)이 달라 명세와 일치할 수도 있습니다.
**가이드 05장은 먼저 명세대로 설정 → 실행 → 실패 메시지를 읽고 → 고치는 순서**로 진행하므로 어느 바이너리든 통과할 수 있습니다.
이 과정 자체가 현업에서 매우 흔한 "벤더 문서와 실제 동작이 다를 때" 대응 훈련이며, 수행 내역서에 **편차(Deviation)** 로 기록합니다.

---

## 5. 가이드 표기 규칙

| 표기 | 의미 |
|---|---|
| `mac$` | 내 PC(호스트) 터미널 |
| `ops@vm$` | VM 의 관리자 계정(설치 시 만든 sudo 사용자, 가이드에서는 `ops` 로 부름) |
| `agent-admin@vm$` 등 | `sudo -iu agent-admin` 으로 전환한 셸 |
| ✅ 체크포인트 | 여기서 기대 결과가 안 나오면 다음 단계로 가지 말 것 |
| 📝 수행 내역서 | `submission/수행내역서.md` 에 옮겨 적을 내용 |
| 🤖 현장 노트 | 서비스 로봇 현장에서는 어떻게 하는가 |
| 🧠 자기 점검 | 과제 목표 "스스로 설명하기" 대비 질문 |

> 명령어를 복사해 붙여넣기만 하지 말고, **실행 전에 "이 명령이 무엇을 바꾸는가"를 한 문장으로 말해본 뒤** 실행하세요.
> 현장 로봇에서는 잘못된 명령 하나가 "출동"(엔지니어 현장 방문)으로 이어집니다.
