# 04. 디렉토리 구조와 권한 — 공유 디렉토리 vs 보안 디렉토리

## 이 장의 목표

| 경로 | 미션 정책 | 이 가이드의 설계 |
|---|---|---|
| `$AGENT_HOME` (`/home/agent-admin/agent-app`) | — | `agent-admin:agent-common` `2750` |
| `$AGENT_HOME/upload_files` | **agent-common R/W** | `agent-admin:agent-common` `2770` + default ACL |
| `$AGENT_HOME/api_keys` | **agent-core ONLY R/W** | `agent-admin:agent-core` `2770` + default ACL |
| `/var/log/agent-app` | **agent-core ONLY R/W** | `agent-admin:agent-core` `2770` + default ACL |
| `$AGENT_HOME/bin` (06장 monitor.sh 위치) | monitor.sh: `agent-dev:agent-core 750` | `agent-dev:agent-core` `2750` |
| `/home/agent-admin` | (경로 통과 필요) | `750` 유지 + **ACL `g:agent-common:--x`** |

그리고 다음을 **설명할 수 있어야** 합니다.
> 역할 기반 계정/그룹과 ACL을 통해 "공유 디렉토리"와 "보안 디렉토리"를 분리하는 이유는?

---

## 1. 개념

### 1-1. 권한 비트 복습 — 파일과 디렉토리는 의미가 다르다

```
-rw-r-----  1 agent-admin agent-core  19 ... t_secret.key
│└┬┘└┬┘└┬┘
│ │  │  └ other (그 외 모두)
│ │  └── group (소유 그룹 agent-core 멤버)
│ └───── user  (소유자 agent-admin)
└─────── 종류 (- 파일, d 디렉토리, l 링크)
```

| 비트 | 파일 | **디렉토리** |
|---|---|---|
| `r` (4) | 내용 읽기 | 안의 **이름 목록** 보기 (`ls`) |
| `w` (2) | 내용 수정 | 안에 파일 **생성·삭제·이름변경** |
| `x` (1) | 실행 | **통과(진입)**: `cd`, 그리고 하위 경로 접근 |

- 디렉토리에 `x` 가 없으면 안의 파일 권한이 777 이어도 접근할 수 없습니다.
- 경로 `/home/agent-admin/agent-app/api_keys/secret.key` 에 접근하려면 **경로상의 모든 디렉토리에 `x`** 가 있어야 합니다. → `namei -l` 로 한 번에 확인합니다.
- 파일 삭제 권한은 **파일이 아니라 디렉토리의 `w`** 에서 나옵니다.

### 1-2. 특수 비트 — setgid 디렉토리

| 비트 | 디렉토리에 설정 시 | 표시 |
|---|---|---|
| **setgid (2000)** | 안에서 만든 파일의 그룹이 **만든 사람의 그룹이 아니라 디렉토리의 그룹**을 따른다 | `drwxrws---` |
| sticky (1000) | 파일은 **소유자만** 삭제 가능 (`/tmp` 가 이 방식) | `drwxrwx--T` |

**setgid가 없으면 생기는 일:** `agent-dev` 가 `upload_files` 에 파일을 만들면 그룹이 `agent-dev`(개인 그룹)가 됩니다 → `agent-test` 는 그 파일을 읽을 수 없습니다. 공유 디렉토리가 공유되지 않는 것이죠.

### 1-3. umask와 그 한계

새 파일의 권한 = `666 & ~umask` (디렉토리는 `777 & ~umask`). umask 가 `022` 인 사용자가 만든 파일은 `644` → **그룹 쓰기 불가**. 사용자마다, 접속 방식(SSH/cron/sudo)마다 umask 가 다를 수 있어 **umask에 의존하면 공유가 깨집니다.**

### 1-4. ACL (Access Control List)

기본 권한(user/group/other 3칸)으로 표현 못 하는 규칙을 추가합니다.

| ACL 항목 | 의미 | 예 |
|---|---|---|
| `user:이름:rwx` | 특정 사용자에게 | `u:agent-dev:r-x` |
| `group:이름:rwx` | 특정 그룹에게 | `g:agent-common:--x` |
| `mask::rwx` | 그룹 계열(named user/group, 소유 그룹) 권한의 **상한** | `chmod g=` 로 바뀜 |
| `default:...` | (디렉토리 전용) **안에 새로 생기는 파일/디렉토리가 상속**할 ACL | `d:g::rwx` |

