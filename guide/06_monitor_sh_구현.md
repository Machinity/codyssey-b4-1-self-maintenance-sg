# 06. monitor.sh 구현 — 시스템이 스스로 상태를 기록하게 만들기

## 이 장의 목표

| 미션 요구사항 | 구현 위치(완성본 [`scripts/monitor.sh`](../scripts/monitor.sh)) |
|---|---|
| 경로 `$AGENT_HOME/bin/monitor.sh`, 소유 `agent-dev:agent-core`, 권한 `750` | 3-8 설치 |
| **Health Check**: 앱 프로세스 확인, 비정상 시 `exit 1` | 2단계 |
| **Health Check**: TCP 15034 LISTEN 확인, 비정상 시 `exit 1` | 2단계 |
| 방화벽 활성 점검, 비활성이면 `[WARNING]` (종료 안 함) | 3단계 |
| CPU / MEM / DISK(/) 사용률 수집 | 4단계 |
| CPU > 20%, MEM > 10%, DISK > 80% 시 `[WARNING]` | 5단계 |
| `/var/log/agent-app/monitor.log` 에 `[YYYY-MM-DD HH:MM:SS] PID:.. CPU:..% MEM:..% DISK_USED:..%` | 7단계 |
| 최대 10MB / 10개 파일 유지 | 6단계 |
| **Bash 로만** 작성 | 전체 |

그리고 다음을 **설명할 수 있어야** 합니다.
> 쉘 스크립트로 프로세스/포트/리소스 상태를 수집하고, 로그로 남겨 운영 문제를 추적하는 흐름은?

---

## 1. 개념

### 1-1. 헬스 체크, 모니터링, 경보의 차이

| 구분 | 질문 | 실패 시 | monitor.sh 에서 |
|---|---|---|---|
| **Health Check** | "살아 있나?" (Yes/No) | 즉시 조치 필요 → **비정상 종료(exit 1)** | 프로세스, 포트 |
| **상태 점검** | "설정이 올바른가?" | 경고, 계속 진행 | 방화벽 |
| **Metric 수집** | "얼마나 쓰고 있나?" (숫자) | 없음, 기록 | CPU/MEM/DISK |
| **임계값 경고** | "위험 수준인가?" | 경고, 계속 진행 | > 20/10/80% |

왜 방화벽·자원 경고는 종료하지 않나? **수집이 멈추면 기록이 끊기기 때문**입니다. 장애 순간의 자원 사용량이야말로 나중에 원인을 밝히는 데 가장 필요한 데이터입니다.

### 1-2. 종료 코드(exit code) — 자동화 도구와의 약속

```bash
$ ./monitor.sh; echo $?
```

| 코드 | 의미 (이 스크립트의 약속) |
|---|---|
| `0` | 정상 (경고가 있어도 0) |
| `1` | Health Check 실패 |
| `2` | 실행 환경 오류 (로그 디렉토리 없음/권한 없음 등) |

사람은 출력을 읽지만 **cron, systemd, CI, 관제 에이전트는 종료 코드만 봅니다.** 의미 있는 종료 코드를 정하고 문서화하는 것이 자동화의 기본입니다.

### 1-3. /proc — 커널이 보여주는 실시간 상태

`/proc` 은 디스크에 있는 파일이 아니라 **커널이 읽는 순간 만들어 주는 가상 파일**입니다. `top`, `free`, `ps` 도 결국 여기를 읽습니다.

**CPU 사용률** — `/proc/stat` 의 첫 줄은 부팅 이후 누적된 CPU 시간(단위: jiffies)입니다.

```
cpu  user  nice system  idle   iowait irq softirq steal guest guest_nice
cpu  4705  150  1120    16250  520    0   30      0     0     0
```

누적값이므로 **한 번만 읽으면 "부팅 이후 평균"** 이 됩니다. 현재 사용률을 알려면 **시간 간격을 두고 두 번 읽어 차이**를 봅니다.

```
Δtotal = total₂ − total₁        (user~steal 합)
Δidle  = idle₂  − idle₁         (idle + iowait)
CPU%   = (1 − Δidle / Δtotal) × 100
```

