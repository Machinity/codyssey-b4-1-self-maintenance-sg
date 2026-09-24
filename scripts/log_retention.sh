#!/usr/bin/env bash
#
# log_retention.sh - 시간 기반 로그 보존 정책 (보너스 2)
#
#   1) /var/log/agent-app 의 로그 중 7일 이상 지난 파일 → gzip 압축
#   2) 압축본을 /var/log/monitor/agent-app/archive/ 로 이동
#   3) archive 의 *.gz 중 30일 이상 지난 파일 → 삭제
#
#   사용법
#     log_retention.sh            # 실제 수행
#     log_retention.sh -n         # dry-run: 무엇을 할지 출력만
#
#   실행 계정: agent-admin (agent-core 그룹) / cron: 매일 03:10
#
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

SRC_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="/var/log/monitor/agent-app/archive"
COMPRESS_DAYS=7
DELETE_DAYS=30

# find -mtime +N 은 "N+1 일 이상" 을 뜻한다 (소수점 이하 버림 후 N 초과 비교).
#   → "7일 이상 경과" = -mtime +6,  "30일 이상 경과" = -mtime +29
COMPRESS_MTIME=$((COMPRESS_DAYS - 1))
DELETE_MTIME=$((DELETE_DAYS - 1))

DRY_RUN=0
[[ "${1:-}" == "-n" ]] && DRY_RUN=1

info() { echo "[INFO] $*"; }
warn() { echo "[WARNING] $*"; }

(( DRY_RUN )) && info "DRY-RUN 모드: 파일을 변경하지 않습니다."

# ---------------------------------------------------------------------------
# 0. 예외 처리: 디렉토리 존재/권한
#    보존 작업 실패가 서비스 장애로 번지지 않도록 '경고 후 안전 종료(0)' 한다.
# ---------------------------------------------------------------------------
if [[ ! -d "$SRC_DIR" ]]; then
    warn "원본 디렉토리가 없습니다: $SRC_DIR  → 작업 없이 종료"
    exit 0
fi
if [[ ! -r "$SRC_DIR" || ! -w "$SRC_DIR" || ! -x "$SRC_DIR" ]]; then
    warn "원본 디렉토리 권한 부족: $SRC_DIR (user: $(id -un))  → 작업 없이 종료"
    exit 0
fi
if [[ ! -d "$ARCHIVE_DIR" ]] && (( DRY_RUN )); then
    warn "아카이브 디렉토리가 없습니다: $ARCHIVE_DIR (dry-run 이므로 생성하지 않음)"
    exit 0
fi
if [[ ! -d "$ARCHIVE_DIR" ]]; then
    if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
        warn "아카이브 디렉토리를 만들 수 없습니다: $ARCHIVE_DIR"
        warn "관리자가 먼저 생성해야 합니다: sudo install -d -o agent-admin -g agent-core -m 2770 $ARCHIVE_DIR"
        exit 0
    fi
    info "아카이브 디렉토리 생성: $ARCHIVE_DIR"
fi
if [[ ! -w "$ARCHIVE_DIR" ]]; then
    warn "아카이브 디렉토리 쓰기 권한 없음: $ARCHIVE_DIR  → 작업 없이 종료"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1+2. 7일 경과 로그 압축 → 아카이브 이동
#   대상: *.log 와 회전된 *.log.N  (이미 압축된 *.gz 제외)
#   현재 기록 중인 monitor.log / agent_app.log 는 매분 갱신되므로 mtime 조건에 걸리지 않는다.
# ---------------------------------------------------------------------------
compressed=0; failed=0
while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    stamp="$(date -r "$file" '+%Y%m%d')"
    dest="${ARCHIVE_DIR}/${base}.${stamp}.gz"

    if [[ -e "$dest" ]]; then
        dest="${ARCHIVE_DIR}/${base}.${stamp}.$(date '+%H%M%S').gz"
    fi

    # 압축본을 먼저 만들고 성공했을 때만 원본을 지운다 (중간 실패 시 원본 보존)
    if (( DRY_RUN )); then
        echo "  (dry-run) gzip $file -> $dest"
        compressed=$((compressed + 1))
    elif gzip -c -- "$file" > "$dest" && rm -f -- "$file"; then
        info "압축/이동: $file -> $dest"
        compressed=$((compressed + 1))
    else
        warn "압축 실패: $file"
        rm -f -- "$dest"
        failed=$((failed + 1))
    fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f \
            \( -name '*.log' -o -name '*.log.[0-9]*' \) ! -name '*.gz' \
            -mtime "+${COMPRESS_MTIME}" -print0)

(( compressed == 0 && failed == 0 )) && info "압축 대상 없음 (${COMPRESS_DAYS}일 이상 경과한 로그 0개)"

# ---------------------------------------------------------------------------
# 3. 30일 경과 아카이브 삭제
# ---------------------------------------------------------------------------
deleted=0
while IFS= read -r -d '' gz; do
    if (( DRY_RUN )); then
        echo "  (dry-run) rm $gz"
    else
        rm -f -- "$gz" && info "삭제: $gz"
    fi
    deleted=$((deleted + 1))
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' -mtime "+${DELETE_MTIME}" -print0)

(( deleted == 0 )) && info "삭제 대상 없음 (${DELETE_DAYS}일 이상 경과한 아카이브 0개)"

echo "[SUMMARY] compressed=${compressed} failed=${failed} deleted=${deleted}"
exit 0