**Default ACL이 umask 문제를 해결합니다.** 디렉토리에 default ACL이 있으면 새 파일에 **umask 대신 default ACL이 적용**됩니다. 누가 어떤 umask로 만들든 그룹 R/W가 보장됩니다.

`ls -l` 결과 끝에 `+` 가 붙으면 ACL이 있다는 뜻입니다: `drwxrws---+`

### 1-5. 왜 공유/보안 디렉토리를 분리하나

| | 공유 (`upload_files`) | 보안 (`api_keys`, 로그) |
|---|---|---|
| 담기는 것 | 작업 파일, 업로드 데이터 | **비밀 값**, 운영 기록 |
| 유출 시 피해 | 제한적 | API 키 → 외부 서비스 도용 / 로그 → 내부 구조·IP 노출, **로그 변조 → 사고 은폐** |
| 접근자 | 모든 협업자 (admin·dev·test) | 운영 핵심 인원 (admin·dev) |

한 디렉토리에 섞으면 "업로드만 필요한 QA"도 키를 볼 수 있게 됩니다. **데이터의 민감도가 다르면 권한 경계를 나눈다** 가 핵심입니다.

---

## 2. 실습

### 2-1. 문제 관찰: 홈 디렉토리 통과 권한

```bash
ops@vm$ ls -ld /home/agent-admin
# drwxr-x--- 2 agent-admin agent-admin ... /home/agent-admin     ← 750 (Ubuntu 21.04+ 기본값)
```

`AGENT_HOME` 이 `/home/agent-admin` 아래에 있는데, `agent-dev`, `agent-test` 는 이 디렉토리의 other 에 해당하므로 **통과(x)조차 못 합니다.**

| 해결 방법 | 문제점 |
|---|---|
| `chmod 755 /home/agent-admin` | **모든 사용자**가 홈 목록을 볼 수 있음 (과잉 허용) |
| `chmod 751` | 모든 사용자가 통과 가능 (여전히 과잉) |
| **ACL: `agent-common` 에게만 `--x`** | ✅ 필요한 그룹에만, 필요한 최소 권한(통과만, 목록 보기 불가) |

```bash
ops@vm$ sudo setfacl -m g:agent-common:--x /home/agent-admin
ops@vm$ getfacl -p /home/agent-admin
# # file: /home/agent-admin
# # owner: agent-admin
# # group: agent-admin
# user::rwx
# group::r-x
# group:agent-common:--x
# mask::r-x
# other::---
```

### 2-2. 디렉토리 생성

`$AH` 는 00장에서 `~/.bashrc` 에 넣어 둔 약칭입니다. (앱용 정식 환경 변수 `AGENT_HOME` 은 05장에서 고정합니다.)

```bash
ops@vm$ echo $AH          # /home/agent-admin/agent-app

# 앱 홈
ops@vm$ sudo mkdir -p $AH
ops@vm$ sudo chown agent-admin:agent-common $AH
ops@vm$ sudo chmod 2750 $AH

# 공유 디렉토리
ops@vm$ sudo mkdir -p $AH/upload_files
ops@vm$ sudo chown agent-admin:agent-common $AH/upload_files
ops@vm$ sudo chmod 2770 $AH/upload_files

# 보안 디렉토리: API 키
ops@vm$ sudo mkdir -p $AH/api_keys
ops@vm$ sudo chown agent-admin:agent-core $AH/api_keys
ops@vm$ sudo chmod 2770 $AH/api_keys

# 스크립트 디렉토리 (06장 monitor.sh). 작성자 agent-dev, 실행은 agent-core
ops@vm$ sudo mkdir -p $AH/bin
ops@vm$ sudo chown agent-dev:agent-core $AH/bin
ops@vm$ sudo chmod 2750 $AH/bin

# 보안 디렉토리: 로그
ops@vm$ sudo mkdir -p /var/log/agent-app
ops@vm$ sudo chown agent-admin:agent-core /var/log/agent-app
ops@vm$ sudo chmod 2770 /var/log/agent-app
```

`2770` 을 풀어 읽으면: setgid(2) + 소유자 rwx(7) + 그룹 rwx(7) + other 없음(0).

### 2-3. Default ACL — 새 파일도 그룹 R/W 를 상속하도록