예) 1초 동안 Δtotal=200, Δidle=150 → (1 − 150/200) × 100 = **25.0%**

> `guest`, `guest_nice` 는 이미 `user`, `nice` 에 포함된 값이라 더하면 중복입니다. 그래서 2~9번째 필드만 합산합니다.

**메모리 사용률** — `/proc/meminfo`

```
MemTotal:        2014124 kB
MemFree:          120340 kB     ← 정말 아무도 안 쓰는 메모리
MemAvailable:    1450220 kB     ← 캐시 회수까지 고려해 "지금 쓸 수 있는" 메모리
```

리눅스는 남는 메모리를 디스크 캐시로 씁니다. `MemFree` 기준으로 계산하면 멀쩡한 시스템도 "90% 사용 중"으로 보입니다. 그래서 **`(MemTotal − MemAvailable) / MemTotal`** 을 씁니다.

**디스크 사용률** — `df -P /`

`-P`(POSIX 형식)는 장치 이름이 길어도 **한 줄로 출력**되도록 보장합니다. 스크립트에서 파싱할 출력은 항상 형식이 고정된 옵션을 씁니다.

### 1-4. 프로세스와 포트 확인 도구

| 목적 | 명령 | 포인트 |
|---|---|---|
| 프로세스 찾기 | `pgrep -x 이름` | `-x` 이름 **정확히** 일치, `-n` 가장 최근 것 |
| | `pgrep -f 패턴` | 전체 명령줄 검색 → `sudo ./agent-app...`, `vim agent-app...` 도 걸림 ❌ |
| 포트 LISTEN | `ss -Htln 'sport = :15034'` | `-H` 헤더 제거 → 출력이 있으면 LISTEN, 없으면 아님 |

> 05장에서 본 것처럼 앱 프로세스 이름은 `agent-app-linux`(15자 제한)이고 2개(부모/자식)가 뜹니다. `pgrep -n -x agent-app-linux` 는 **가장 최근에 뜬 자식(실제 앱)** 의 PID를 줍니다.

### 1-5. Bash 에서 실수(소수) 다루기

Bash 산술 `$(( ))` 는 **정수만** 됩니다. `(( 25.3 > 20 ))` 은 문법 오류입니다. 그래서 계산·비교는 `awk` 에 맡깁니다(awk 는 POSIX 표준 도구이므로 "Bash 로만 작성" 제약에 위배되지 않습니다. Python 등 다른 언어 런타임으로 대체하지 않는 것이 요점입니다).

```bash
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
if gt 25.3 20; then echo "초과"; fi
```

### 1-6. 방화벽 상태 확인과 sudo 최소 권한

`ufw status` 는 **root 만** 실행할 수 있습니다. cron 으로 도는 `agent-admin` 은 root 가 아닙니다. 선택지는:

| 방법 | 평가 |
|---|---|
| monitor.sh 를 root crontab 으로 실행 | ❌ 미션 요구(agent-admin) 위반, 스크립트 전체가 root 권한 |
| agent-admin 을 sudo 그룹에 추가 | ❌ 모든 명령을 root 로 실행 가능 — 과잉 권한 |
| **sudoers 에 `ufw status` 한 줄만 허용** | ✅ 딱 필요한 명령, 필요한 인자만 |

```
%agent-core ALL=(root) NOPASSWD: /usr/sbin/ufw status
```

인자까지 `status` 로 고정했기 때문에 `sudo ufw disable` 은 **불가능**합니다.

### 1-7. 로그 설계

```
[2026-09-23 14:00:01] PID:5012 CPU:25.3% MEM:12.4% DISK_USED:23%
```

- **시각이 맨 앞 + 정렬 가능한 형식**(`YYYY-MM-DD HH:MM:SS`) → 문자열 정렬 = 시간 정렬, `grep '2026-09-23 14:'` 로 시간대 추출
- **한 줄 = 한 측정** + **`키:값`** → `awk`, `grep` 으로 바로 분석 (보너스 report.sh)
- 콘솔 출력(사람용)과 로그(기계용)를 **분리**

### 1-8. 로그 회전(rotation)과 동시 실행

