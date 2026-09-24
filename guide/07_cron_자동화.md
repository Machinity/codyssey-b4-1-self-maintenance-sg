# 07. cron 자동화 — 매분 스스로 점검하게 만들기

## 이 장의 목표

| 미션 요구사항 | 확인 방법 |
|---|---|
| **agent-admin 의 crontab** 에 monitor.sh 를 **매분** 실행 등록 | `crontab -l -u agent-admin` |
| 등록 후 1~2분 내 monitor.log 에 새 줄이 **자동으로** 쌓임 | 전/후 `wc -l`, `tail` |

그리고 다음을 **설명할 수 있어야** 합니다.
> crontab 으로 모니터링을 주기 실행시키고, 로그 보존 정책(압축/삭제)이 왜 필요한가?

---

## 1. 개념

### 1-1. cron 의 구조

```
 cron 데몬 (systemd: cron.service)
   │ 매분 0초에 깨어나서
   ├─ /etc/crontab, /etc/cron.d/*          ← 시스템 작업 (실행 계정을 줄마다 지정)
   └─ /var/spool/cron/crontabs/<사용자>     ← 사용자별 crontab (그 사용자 권한으로 실행)
         ↑ 직접 편집 금지! 반드시 `crontab` 명령으로
```

미션은 **사용자 crontab** 을 요구합니다 → `agent-admin` 의 권한으로 실행됩니다.

### 1-2. 시간 필드

```
┌───────── 분 (0-59)
│ ┌─────── 시 (0-23)
│ │ ┌───── 일 (1-31)
│ │ │ ┌─── 월 (1-12)
│ │ │ │ ┌─ 요일 (0-7, 0과 7은 일요일)
│ │ │ │ │
* * * * *   명령
```

| 표현 | 의미 |
|---|---|
| `* * * * *` | **매분** |
| `*/5 * * * *` | 5분마다 |
| `0 * * * *` | 매시 정각 |
| `10 3 * * *` | 매일 03:10 |
| `0 9 * * 1-5` | 평일 09:00 |

> https://crontab.guru 에서 표현식을 사람 말로 확인할 수 있습니다.

### 1-3. cron 은 "텅 빈 환경"에서 실행된다 ⚠️

cron 작업은 로그인 셸이 아닙니다. 그래서:

| 항목 | 로그인 셸 | cron |
|---|---|---|
| `PATH` | `/usr/local/sbin:...:/usr/sbin:...` | **`/usr/bin:/bin`** 만 |
| `AGENT_*` (profile.d) | 있음 | **없음** |
| 현재 디렉토리 | 작업 위치 | 홈 디렉토리 |
| 출력(stdout/stderr) | 화면 | **메일로 발송 시도** (MTA 없으면 버려짐) |

"터미널에서는 되는데 cron 에서는 안 돼요" 의 거의 모든 원인이 이 표에 있습니다. 06장에서 monitor.sh 가 **스스로** PATH 와 환경 파일을 설정하도록 만든 이유입니다.

### 1-4. cron 출력은 어디로 보낼까

| 방법 | 평가 |
|---|---|
| 그대로 둠 | 메일 서버가 없으면 **사라짐**. 경고를 아무도 못 봄 |
| `>/dev/null 2>&1` | 명시적으로 버림. 조용하지만 디버깅 불가 |
| `>> 파일.log 2>&1` | 크기 제한이 없으면 **또 하나의 무한 증가 로그** |
| **`2>&1 \| logger -t agent-monitor`** | ✅ syslog/journald 로 → 시스템 로그 정책(크기·보존)을 그대로 따름, `journalctl -t` 로 조회 |

monitor.log(측정 기록)와 콘솔 출력(경고 메시지)을 **분리해서 각자 알맞은 곳**에 남기는 설계입니다.

### 1-5. 왜 로그 보존 정책이 필요한가

매분 1줄이면 하루 1,440줄, 1년이면 50만 줄입니다. 앱 로그·시스템 로그까지 합치면 디스크는 결국 가득 찹니다.

| 정책 | 목적 |
|---|---|
| **크기 제한/회전** (06장, 10MB × 10) | 파일 하나가 무한히 커지지 않게 |
| **압축** (보너스 2, 7일) | 오래된 로그는 자주 안 보므로 공간 절약 (텍스트 로그는 보통 90% 이상 줄어듦) |
| **삭제** (보너스 2, 30일) | 보존 기간이 지난 로그 제거 — 디스크 보호 + **개인정보/보안상 불필요한 데이터 최소 보유** |

"얼마나 보관하나"는 기술 문제가 아니라 **정책** 문제입니다(장애 분석 필요 기간, 법적 보존 의무, 저장 용량).

---

## 2. 실습

### 2-1. cron 서비스 확인

```bash
ops@vm$ systemctl is-active cron        # active
ops@vm$ systemctl is-enabled cron       # enabled (부팅 시 자동 시작)
```