```bash
ops@vm$ sudo setfacl -d -m u::rwx,g::rwx,o::--- \
          $AH/upload_files $AH/api_keys /var/log/agent-app
```

- `-d` : default ACL 을 설정 (디렉토리에 새로 생기는 것에 적용)
- `g::rwx` : "소유 그룹"(setgid 덕분에 항상 디렉토리의 그룹)에게 rwx → 파일은 실행 비트가 빠져 `rw-`
- `o::---` : 그 외 사용자는 아무 권한 없음

```bash
ops@vm$ sudo getfacl -p $AH/api_keys
# # file: /home/agent-admin/agent-app/api_keys
# # owner: agent-admin
# # group: agent-core
# # flags: -s-                 ← setgid
# user::rwx
# group::rwx
# other::---
# default:user::rwx
# default:group::rwx
# default:other::---
```

### 2-4. 구조 확인

```bash
ops@vm$ sudo ls -la $AH
# drwxr-s--- 5 agent-admin agent-common ... .
# drwxr-s--- 2 agent-dev   agent-core   ... bin
# drwxrws---+ 2 agent-admin agent-core   ... api_keys
# drwxrws---+ 2 agent-admin agent-common ... upload_files
ops@vm$ ls -ld /var/log/agent-app
# drwxrws---+ 2 agent-admin agent-core ... /var/log/agent-app

# 경로상 모든 디렉토리 권한을 한 번에
# (ops 는 agent-common 이 아니므로 /home/agent-admin 을 통과할 수 없다 → 확인 명령에도 sudo 필요)
ops@vm$ sudo namei -l $AH/api_keys
```

### 2-5. 권한 검증 — "되어야 하는 것"과 "안 되어야 하는 것" 모두

보안 설정은 **허용 테스트(positive)** 만큼 **차단 테스트(negative)** 가 중요합니다.

```bash
ops@vm$ cat > /tmp/permtest.sh <<'EOF'
AH=/home/agent-admin/agent-app
chk() { if sudo -u "$1" bash -c "$2" >/dev/null 2>&1; then echo "O"; else echo "X"; fi; }
printf '%-40s %-12s %-12s %-12s\n' "작업" agent-admin agent-dev agent-test
while IFS='|' read -r label cmd; do
  printf '%-40s' "$label"
  for u in agent-admin agent-dev agent-test; do
    c="${cmd//@U@/$u}"; printf ' %-12s' "$(chk $u "$c")"
  done; echo
done <<T
upload_files 파일 생성/삭제|touch $AH/upload_files/.t_@U@ && rm $AH/upload_files/.t_@U@
api_keys 목록 보기|ls $AH/api_keys
api_keys 파일 생성/삭제|touch $AH/api_keys/.t_@U@ && rm $AH/api_keys/.t_@U@
/var/log/agent-app 파일 생성/삭제|touch /var/log/agent-app/.t_@U@ && rm /var/log/agent-app/.t_@U@
bin 목록 보기|ls $AH/bin
T
EOF
ops@vm$ bash /tmp/permtest.sh
```

기대 결과:

```
작업                                      agent-admin  agent-dev    agent-test
upload_files 파일 생성/삭제                O            O            O
api_keys 목록 보기                         O            O            X
api_keys 파일 생성/삭제                    O            O            X
/var/log/agent-app 파일 생성/삭제          O            O            X
bin 목록 보기                              O            O            X
```

✅ 체크포인트: 위 표와 정확히 일치. 📸 스크린샷을 남깁니다.

### 2-6. Default ACL + setgid 효과 확인 (중요 실험)

```bash
# agent-dev 가 공유 디렉토리에 파일을 만든다 (umask 를 일부러 077 로 가장 엄격하게)
ops@vm$ sudo -u agent-dev bash -c 'umask 077; echo hello > /home/agent-admin/agent-app/upload_files/from-dev.txt'
ops@vm$ sudo ls -l $AH/upload_files/from-dev.txt
# -rw-rw---- 1 agent-dev agent-common 6 ... from-dev.txt
#      ↑ umask 077 이었는데도 그룹 rw     ↑ 그룹이 agent-dev 가 아니라 agent-common (setgid)

# agent-test 가 그 파일을 수정할 수 있는가?
ops@vm$ sudo -u agent-test bash -c 'echo "qa checked" >> /home/agent-admin/agent-app/upload_files/from-dev.txt' && echo OK
ops@vm$ sudo rm $AH/upload_files/from-dev.txt
```