```
10MB 초과 시:  monitor.log.8 → .9 (기존 .9 삭제)
              ...
              monitor.log.1 → .2
              monitor.log   → .1
              (새 monitor.log 생성)       ⇒ 최대 10개 = 100MB 상한
```

cron 의 매분 실행과 사람이 수동으로 돌린 실행이 **동시에 회전을 시작하면** 파일이 꼬입니다. `flock` 으로 한 번에 하나만 실행되도록 **잠금(lock)** 을 겁니다.

### 1-9. 스크립트 안전장치

| 설정 | 의미 |
|---|---|
| `set -u` | 정의되지 않은 변수를 쓰면 즉시 에러 (오타 방지) |
| `set -o pipefail` | 파이프 중간 명령 실패도 실패로 취급 |
| (`set -e` 는 쓰지 않음) | `grep` 이 "못 찾음"으로 1을 반환하는 것처럼 **정상적인 실패**가 많아 오히려 예측이 어려워짐. 대신 중요한 지점에서 명시적으로 검사 |
| `export PATH=...` | cron 의 PATH 는 `/usr/bin:/bin` 뿐 → `ss`, `ufw`(/usr/sbin)를 못 찾는 사고 방지 |
| `export LC_ALL=C` | 로케일에 따라 소수점이 `,` 로 나오는 등의 차이 제거 |

---

## 2. 사전 준비 — sudoers (ops 계정)

```bash
# 1) 문법 검사 먼저 (문법이 틀린 sudoers 파일은 sudo 전체를 마비시킨다)
ops@vm$ sudo visudo -cf $REPO/config/sudoers/agent-monitor
# .../agent-monitor: parsed OK

# 2) 설치 (0440, root 소유여야 sudo 가 읽는다)
ops@vm$ sudo install -m 440 -o root -g root $REPO/config/sudoers/agent-monitor /etc/sudoers.d/agent-monitor
ops@vm$ sudo visudo -c

# 3) 허용된 것은 되고
ops@vm$ sudo -u agent-admin sudo -n /usr/sbin/ufw status | head -n 1
# Status: active
# 4) 허용되지 않은 것은 안 된다
ops@vm$ sudo -u agent-admin sudo -n /usr/sbin/ufw disable
# sudo: a password is required        ← 거부됨 (정상)
ops@vm$ sudo -u agent-test sudo -n /usr/sbin/ufw status
# sudo: a password is required        ← agent-core 가 아니므로 거부 (정상)
```

> 직접 편집한다면 반드시 `sudo visudo -f /etc/sudoers.d/agent-monitor` 를 쓰세요. 저장 시 문법 검사를 해줍니다.

✅ 체크포인트: 3) 성공, 4) 두 줄 모두 거부.

---

## 3. 단계별 작성 (agent-dev 계정)

monitor.sh 의 작성자는 `agent-dev` 입니다. 단계마다 **작성 → 실행 → 결과 확인**을 반복합니다.

```bash
ops@vm$ sudo -iu agent-dev
agent-dev@vm$ cd "$AGENT_HOME/bin"
agent-dev@vm$ nano monitor.sh          # vim 이 익숙하면 vim
```

테스트 실행은 두 가지로 합니다.

```bash
agent-dev@vm$ bash monitor.sh; echo "exit=$?"                     # 작성자 본인이 빠르게
ops@vm$ sudo -u agent-admin $AH/bin/monitor.sh; echo "exit=$?"     # 실제 cron 실행자로
```

### 3-1. 1단계 — 뼈대: 실행 환경 고정

```bash
#!/usr/bin/env bash
#
# monitor.sh - agent-app 시스템 상태 수집 및 로깅 스크립트
#   종료 코드: 0 정상 / 1 Health Check 실패 / 2 실행 환경 오류
#
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

# cron 에는 AGENT_* 가 없다 → 공용 환경 파일을 직접 읽고, 없으면 기본값
ENV_FILE="/etc/agent-app/agent.env"
if [[ -r "$ENV_FILE" ]]; then
    set -a            # 이후 정의되는 변수를 자동 export
    . "$ENV_FILE"
    set +a
fi

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
APP_PROC_NAME="${APP_PROC_NAME:-agent-app-linux}"

LOG_FILE="${AGENT_LOG_DIR}/monitor.log"

echo "AGENT_HOME=$AGENT_HOME PORT=$AGENT_PORT LOG=$LOG_FILE"   # 확인용, 다음 단계에서 삭제
```

