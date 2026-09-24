#!/usr/bin/env bash
#
# report.sh - monitor.log 통계 리포트 (보너스 1)
#
#   사용법
#     report.sh                                   # 전체 구간
#     report.sh -s "2026-09-23 10:00:00"          # 시작 시각 이후
#     report.sh -s "2026-09-23 10:00:00" -e "2026-09-23 11:00:00"
#     report.sh -f /var/log/agent-app/monitor.log.1   # 다른 파일 분석
#
#   시각 형식은 로그와 같은 "YYYY-MM-DD HH:MM:SS" 이다.
#   이 형식은 '문자열 비교 = 시간 비교' 가 성립하므로 awk 에서 그대로 비교한다.
#
set -uo pipefail
export LC_ALL=C

LOG_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log"
START=""
END=""

usage() {
    sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

is_ts() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; }

while getopts ":s:e:f:h" opt; do
    case "$opt" in
        s) START="$OPTARG" ;;
        e) END="$OPTARG" ;;
        f) LOG_FILE="$OPTARG" ;;
        h) usage 0 ;;
        :) echo "[ERROR] -$OPTARG 옵션에 값이 필요합니다." >&2; usage 1 ;;
        *) echo "[ERROR] 알 수 없는 옵션: -$OPTARG" >&2; usage 1 ;;
    esac
done

for ts in "$START" "$END"; do
    if [[ -n "$ts" ]] && ! is_ts "$ts"; then
        echo "[ERROR] 시각 형식 오류: '$ts' (예: 2026-09-23 14:00:00)" >&2
        exit 1
    fi
done
if [[ -n "$START" && -n "$END" && "$START" > "$END" ]]; then
    echo "[ERROR] 시작 시각이 종료 시각보다 늦습니다." >&2
    exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
    echo "[ERROR] Log file not found: $LOG_FILE" >&2
    exit 1
fi
if [[ ! -r "$LOG_FILE" ]]; then
    echo "[ERROR] Permission denied: $LOG_FILE (user: $(id -un))" >&2
    exit 1
fi

# 로그 한 줄 예시
#   [2026-09-23 14:00:01] PID:4829 CPU:25.3% MEM:9.8% DISK_USED:23%
# [ERROR] 줄 등 형식이 다른 줄은 정규식으로 걸러낸다.
awk -v start="$START" -v end="$END" -v file="$LOG_FILE" '
function upd(key, val, ts) {
    sum[key] += val
    if (n == 1 || val > max[key]) { max[key] = val; maxts[key] = ts }
    if (n == 1 || val < min[key]) { min[key] = val; mints[key] = ts }
}
/^\[[0-9-]+ [0-9:]+\] PID:[0-9]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9.]+%/ {
    ts = substr($0, 2, 19)
    if (start != "" && ts < start) next
    if (end   != "" && ts > end)   next

    for (i = 3; i <= NF; i++) {
        split($i, kv, ":"); gsub("%", "", kv[2]); v[kv[1]] = kv[2] + 0
    }
    n++
    if (n == 1) first = ts
    last = ts
    upd("CPU", v["CPU"], ts); upd("MEM", v["MEM"], ts); upd("DISK", v["DISK_USED"], ts)
}
END {
    if (n == 0) {
        print "[INFO] 분석할 데이터가 없습니다. (file: " file ")"
        exit 0
    }
    print "====== STATISTICS REPORT ======"
    printf "Source : %s\n", file
    printf "Range  : %s ~ %s\n", first, last
    split("CPU MEM DISK", keys, " ")
    split("CPU Memory Disk", titles, " ")
    for (k = 1; k <= 3; k++) {
        key = keys[k]
        printf "[%s]\n", titles[k]
        printf "  Average : %.1f%%\n", sum[key] / n
        printf "  Maximum : %.1f%% at %s\n", max[key], maxts[key]
        printf "  Minimum : %.1f%% at %s\n", min[key], mints[key]
    }
    print "[Samples]"
    printf "  Data Points: %d samples\n", n
}' "$LOG_FILE"
