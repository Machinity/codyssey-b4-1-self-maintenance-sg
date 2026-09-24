#!/usr/bin/env bash
#
# collect_evidence.sh - 제출용 증거 자료 일괄 수집
#
#   사용법 (VM 안, 저장소 루트에서)
#     sudo ./scripts/collect_evidence.sh            # 전체 수집 (cron 확인에 약 70초 소요)
#     sudo ./scripts/collect_evidence.sh --no-wait  # cron 대기 생략
#
#   결과: submission/evidence/NN_*.txt
#     - 각 파일에는 "실행한 명령 + 출력 + 수집 시각" 이 함께 기록된다.
#     - 비밀 값(secret.key 내용)은 절대 출력하지 않는다. (증거 파일도 유출 경로가 될 수 있다)
#
set -uo pipefail
export LC_ALL=C

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] sudo 로 실행하세요: sudo $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_DIR}/submission/evidence"
WAIT_CRON=1
[[ "${1:-}" == "--no-wait" ]] && WAIT_CRON=0

ENV_FILE=/etc/agent-app/agent.env
if [[ -r "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
MONITOR="${AGENT_HOME}/bin/monitor.sh"
MONLOG="${AGENT_LOG_DIR}/monitor.log"

mkdir -p "$OUT_DIR"
CUR=""

section() {                       # section <파일명> <제목>
    CUR="${OUT_DIR}/$1"
    {
        echo "################################################################"
        echo "# $2"
        echo "# collected: $(date '+%Y-%m-%d %H:%M:%S %Z') on $(hostname)"
        echo "################################################################"
    } > "$CUR"
    echo "[+] $1"
}

run() {                           # run <명령 문자열>
    {
        echo
        echo "\$ $*"
        bash -c "$*" 2>&1
        echo "(exit=$?)"
    } >> "$CUR"
}

note() { echo -e "\n# $*" >> "$CUR"; }

# ---------------------------------------------------------------------------
section 00_system.txt "실습 환경 정보"
run "lsb_release -a"
run "uname -a"
run "hostnamectl"
run "timedatectl | head -n 5"

# ---------------------------------------------------------------------------
section 01_ssh.txt "SSH 포트 변경(20022) 및 Root 원격 접속 차단"
note "drop-in 설정 파일"
run "ls -l /etc/ssh/sshd_config.d/"
run "cat /etc/ssh/sshd_config.d/10-agent-hardening.conf"
note "메인 설정에 활성화된 Port/PermitRootLogin 이 남아있지 않은지 (주석만 있어야 함)"
run "grep -nE '^[[:space:]]*#?[[:space:]]*(Port|PermitRootLogin|Include)' /etc/ssh/sshd_config"
note "sshd 가 실제로 적용한 최종 설정 (sshd -T = effective config)"
run "sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|maxauthtries|x11forwarding) '"
note "리슨 상태: 20022 만 있어야 하고 22 는 없어야 함"
run "ss -tulnp | grep -E 'sshd|State'"
run "systemctl is-active ssh"

# ---------------------------------------------------------------------------
section 02_firewall.txt "UFW 활성화 및 20022/tcp, 15034/tcp 만 허용"
run "ufw status verbose"
run "ufw status numbered"
note "전체 LISTEN 포트 (방화벽 정책과 비교: 열려 있는 포트 ≠ 허용된 포트)"
run "ss -tulnH | awk '{print \$1, \$5}' | sort -u"

# ---------------------------------------------------------------------------
section 03_accounts.txt "계정/그룹 생성 확인"
run "id agent-admin"
run "id agent-dev"
run "id agent-test"
run "getent group agent-common agent-core"
run "getent passwd agent-admin agent-dev agent-test"
note "sudoers: monitor 용 최소 권한 규칙"
run "ls -l /etc/sudoers.d/agent-monitor && cat /etc/sudoers.d/agent-monitor"
run "sudo -l -U agent-admin | tail -n 3"

# ---------------------------------------------------------------------------
section 04_dirs_acl.txt "디렉토리 구조 및 권한(ACL 포함)"
run "namei -l ${AGENT_HOME}/api_keys"
run "ls -ld ${AGENT_HOME} ${AGENT_HOME}/upload_files ${AGENT_HOME}/api_keys ${AGENT_HOME}/bin ${AGENT_LOG_DIR}"
run "ls -l ${AGENT_HOME}/api_keys ${AGENT_HOME}/bin"
run "getfacl -p /home/agent-admin ${AGENT_HOME} ${AGENT_HOME}/upload_files ${AGENT_HOME}/api_keys ${AGENT_LOG_DIR}"
note "권한 검증 테스트 (OK = 허용되어야 함, DENIED = 차단되어야 함)"
t() {  # t <user> <기대결과> <명령>
    local u=$1 exp=$2; shift 2
    if sudo -u "$u" bash -c "$*" >/dev/null 2>&1; then r=ALLOWED; else r=DENIED; fi
    printf '%-12s %-60s expect=%-8s got=%-8s %s\n' "$u" "$*" "$exp" "$r" \
        "$([[ $exp == "$r" ]] && echo PASS || echo '<<< FAIL')" >> "$CUR"
}
echo >> "$CUR"
T="${AGENT_HOME}/upload_files/.evidence_\$(id -un)"
t agent-test ALLOWED "touch $T && rm -f $T"
t agent-dev  ALLOWED "touch $T && rm -f $T"
t agent-test DENIED  "ls ${AGENT_HOME}/api_keys"
t agent-test DENIED  "cat ${AGENT_HOME}/api_keys/*"
t agent-test DENIED  "ls ${AGENT_LOG_DIR}"
t agent-dev  ALLOWED "test -r ${AGENT_HOME}/api_keys/secret.key || test -r ${AGENT_HOME}/api_keys/t_secret.key"
t agent-dev  ALLOWED "touch ${AGENT_LOG_DIR}/.evidence && rm -f ${AGENT_LOG_DIR}/.evidence"
t agent-admin ALLOWED "test -x ${MONITOR}"
t agent-test DENIED  "test -x ${MONITOR} && ${MONITOR}"

# ---------------------------------------------------------------------------
section 05_env_app.txt "환경 변수 및 앱 실행 상태"
run "ls -l ${ENV_FILE} && cat ${ENV_FILE}"
run "ls -l ${AGENT_HOME}/api_keys/"
note "키 파일 내용 대신 '기대값과 일치 여부'만 기록 (비밀 값 비노출)"
run "for f in ${AGENT_HOME}/api_keys/*.key; do printf '%s : ' \"\$f\"; [ \"\$(tr -d '[:space:]' < \"\$f\")\" = agent_api_key_test ] && echo 'content OK' || echo 'content MISMATCH'; done"
run "ps -o user,pid,ppid,ni,etime,cmd -C agent-app-linux"
run "ss -tlnp 'sport = :15034'"
APP_PID="$(pgrep -n -x agent-app-linux || true)"
if [[ -n "$APP_PID" ]]; then
    note "실행 중인 앱 프로세스(PID ${APP_PID})가 실제로 받은 환경 변수"
    run "tr '\\0' '\\n' < /proc/${APP_PID}/environ | grep '^AGENT_' | sort"
else
    note "!!! 앱이 실행 중이 아닙니다. 앱을 먼저 실행한 뒤 다시 수집하세요."
fi
note "부팅 로그는 guide/05 에서 script 명령으로 저장한 05_app_boot.txt 를 함께 제출"

# ---------------------------------------------------------------------------
section 06_monitor_run.txt "monitor.sh 실행 결과"
run "ls -l ${MONITOR}"
run "sudo -u agent-admin ${MONITOR}"

# ---------------------------------------------------------------------------
section 07_monitor_log.txt "monitor.log 누적 기록"
run "ls -l ${AGENT_LOG_DIR}/"
run "wc -l ${MONLOG}"
run "tail -n 15 ${MONLOG}"

# ---------------------------------------------------------------------------
section 08_cron.txt "crontab 매분 실행 등록 및 자동 실행 확인"
run "crontab -l -u agent-admin"
run "systemctl is-active cron"
if (( WAIT_CRON )); then
    before=$(wc -l < "$MONLOG")
    note "대기 전 라인 수: ${before}  ($(date '+%H:%M:%S'))"
    echo "    ... cron 자동 실행 확인을 위해 70초 대기합니다"
    sleep 70
    after=$(wc -l < "$MONLOG")
    note "대기 후 라인 수: ${after}  ($(date '+%H:%M:%S'))  → 증가량 $((after - before))"
    run "tail -n 3 ${MONLOG}"
fi
run "journalctl -t CRON --since '-5 min' --no-pager | grep agent-admin | tail -n 5"
run "journalctl -t agent-monitor --since '-5 min' --no-pager | tail -n 20"

# ---------------------------------------------------------------------------
if [[ -x "${AGENT_HOME}/bin/report.sh" || -x "${AGENT_HOME}/bin/log_retention.sh" ]]; then
    section 09_bonus.txt "보너스 과제"
    [[ -x "${AGENT_HOME}/bin/report.sh" ]] && run "sudo -u agent-admin ${AGENT_HOME}/bin/report.sh"
    [[ -x "${AGENT_HOME}/bin/log_retention.sh" ]] && run "sudo -u agent-admin ${AGENT_HOME}/bin/log_retention.sh -n"
    run "ls -la /var/log/monitor/agent-app/archive/ 2>&1"
fi

# 수집 파일 소유권을 sudo 를 호출한 사용자에게 돌려준다
if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:" "$OUT_DIR"
fi

echo
echo "[DONE] ${OUT_DIR}"
grep -l '<<< FAIL' "$OUT_DIR"/*.txt 2>/dev/null | sed 's/^/[CHECK] 실패 항목 있음: /'