```bash
agent-dev@vm$ bash monitor.sh
# AGENT_HOME=/home/agent-admin/agent-app PORT=15034 LOG=/var/log/agent-app/monitor.log

# cron 과 같은 "텅 빈 환경"에서도 같은 결과가 나오는지 (env -i = 환경 변수 전부 제거)
agent-dev@vm$ env -i /bin/bash monitor.sh
```

✅ 두 결과가 같아야 합니다. 이 `env -i` 테스트는 07장 cron 디버깅의 핵심 도구입니다.

> `${VAR:-기본값}` : VAR 가 비어 있거나 없으면 기본값을 쓴다.

### 3-2. 2단계 — Health Check (실패 시 exit 1)

확인용 `echo` 줄을 지우고 아래를 이어 붙입니다.

```bash
now() { date '+%Y-%m-%d %H:%M:%S'; }

# 실패도 로그에 남겨야 나중에 "언제 죽었는지" 알 수 있다
log_error() {
    local msg="[$(now)] [ERROR] $*"
    echo "$msg" >&2                                   # 표준 에러로
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$AGENT_LOG_DIR" ) ]] && echo "$msg" >> "$LOG_FILE"
}

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# 프로세스: 이름이 정확히 일치하는 것 중 가장 최근(자식 = 실제 앱)
printf "Checking process '%s'... " "$APP_PROC_NAME"
APP_PID="$(pgrep -n -x "$APP_PROC_NAME" || true)"
if [[ -z "$APP_PID" ]]; then
    echo "[FAIL]"
    log_error "Process '${APP_PROC_NAME}' is not running"
    exit 1
fi
echo "[OK] (PID: ${APP_PID})"

# 포트: LISTEN 상태의 TCP 소켓 중 로컬 포트가 15034 인 것
printf "Checking port %s... " "$AGENT_PORT"
if [[ -z "$(ss -Htln "sport = :${AGENT_PORT}")" ]]; then
    echo "[FAIL]"
    log_error "Port ${AGENT_PORT}/tcp is not in LISTEN state"
    exit 1
fi
echo "[OK]"
```

```bash
agent-dev@vm$ bash monitor.sh; echo "exit=$?"
# [HEALTH CHECK]
# Checking process 'agent-app-linux'... [OK] (PID: 5012)
# Checking port 15034... [OK]
# exit=0
```

> **왜 `|| true` 인가?** `pgrep` 은 못 찾으면 종료 코드 1 을 냅니다. `set -o pipefail` 환경에서 의도치 않은 실패 전파를 막고, "빈 문자열"로 판단하기 위해서입니다.
>
> **stdout vs stderr**: 정상 출력은 표준 출력(1), 에러는 표준 에러(2)로 보냅니다. 호출하는 쪽에서 `2>/dev/null`, `2>&1` 로 따로 다룰 수 있습니다.

### 3-3. 3단계 — 방화벽 점검 (경고만)

```bash
warn() { echo "[WARNING] $*"; }

printf "Checking firewall (ufw)... "
FW_STATUS="$(sudo -n /usr/sbin/ufw status 2>/dev/null | head -n 1 || true)"
if [[ "$FW_STATUS" == "Status: active" ]]; then
    echo "[OK] (active)"
elif [[ -z "$FW_STATUS" ]] && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
    # sudo 권한이 없는 사용자가 돌린 경우: 설정 파일로 대신 판단
    echo "[OK] (enabled in /etc/ufw/ufw.conf, runtime not verified)"
else
    echo "[WARN]"
    warn "Firewall(ufw) is not active"
fi
```

> `sudo -n` (non-interactive): 비밀번호가 필요하면 **묻지 않고 즉시 실패**합니다. cron 처럼 사람이 없는 환경에서 스크립트가 비밀번호 입력을 기다리며 **영원히 멈추는 사고**를 막습니다.

### 3-4. 4단계 — 자원 수집