> 비교 실험(선택): `sudo setfacl -k $AH/upload_files` (default ACL 제거) 후 같은 실험을 하면 `-rw-------` 가 되어 agent-test 가 실패합니다. 확인 후 2-3 을 다시 실행해 복구하세요.

---

## 3. 트러블슈팅

| 증상 | 원인/해결 |
|---|---|
| `setfacl: command not found` | `sudo apt install acl` |
| `setfacl: Operation not supported` | 파일시스템이 ACL 미지원(드묾). ext4 는 기본 지원 |
| 그룹 권한을 줬는데 안 됨 | ① 경로 중간 디렉토리 `x` 부족 → `namei -l` ② 그룹 추가 후 재로그인 안 함 ③ ACL `mask` 가 권한을 깎음 → `getfacl` 에서 `#effective:` 확인 |
| `chmod` 후 ACL 이 이상해짐 | ACL 이 있는 파일에 `chmod g=...` 하면 **mask** 가 바뀝니다. 권한을 다시 `getfacl` 로 확인 |

---

## 🤖 현장 노트 — 로봇의 파일시스템 보안

1. **업로드 디렉토리는 공격면이다** — 외부에서 들어온 파일이 실행되면 안 됩니다. 현장에서는 업로드 영역을 별도 파티션으로 두고 `noexec,nosuid,nodev` 로 마운트합니다. 공유 디렉토리에 **sticky bit**(`chmod +t`)를 더해 "남의 파일은 못 지우게" 하기도 합니다.
2. **파일 권한은 암호화가 아니다** — 로봇은 **도난·분실**될 수 있습니다. 디스크를 떼어 다른 PC에 꽂으면 `chmod` 는 의미가 없습니다. 그래서 현장 로봇은 **디스크 암호화(LUKS) + TPM 자동 잠금 해제**를 쓰고, API 키는 로봇마다 **다른 키(기기별 자격증명)** 를 발급해 한 대가 털려도 그 키만 폐기합니다. ([F3](field/F3_서비스운영_systemd_로그_시크릿.md))
3. **키 파일은 읽기 전용이 원칙** — 미션은 `api_keys` 디렉토리 R/W 를 요구하지만, 현장에서 키 파일 자체는 `0440`(소유자·그룹 읽기만)으로 두고 교체(rotation) 시에만 배포 도구가 씁니다.
4. **무결성 감시** — 설정·바이너리가 몰래 바뀌었는지 `AIDE` 같은 도구로 해시를 비교하거나, 중요 설정에 `chattr +i`(불변 속성)를 걸기도 합니다.
5. **`/home` 대신 `/opt`, `/srv`** — FHS 관례상 서비스 앱은 `/opt/<앱>` 에 둡니다. 사람 홈 아래에 서비스를 두면 이번 장처럼 홈 디렉토리 권한 문제가 생깁니다. 미션 예시를 따라 `/home/agent-admin` 을 썼지만, 현업 설계라면 `/opt/agent-app` 을 권장합니다.

---

## 📝 수행 내역서에 기록할 것

- 권한 설계 표 (이 장 맨 위 표) + **왜 그렇게 설계했는지**
- 실행한 `mkdir/chown/chmod/setfacl` 명령
- 증거: `ls -la $AH`, `ls -ld /var/log/agent-app`, `getfacl` 출력, `namei -l` 출력
- 증거: 2-5 권한 매트릭스 결과 (특히 agent-test 의 X)

## 🧠 자기 점검

1. 디렉토리의 `r` 과 `x` 는 각각 무엇을 허용하는가? `x` 만 있으면 무엇이 가능한가?
2. setgid 디렉토리가 없으면 공유 디렉토리에서 어떤 문제가 생기는가?
3. umask 에 의존하지 않고 default ACL 을 쓰는 이유는?
4. `/home/agent-admin` 을 `755` 로 여는 대신 ACL `g:agent-common:--x` 를 쓴 이유는?
5. API 키와 로그를 `agent-core` 로만 제한해야 하는 이유를 각각 설명하시오. (로그는 왜 "쓰기"까지 제한해야 하는가?)

⬅️ 이전: [03_계정과_그룹](03_계정과_그룹.md) | ➡️ 다음: [05_환경변수와_앱실행](05_환경변수와_앱실행.md)