### 2-2. cron 과 같은 환경으로 미리 테스트 (가장 중요한 습관)

```bash
# env -i : 환경 변수를 모두 비움 / PATH 만 cron 과 똑같이
ops@vm$ sudo -u agent-admin env -i PATH=/usr/bin:/bin HOME=/home/agent-admin SHELL=/bin/sh \
          /home/agent-admin/agent-app/bin/monitor.sh; echo "exit=$?"
```

✅ 체크포인트: 06장 T1 과 같은 결과(`exit=0`). 여기서 실패하면 cron 에서도 실패합니다.

### 2-3. crontab 등록

**방법 1 — 편집기로 직접 (권장: 형식을 익히기 위해)**

```bash
ops@vm$ sudo crontab -u agent-admin -e
# 처음이면 편집기 선택 → 1 (nano)
```

맨 아래에 추가:

```
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

* * * * * /home/agent-admin/agent-app/bin/monitor.sh 2>&1 | /usr/bin/logger -t agent-monitor
```

**방법 2 — 파일로 설치 (현업 방식: 설정을 코드로 관리)**

```bash
ops@vm$ sudo crontab -u agent-admin $REPO/config/cron/agent-admin.crontab
```

> ⚠️ 방법 2 는 agent-admin 의 기존 crontab 을 **통째로 교체**합니다. 기존 내용이 있다면 먼저 `sudo crontab -u agent-admin -l` 로 확인하세요.

> **주의할 점**
> - 명령은 **절대 경로**로. (`~` , `$AGENT_HOME` 은 cron 에서 기대대로 펼쳐지지 않을 수 있음)
> - crontab 안에서 `%` 는 특수 문자(줄바꿈)입니다. `date +%F` 같은 명령을 넣으려면 `\%` 로 이스케이프해야 합니다. — monitor.sh 안에서 날짜를 만드는 이유 중 하나.
> - 파일 마지막 줄 뒤에 **줄바꿈**이 있어야 합니다. 없으면 마지막 줄이 무시될 수 있습니다.

### 2-4. 등록 확인

```bash
ops@vm$ sudo crontab -u agent-admin -l
ops@vm$ sudo ls -l /var/spool/cron/crontabs/
# -rw------- 1 agent-admin crontab ... agent-admin
```

### 2-5. 자동 실행 확인 — "1분 후 로그 증가"

```bash
ops@vm$ date '+%T'; sudo wc -l /var/log/agent-app/monitor.log
# 14:10:25
# 42 /var/log/agent-app/monitor.log

# 1~2분 기다린 뒤
ops@vm$ date '+%T'; sudo wc -l /var/log/agent-app/monitor.log
# 14:12:03
# 44 /var/log/agent-app/monitor.log        ← 사람이 실행하지 않았는데 증가

ops@vm$ sudo tail -n 3 /var/log/agent-app/monitor.log
# [2026-09-23 14:11:01] PID:5012 CPU:18.2% MEM:11.9% DISK_USED:23%
# [2026-09-23 14:12:01] PID:5012 CPU:27.5% MEM:12.3% DISK_USED:23%
#          ↑ 매분 01초 전후 (cron 은 0초에 시작, CPU 측정에 1초 소요)
```

실시간으로 보고 싶다면:

```bash
ops@vm$ sudo tail -f /var/log/agent-app/monitor.log      # Ctrl+C 로 종료
```

✅ 체크포인트: 사람이 실행하지 않아도 **매분 한 줄씩** 늘어난다. 📸 스크린샷 (전/후 `wc -l` + `tail`).

### 2-6. cron 실행 기록과 콘솔 출력 확인

```bash
# cron 이 명령을 실행했다는 기록
ops@vm$ sudo journalctl -t CRON --since "5 min ago" --no-pager | grep agent-admin
# ... CRON[6120]: (agent-admin) CMD (/home/agent-admin/agent-app/bin/monitor.sh 2>&1 | /usr/bin/logger -t agent-monitor)

# monitor.sh 의 콘솔 출력(경고 포함) — logger 로 보낸 것
ops@vm$ journalctl -t agent-monitor --since "5 min ago" --no-pager | tail -n 15
ops@vm$ journalctl -t agent-monitor --since today | grep -c WARNING      # 오늘 경고 횟수
```

> `ops` 가 sudo 없이 `journalctl -t agent-monitor` 를 볼 수 있는 이유: Ubuntu 기본 사용자는 `adm` 그룹이라 시스템 로그 열람 권한이 있습니다. (`id ops` 로 확인)

### 2-7. 장애 시나리오 확인 — cron 이 장애를 기록하는가

```bash
# 앱을 Ctrl+C 로 종료하고 (tmux attach -t agent → Ctrl+C → Ctrl+b d) 2분 기다린 뒤
ops@vm$ sudo tail -n 3 /var/log/agent-app/monitor.log
# [2026-09-23 14:20:01] [ERROR] Process 'agent-app-linux' is not running
# [2026-09-23 14:21:01] [ERROR] Process 'agent-app-linux' is not running
ops@vm$ journalctl -t agent-monitor --since "3 min ago" --no-pager | grep FAIL
```