```bash
# CPU: /proc/stat 을 1초 간격으로 두 번 읽어 차이로 계산
read_cpu() {
    awk '/^cpu / { idle = $5 + $6; total = 0
                   for (i = 2; i <= 9; i++) total += $i
                   print idle, total }' /proc/stat
}
read -r IDLE1 TOTAL1 < <(read_cpu)
sleep 1
read -r IDLE2 TOTAL2 < <(read_cpu)
CPU_USAGE="$(awk -v i1="$IDLE1" -v t1="$TOTAL1" -v i2="$IDLE2" -v t2="$TOTAL2" \
    'BEGIN { dt = t2 - t1; printf "%.1f", (dt > 0) ? (1 - (i2 - i1) / dt) * 100 : 0 }')"

# MEM: (MemTotal - MemAvailable) / MemTotal
MEM_USAGE="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
                  END { printf "%.1f", (t - a) / t * 100 }' /proc/meminfo)"

# DISK: 루트(/) 파티션 Used%
DISK_USED="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"

echo
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used : ${DISK_USED}%"
```

검증 — 다른 도구의 값과 비교해 봅니다(시점이 달라 정확히 같지는 않음).

```bash
agent-dev@vm$ bash monitor.sh
agent-dev@vm$ top -bn2 -d1 | grep '^%Cpu' | tail -n1     # 100 - id 값과 비교
agent-dev@vm$ free -m                                     # (total-available)/total
agent-dev@vm$ df -h /
```

> `< <(명령)` (프로세스 치환): 명령의 출력을 파일처럼 `read` 에 넘깁니다. `명령 | read a b` 로 쓰면 `read` 가 서브셸에서 실행되어 변수가 사라집니다.

### 3-5. 5단계 — 임계값 경고

```bash
CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80

gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

HAS_WARNING=0
if gt "$CPU_USAGE" "$CPU_LIMIT"; then
    warn "CPU threshold exceeded (${CPU_USAGE}% > ${CPU_LIMIT}%)"; HAS_WARNING=1
fi
if gt "$MEM_USAGE" "$MEM_LIMIT"; then
    warn "MEM threshold exceeded (${MEM_USAGE}% > ${MEM_LIMIT}%)"; HAS_WARNING=1
fi
if gt "$DISK_USED" "$DISK_LIMIT"; then
    warn "DISK threshold exceeded (${DISK_USED}% > ${DISK_LIMIT}%)"; HAS_WARNING=1
fi
(( HAS_WARNING == 0 )) && echo "[INFO] All resources within thresholds"
```

> 완성본에서는 임계값·유틸리티 함수를 스크립트 **위쪽 설정 영역**으로 모았습니다. "바꿀 가능성이 있는 값은 한 곳에" 가 유지보수의 기본입니다.

### 3-6. 6단계 — 로그 회전 + 동시 실행 방지

설정 영역(1단계 아래)에 추가:

```bash
LOCK_FILE="${AGENT_LOG_DIR}/.monitor.lock"
# 테스트용으로 MONITOR_LOG_MAX_BYTES 를 주면 그 값을 쓴다
LOG_MAX_BYTES="${MONITOR_LOG_MAX_BYTES:-$((10 * 1024 * 1024))}"
LOG_MAX_FILES=10
```

`echo "====== SYSTEM MONITOR RESULT ======"` **앞**에 추가 (사전 점검 + 잠금):

```bash
if [[ ! -d "$AGENT_LOG_DIR" ]]; then
    echo "[ERROR] Log directory not found: $AGENT_LOG_DIR" >&2
    exit 2
fi
if [[ ! -w "$AGENT_LOG_DIR" ]]; then
    echo "[ERROR] No write permission: $AGENT_LOG_DIR (user: $(id -un))" >&2
    exit 2
fi

# 파일 디스크립터 9번으로 잠금 파일을 열고 배타적 잠금 (최대 10초 대기)
exec 9>>"$LOCK_FILE"
if ! flock -w 10 9; then
    echo "[ERROR] Another monitor.sh is running (lock: $LOCK_FILE)" >&2
    exit 2
fi
```

임계값 경고 **뒤**에 추가:

