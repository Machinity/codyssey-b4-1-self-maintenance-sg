#!/usr/bin/env bash
#
# monitor.sh - agent-app 시스템 상태 수집 및 로깅 스크립트
#
#   설치 위치 : $AGENT_HOME/bin/monitor.sh   (agent-dev:agent-core, 750)
#   실행 계정 : agent-admin (crontab, 매분)
#   로그 파일 : /var/log/agent-app/monitor.log
#
#   종료 코드
#     0 : 정상 (경고가 있어도 0)
#     1 : Health Check 실패 (프로세스 없음 / 포트 미리슨)
#     2 : 실행 환경 오류 (로그 디렉토리 없음/쓰기 불가, 락 획득 실패)
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 0. 실행 환경 고정
#    cron 은 PATH 가 /usr/bin:/bin 뿐이고 AGENT_* 환경 변수도 없다.
#    → PATH 를 직접 지정하고, 공용 환경 파일을 읽은 뒤, 없으면 기본값을 쓴다.
# ---------------------------------------------------------------------------
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C   # 소수점/날짜 출력 형식을 로케일과 무관하게 고정

ENV_FILE="/etc/agent-app/agent.env"
if [[ -r "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
fi

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"

# 제공 앱은 PyInstaller 로 만든 실행 파일이다.
# 리눅스는 프로세스 이름(comm)을 15자로 자르므로
#   agent-app-linux-x86 / agent-app-linux-arm64  →  "agent-app-linux"
APP_PROC_NAME="${APP_PROC_NAME:-agent-app-linux}"

LOG_FILE="${AGENT_LOG_DIR}/monitor.log"
LOCK_FILE="${AGENT_LOG_DIR}/.monitor.lock"

# 임계값 (%)
CPU_LIMIT=20
MEM_LIMIT=10
DISK_LIMIT=80

# 로그 용량 관리: monitor.log 1개 + monitor.log.1 ~ .9 = 최대 10개, 파일당 10MB
#   MONITOR_LOG_MAX_BYTES 는 로테이션 테스트용 (예: MONITOR_LOG_MAX_BYTES=500 ./monitor.sh)
LOG_MAX_BYTES="${MONITOR_LOG_MAX_BYTES:-$((10 * 1024 * 1024))}"
LOG_MAX_FILES=10

# ---------------------------------------------------------------------------
# 유틸리티
# ---------------------------------------------------------------------------
now()  { date '+%Y-%m-%d %H:%M:%S'; }
warn() { echo "[WARNING] $*"; }

# awk 로 실수 비교 (bash 산술은 정수만 지원)
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# 실패 기록: 장애 원인을 나중에 추적할 수 있도록 monitor.log 에도 남긴다
log_error() {
    local msg="[$(now)] [ERROR] $*"
    echo "$msg" >&2
    [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$AGENT_LOG_DIR" ) ]] && echo "$msg" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# 1. 사전 점검 + 동시 실행 방지
# ---------------------------------------------------------------------------
if [[ ! -d "$AGENT_LOG_DIR" ]]; then
    echo "[ERROR] Log directory not found: $AGENT_LOG_DIR" >&2
    exit 2
fi
if [[ ! -w "$AGENT_LOG_DIR" ]]; then
    echo "[ERROR] No write permission: $AGENT_LOG_DIR (user: $(id -un))" >&2
    exit 2
fi

# cron(매분) 실행과 수동 실행이 겹쳐도 로그 로테이션이 꼬이지 않도록 락을 잡는다
exec 9>>"$LOCK_FILE"
if ! flock -w 10 9; then
    echo "[ERROR] Another monitor.sh is running (lock: $LOCK_FILE)" >&2
    exit 2
fi

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# ---------------------------------------------------------------------------
# 2. Health Check (실패 시 exit 1)
# ---------------------------------------------------------------------------
# 2-1. 프로세스
#   PyInstaller onefile 앱은 부모(압축 해제)+자식(실제 앱) 2개 프로세스로 뜬다.
#   -n(newest) 으로 실제 앱인 자식 프로세스의 PID 를 고른다.
printf "Checking process '%s'... " "$APP_PROC_NAME"
APP_PID="$(pgrep -n -x "$APP_PROC_NAME" || true)"
if [[ -z "$APP_PID" ]]; then
    echo "[FAIL]"
    log_error "Process '${APP_PROC_NAME}' is not running"
    exit 1
fi
echo "[OK] (PID: ${APP_PID})"

# 2-2. 포트 (TCP LISTEN)
printf "Checking port %s... " "$AGENT_PORT"
if [[ -z "$(ss -Htln "sport = :${AGENT_PORT}")" ]]; then
    echo "[FAIL]"
    log_error "Port ${AGENT_PORT}/tcp is not in LISTEN state"
    exit 1
fi
echo "[OK]"

# ---------------------------------------------------------------------------
# 3. 방화벽 상태 점검 (경고만, 종료하지 않음)
#   'ufw status' 는 root 권한이 필요하다.
#   /etc/sudoers.d/agent-monitor 로 'ufw status' 한 줄만 허용해 두었다(최소 권한).
#   sudo 권한이 없으면 설정 파일(ENABLED=yes)로 대신 판단한다.
# ---------------------------------------------------------------------------
printf "Checking firewall (ufw)... "
FW_STATUS="$(sudo -n /usr/sbin/ufw status 2>/dev/null | head -n 1 || true)"
if [[ "$FW_STATUS" == "Status: active" ]]; then
    echo "[OK] (active)"
elif [[ -z "$FW_STATUS" ]] && grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
    echo "[OK] (enabled in /etc/ufw/ufw.conf, runtime not verified)"
else
    echo "[WARN]"
    warn "Firewall(ufw) is not active"
fi

# ---------------------------------------------------------------------------
# 4. 자원 수집
# ---------------------------------------------------------------------------
# 4-1. CPU: /proc/stat 을 1초 간격으로 두 번 읽어 그 사이의 사용률을 계산
#   cpu  user nice system idle iowait irq softirq steal guest guest_nice
#   (guest 는 user 에 이미 포함되어 있으므로 합계에서 제외)
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

# 4-2. 메모리: (MemTotal - MemAvailable) / MemTotal
#   MemFree 가 아니라 MemAvailable 을 쓰는 이유: 캐시는 필요 시 회수되므로 '사용 중'이 아님
MEM_USAGE="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
                  END { printf "%.1f", (t - a) / t * 100 }' /proc/meminfo)"

# 4-3. 디스크: 루트(/) 파티션 Used%   (-P: 한 줄 POSIX 형식 보장)
DISK_USED="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"

echo
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU_USAGE}%"
echo "MEM Usage : ${MEM_USAGE}%"
echo "DISK Used : ${DISK_USED}%"

# ---------------------------------------------------------------------------
# 5. 임계값 경고 (경고만)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 6. 로그 용량 관리 (10MB 초과 시 회전, 최대 10개 파일 유지)
#   monitor.log → .1 → .2 ... → .9 → 삭제
# ---------------------------------------------------------------------------
rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size="$(stat -c %s "$LOG_FILE")"
    (( size < LOG_MAX_BYTES )) && return 0

    local last=$((LOG_MAX_FILES - 1)) i
    rm -f "${LOG_FILE}.${last}"
    for (( i = last - 1; i >= 1; i-- )); do
        [[ -f "${LOG_FILE}.${i}" ]] && mv -f "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
    echo "[INFO] Log rotated: ${LOG_FILE} (${size} bytes) -> ${LOG_FILE}.1"
}
rotate_log

# ---------------------------------------------------------------------------
# 7. 로그 기록
#   [YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%
# ---------------------------------------------------------------------------
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
    "$(now)" "$APP_PID" "$CPU_USAGE" "$MEM_USAGE" "$DISK_USED" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: ${LOG_FILE}"
exit 0