**앱을 다시 실행**합니다. 로그만 봐도 "14:19~14:21 사이 앱 중단"을 알 수 있습니다. 이것이 미션 소개의 "로그가 없으면 원인 분석은 감에 의존" 의 반대 상황입니다.

---

## 3. 트러블슈팅 — cron 이 안 돌 때 체크 순서

| 순서 | 확인 | 명령 |
|---|---|---|
| 1 | cron 데몬이 도는가 | `systemctl status cron` |
| 2 | cron 이 명령을 실행했는가 | `journalctl -t CRON --since "5 min ago"` |
| 3 | 실행은 됐는데 실패했는가 | `journalctl -t agent-monitor --since "5 min ago"` |
| 4 | cron 환경에서 재현되는가 | 2-2 의 `env -i` 명령 |
| 5 | 권한 | `sudo -u agent-admin test -x /home/agent-admin/agent-app/bin/monitor.sh && echo OK` |
| 6 | 줄바꿈 | `crontab -l` 마지막 줄 뒤 개행, 스크립트 CRLF |

| 흔한 증상 | 원인 |
|---|---|
| `CMD` 기록은 있는데 로그가 안 늘어남 | 스크립트 내부 실패 → 3번 |
| `(CRON) info (No MTA installed, discarding output)` | 출력 처리 안 함 → `\| logger` 추가 |
| `command not found` | PATH → 절대 경로 사용 / 스크립트 안에서 PATH 설정 |
| 시각이 9시간 차이 | 00장 timezone 설정 후 `sudo systemctl restart cron` |

---

## 🤖 현장 노트 — 로봇의 주기 작업

1. **systemd timer 가 현대적 대안** — cron 대신 `.timer` 유닛을 쓰면 실행 결과가 `journalctl -u` 로 자동 수집되고, `Persistent=true` 로 로봇이 꺼져 있던 동안 놓친 작업을 부팅 후 실행하며, `RandomizedDelaySec` 으로 수백 대 로봇이 **같은 순간에 서버를 두드리는 것(thundering herd)** 을 막을 수 있습니다.
   ```ini
   # /etc/systemd/system/agent-monitor.timer (예시)
   [Timer]
   OnCalendar=*-*-* *:*:00
   AccuracySec=1s
   Persistent=true
   ```
2. **모니터링 작업 자체의 부하** — 매분 실행되는 스크립트가 무거우면 로봇 성능을 갉아먹습니다. monitor.sh 는 1초 sleep 외에는 가벼운 명령만 씁니다. 현장에서는 모니터링 작업에 `nice`, `ionice` 를 걸기도 합니다.
3. **주기와 보존의 계산** — "몇 초마다, 몇 줄씩, 며칠 보관"은 곧 **디스크 사용량 계산**입니다. 플래시 저장장치(eMMC/SD)를 쓰는 로봇은 쓰기량이 곧 수명이므로, 로그를 RAM(`tmpfs`)에 쓰고 주기적으로 요약만 영구 저장하는 설계도 흔합니다. ([F3](field/F3_서비스운영_systemd_로그_시크릿.md))
4. **크론 등록 권한 제한** — `/etc/cron.allow` 에 허용 사용자만 적으면 나머지는 crontab 을 만들 수 없습니다. 공격자가 탈취한 계정으로 **지속성(persistence)** 을 확보하는 대표 수단이 cron 이므로, 현장 로봇은 cron 사용자를 제한하고 crontab 변경을 감사합니다.

---

## 📝 수행 내역서에 기록할 것

- `crontab -l -u agent-admin` 출력 + 각 필드 설명
- 출력 처리 방식(`logger`)을 선택한 이유
- 증거: 1~2분 간격 `wc -l` 증가 + `tail` (시각 포함)
- 증거: `journalctl -t CRON` 실행 기록
- (선택) 2-7 장애 기록 결과

## 🧠 자기 점검

1. `* * * * *` 와 `*/5 * * * *` 의 차이는?
2. 터미널에서는 잘 되던 스크립트가 cron 에서 실패하는 대표적인 이유 세 가지는?
3. cron 작업이 "실행되었는지"와 "성공했는지"를 각각 어떻게 확인하는가?
4. cron 출력을 파일에 `>>` 로 쌓는 대신 `logger` 로 보낸 이유는?
5. 로그 보존 정책(회전·압축·삭제)이 없으면 어떤 일이 일어나는가? 각각의 목적은?

⬅️ 이전: [06_monitor_sh_구현](06_monitor_sh_구현.md) | ➡️ 다음: [08_보너스_리포트와_보존정책](08_보너스_리포트와_보존정책.md)