```bash
rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size="$(stat -c %s "$LOG_FILE")"
    (( size < LOG_MAX_BYTES )) && return 0

    local last=$((LOG_MAX_FILES - 1)) i
    rm -f "${LOG_FILE}.${last}"                       # 가장 오래된 것 삭제
    for (( i = last - 1; i >= 1; i-- )); do           # 뒤에서부터 한 칸씩 밀기
        [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    echo "[INFO] Log rotated: ${LOG_FILE} (${size} bytes) -> ${LOG_FILE}.1"
}
rotate_log
```

> 왜 **뒤에서부터** 미나? 앞에서부터 `.1 → .2` 를 하면 기존 `.2` 를 덮어써 버립니다.

### 3-7. 7단계 — 로그 기록

```bash
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
    "$(now)" "$APP_PID" "$CPU_USAGE" "$MEM_USAGE" "$DISK_USED" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: ${LOG_FILE}"
exit 0
```

> `printf` 에서 `%` 문자 자체를 출력하려면 `%%` 로 씁니다.
> `>>` 는 이어쓰기(append), `>` 는 덮어쓰기입니다. 로그에 `>` 를 쓰는 실수는 **기록 전체를 날립니다.**

작성이 끝나면 완성본과 비교해 빠진 것이 없는지 확인합니다(ops 계정).

```bash
ops@vm$ diff <(sed 's/[[:space:]]*#.*//' $REPO/scripts/monitor.sh      | grep -v '^$') \
             <(sudo sed 's/[[:space:]]*#.*//' $AH/bin/monitor.sh | grep -v '^$')
# 주석·빈 줄을 제외하고 비교. 차이가 있으면 의도한 것인지 확인
# (ops 는 $AH/bin 을 읽을 수 없으므로 오른쪽만 sudo 로 읽는다)
```

> 막혔다면 완성본을 그대로 설치하고 **한 줄씩 읽으며 이해**하는 방식으로 진행해도 됩니다.
> ```bash
> ops@vm$ sudo install -o agent-dev -g agent-core -m 750 $REPO/scripts/monitor.sh $AH/bin/monitor.sh
> ```

### 3-8. 소유자·권한 설정 (미션 필수)

```bash
agent-dev@vm$ chmod 750 "$AGENT_HOME/bin/monitor.sh"
agent-dev@vm$ ls -l "$AGENT_HOME/bin/monitor.sh"
# -rwxr-x--- 1 agent-dev agent-core ... monitor.sh
```

- 소유자 `agent-dev` : 직접 만들었으므로 자동. (다른 계정으로 만들었다면 `sudo chown agent-dev:agent-core`)
- 그룹 `agent-core` : `bin` 디렉토리의 **setgid** 덕분에 자동 상속 (04장)
- `750` : 작성자 rwx, agent-core(admin 포함) r-x, 그 외 없음

✅ 체크포인트: `-rwxr-x--- agent-dev agent-core`

---

## 4. 테스트 — 정상·실패·경계 조건 모두

### T1. 정상 실행 (cron 실행자 agent-admin)

```bash
ops@vm$ sudo -u agent-admin $AH/bin/monitor.sh; echo "exit=$?"
```

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-linux'... [OK] (PID: 5012)
Checking port 15034... [OK]
Checking firewall (ufw)... [OK] (active)

[RESOURCE MONITORING]
CPU Usage : 25.3%
MEM Usage : 12.4%
DISK Used : 23%
[WARNING] CPU threshold exceeded (25.3% > 20%)
[WARNING] MEM threshold exceeded (12.4% > 10%)

[INFO] Log appended: /var/log/agent-app/monitor.log
exit=0
```

📸 스크린샷. (앱이 부하를 올렸다 내리므로 여러 번 실행하면 경고가 나왔다 사라집니다.)

### T2. 권한 없는 사용자

```bash
ops@vm$ sudo -u agent-test $AH/bin/monitor.sh
# ... Permission denied        ← agent-test 는 agent-core 가 아님 (정상)
```

### T3. 앱이 죽었을 때 (exit 1)

```bash
# tmux 세션으로 가서 앱을 Ctrl+C 로 종료
ops@vm$ tmux attach -t agent       # Ctrl+C → Agent Shutdown 확인 → Ctrl+b d

ops@vm$ sudo -u agent-admin $AH/bin/monitor.sh; echo "exit=$?"
# [HEALTH CHECK]
# Checking process 'agent-app-linux'... [FAIL]
# [2026-09-23 14:05:12] [ERROR] Process 'agent-app-linux' is not running
# exit=1

ops@vm$ sudo tail -n 2 /var/log/agent-app/monitor.log     # [ERROR] 줄도 기록됨
```

**앱을 다시 실행**해 둡니다 (`tmux attach -t agent` → `./agent-app-linux-*` → `Ctrl+b d`).

> 포트 검사는 프로세스 검사 다음에 있으므로, 앱을 끄면 프로세스 단계에서 먼저 실패합니다. "프로세스는 있는데 포트가 닫힌" 상태(앱이 행(hang) 걸리거나 소켓 초기화 실패)는 현업에서 실제로 자주 일어나는 장애이며, 이것이 두 검사를 **따로** 두는 이유입니다.

### T4. 방화벽 비활성 (경고 후 계속)

```bash
ops@vm$ sudo ufw disable
ops@vm$ sudo -u agent-admin $AH/bin/monitor.sh; echo "exit=$?"
# Checking firewall (ufw)... [WARN]
# [WARNING] Firewall(ufw) is not active
# ... (자원 수집, 로그 기록까지 계속 진행)
# exit=0
ops@vm$ sudo ufw enable          # 반드시 다시 켠다!
ops@vm$ sudo ufw status | head -n1
```

### T5. 로그 형식 검증

```bash
ops@vm$ sudo tail -n 5 /var/log/agent-app/monitor.log
ops@vm$ sudo grep -cE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9]+%$' \
      /var/log/agent-app/monitor.log
# 측정 줄 수와 같아야 함
```

### T6. 로그 회전 (10MB 대신 작은 값으로)

10MB 를 채우려면 수년이 걸리므로(1줄 ≈ 70B, 매분 → 하루 약 100KB) **임계값만 작게** 바꿔 로직을 검증합니다.

```bash
# 현재 로그 백업
ops@vm$ sudo -u agent-admin cp -p /var/log/agent-app/monitor.log /var/log/agent-app/monitor.log.bak

# 300바이트마다 회전하도록 12번 실행
ops@vm$ for i in $(seq 1 12); do
          sudo -u agent-admin env MONITOR_LOG_MAX_BYTES=300 $AH/bin/monitor.sh | grep -E 'rotated|appended'
        done
ops@vm$ sudo ls -l /var/log/agent-app/
# monitor.log, monitor.log.1 ~ monitor.log.9  → 최대 10개, .10 은 생기지 않음
ops@vm$ sudo ls /var/log/agent-app/ | grep -c '^monitor\.log\(\.[0-9]\+\)\?$'    # 10
```

📸 스크린샷. 확인 후 테스트 파일을 정리하고 백업을 복원합니다.

```bash
ops@vm$ sudo -u agent-admin bash -c 'cd /var/log/agent-app && rm -f monitor.log.[1-9] && cat monitor.log >> monitor.log.bak && mv monitor.log.bak monitor.log'
ops@vm$ sudo ls -l /var/log/agent-app/
```

> 실제 10MB 조건 확인(선택): `sudo -u agent-admin truncate -s 11M /var/log/agent-app/monitor.log` 후 1회 실행하면 회전됩니다. (truncate 는 파일 끝을 0 바이트로 채우므로 확인 후 `monitor.log.1` 을 지우세요.)

### T7. 동시 실행 (선택)

```bash
ops@vm$ sudo -u agent-admin $AH/bin/monitor.sh >/dev/null & sudo -u agent-admin $AH/bin/monitor.sh | head -n 3; wait
# 두 번째 실행은 첫 번째가 끝날 때까지 대기 후 실행됨 (flock)
```

---

## 5. 트러블슈팅

| 증상 | 원인/해결 |
|---|---|
| `Permission denied` (agent-admin) | `ls -l` 로 `750 agent-dev:agent-core` 확인, `id agent-admin` 에 agent-core 있는지 |
| `bash\r: No such file` | CRLF → `sed -i 's/\r$//' monitor.sh` |
| 프로세스 [FAIL] 인데 앱은 떠 있음 | `ps -o comm= -C agent-app-linux` 로 실제 이름 확인. 파일명을 바꿔 실행했다면 `APP_PROC_NAME` 조정 |
| 방화벽이 항상 "(enabled in ufw.conf …)" | sudoers 미설치/그룹 불일치 → 2장 절차 재확인, `sudo -u agent-admin sudo -n -l` |
| CPU 가 항상 0.0 | `sleep 1` 누락 또는 두 번 읽은 값이 같음 |
| `syntax error: invalid arithmetic operator` | `(( ))` 에 소수 사용 → `gt` 함수(awk) 사용 |
| `bash -n monitor.sh` | 실행하지 않고 문법만 검사. 수정 후 습관적으로 실행 |

---

## 🤖 현장 노트 — 로봇 관제의 실제

1. **로그는 "로봇 안"에만 있으면 소용없다** — 로봇이 꺼지거나 디스크가 망가지면 로그도 사라집니다. 현장에서는 `journald` → 중앙 로그 서버(Loki, Elasticsearch 등)로 전송하고, 메트릭은 `node_exporter` + Prometheus 같은 표준 도구로 수집합니다. monitor.sh 는 그 원리를 직접 구현해 보는 것입니다.
2. **로그 → 경보** — 로그를 쌓기만 하면 아무도 안 봅니다. `exit 1` 이 발생하면 관제 시스템에 알림을 보내는 연결 고리가 필요합니다. 역으로 "모니터 자체가 죽었는데 아무도 모르는" 상황을 막기 위해, 일정 시간 신호가 없으면 경보를 울리는 **dead man's switch(하트비트)** 를 둡니다.
3. **임계값은 로봇 특성에 맞춘다** — 미션의 CPU 20% / MEM 10% 는 경고를 일부러 자주 보기 위한 학습용 값입니다. 실제 로봇은 주행 중 CPU 70~80% 가 정상일 수 있습니다. 순간값이 아니라 "5분 평균이 N% 이상" 처럼 **지속 시간 조건**을 붙여 경보 피로(alert fatigue)를 줄입니다.
4. **로봇에서 중요한 추가 지표** — 배터리 잔량/온도, CPU 온도(스로틀링), 디스크 **쓰기량**(eMMC/SD 수명), 네트워크 RSSI(Wi-Fi 신호), 주요 ROS 노드 생존 여부.
5. **디스크 가득 참(Disk Full)은 로봇을 멈춘다** — 로그가 디스크를 채우면 앱이 설정 파일도 못 쓰고 멈춥니다. 로그 크기 상한(이 장의 10MB × 10)은 선택이 아니라 **필수 안전장치**입니다.

---

## 📝 수행 내역서에 기록할 것

- sudoers 설정 내용과 "왜 이 방식을 택했는가"
- 증거: `ls -l $AGENT_HOME/bin/monitor.sh` (`-rwxr-x--- agent-dev agent-core`)
- 증거: T1 정상 실행 출력(경고 포함), T3 exit 1, T4 방화벽 경고, T6 회전 결과
- 증거: `tail monitor.log`
- 제출물 ②: 최종 `monitor.sh` 소스 (09장에서 저장소에 반영)

## 🧠 자기 점검

1. 프로세스/포트 실패는 `exit 1` 하고 방화벽·자원 경고는 종료하지 않는 이유는?
2. `/proc/stat` 을 한 번만 읽으면 안 되는 이유는?
3. 메모리 사용률에 `MemFree` 가 아닌 `MemAvailable` 을 쓰는 이유는?
4. `pgrep -f agent-app` 대신 `pgrep -x agent-app-linux` 를 쓴 이유는?
5. monitor.sh 가 방화벽 상태를 확인하기 위해 필요한 권한을 어떻게 최소화했는가?
6. 로그 파일 크기를 제한하지 않으면 로봇에서 어떤 일이 벌어지는가?
7. 로그 한 줄의 형식을 `[시각] 키:값 ...` 으로 정한 이유는?

⬅️ 이전: [05_환경변수와_앱실행](05_환경변수와_앱실행.md) | ➡️ 다음: [07_cron_자동화](07_cron_자동화.md)
