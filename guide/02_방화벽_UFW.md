# 02. 방화벽 — UFW로 "필요한 포트만 허용"

## 이 장의 목표

| 미션 요구사항 | 확인 방법 |
|---|---|
| UFW 활성화 | `ufw status` → `Status: active` |
| 인바운드 허용: **TCP 20022(SSH), TCP 15034(APP) 만** | `ufw status verbose` 에 두 규칙만 존재, 기본 정책 `deny (incoming)` |

그리고 다음을 **설명할 수 있어야** 합니다.
> "필요 포트만 허용"하는 방화벽 정책을 어떻게 구성하고 검증하는가?

---

## 1. 개념

### 1-1. UFW는 무엇인가

```
 ufw (사용자 명령) ──▶ iptables/nftables 규칙 생성 ──▶ 커널 netfilter 가 패킷 검사
 "Uncomplicated FireWall"                              (실제 차단은 커널이 한다)
```

- 리눅스 방화벽의 실체는 커널의 **netfilter** 입니다. `iptables`/`nftables` 는 그 규칙을 다루는 도구이고, **UFW는 그 위의 쉬운 프런트엔드**입니다.
- 미션은 UFW / firewalld 중 택1입니다. **Ubuntu 기본 도구가 UFW** 이므로 UFW를 씁니다. (firewalld는 RHEL/Rocky 계열의 기본)

### 1-2. 화이트리스트(Default Deny) 정책

| 방식 | 규칙 | 평가 |
|---|---|---|
| 블랙리스트 | 기본 허용, 위험한 것만 막음 | ❌ 모르는 위험은 못 막음 |
| **화이트리스트** | **기본 차단, 필요한 것만 허용** | ✅ 새로 생긴 서비스도 자동으로 막힘 |

```
default deny incoming   ← 들어오는 연결은 기본 차단
default allow outgoing  ← 나가는 연결은 기본 허용
allow 20022/tcp         ← 예외 1: SSH
allow 15034/tcp         ← 예외 2: 앱
```

### 1-3. Stateful — 응답 패킷은 왜 막히지 않는가

UFW는 **연결 상태를 추적(conntrack)** 합니다. VM이 먼저 밖으로 연결(`apt update` 등)을 열면, 그 **응답 패킷은 "ESTABLISHED" 상태**로 자동 허용됩니다. 그래서 incoming 을 deny 해도 인터넷 사용이 가능합니다.

### 1-4. "LISTEN 중인 포트" ≠ "방화벽이 허용한 포트"

| 상태 | 외부에서 보이는 결과 |
|---|---|
| 방화벽 허용 + 프로세스 LISTEN | ✅ 연결 성공 |
| 방화벽 허용 + LISTEN 없음 | `Connection refused` (커널이 RST 응답) |
| 방화벽 차단(deny = DROP) | **timeout** (아무 응답 없음) |

두 겹의 통제(서비스 자체 + 방화벽)가 겹치는 것이 **심층 방어**입니다. 누군가 실수로 디버그 서버를 띄워도 방화벽이 막아줍니다.

### 1-5. IPv6

Ubuntu의 UFW는 기본으로 IPv6 규칙도 함께 만듭니다(`/etc/ufw/default` 의 `IPV6=yes`). `ufw status` 에 `(v6)` 줄이 같이 보이는 이유입니다. **IPv4만 막고 IPv6를 열어두는 실수**가 현업에서 자주 발생합니다.

---

## 2. 실습

### 2-0. 전제 확인

```bash
ops@vm$ sudo ss -tulnp | grep sshd      # 01장 완료: 20022 에서 LISTEN
ops@vm$ sudo ufw status verbose
# Status: inactive
```

- [ ] VM 콘솔 창이 열려 있다.
- [ ] 지금 SSH 접속이 **20022** 로 되어 있다.

### 2-1. (필요 시) 기존 규칙 초기화

이전에 UFW를 만진 적이 있다면 깨끗하게 시작합니다. 처음이라면 건너뜁니다.

```bash
ops@vm$ sudo ufw --force reset     # 모든 규칙 삭제 + 비활성화 (백업 파일이 /etc/ufw 에 남음)
```

### 2-2. 기본 정책

```bash
ops@vm$ sudo ufw default deny incoming
ops@vm$ sudo ufw default allow outgoing
ops@vm$ sudo ufw default deny routed      # 로봇이 라우터 역할을 할 일은 없다
```

### 2-3. 허용 규칙 (정확히 두 개)

```bash
ops@vm$ sudo ufw allow 20022/tcp comment 'SSH (custom port)'
ops@vm$ sudo ufw allow 15034/tcp comment 'agent-app'
```

> `/tcp` 를 빼면 TCP와 **UDP 둘 다** 열립니다. 미션은 TCP만 요구하므로 반드시 프로토콜을 지정합니다. (최소 허용)
>
> `ufw allow OpenSSH` (앱 프로파일)를 쓰면 **22번**이 열립니다. 포트를 바꿨으므로 쓰지 않습니다.

### 2-4. 활성화 전 검토

```bash
ops@vm$ sudo ufw show added
# ufw allow 20022/tcp comment 'SSH (custom port)'
# ufw allow 15034/tcp comment 'agent-app'
```

여기에 `22`, `OpenSSH` 등 다른 규칙이 있으면 `sudo ufw delete allow 22` 등으로 지웁니다.

### 2-5. 활성화

```bash
ops@vm$ sudo ufw enable
# Command may disrupt existing ssh connections. Proceed with operation (y|n)? y
# Firewall is active and enabled on system startup
```

> 현장이라면 여기서 "5분 뒤 자동 원복" 을 걸어 둡니다 → 아래 🤖 현장 노트 참고.

### 2-6. 검증 ① — 설정

```bash
ops@vm$ sudo ufw status verbose
# Status: active
# Logging: on (low)
# Default: deny (incoming), allow (outgoing), deny (routed)
# New profiles: skip
#
# To                         Action      From
# --                         ------      ----
# 20022/tcp                  ALLOW IN    Anywhere                   # SSH (custom port)
# 15034/tcp                  ALLOW IN    Anywhere                   # agent-app
# 20022/tcp (v6)             ALLOW IN    Anywhere (v6)              # SSH (custom port)
# 15034/tcp (v6)             ALLOW IN    Anywhere (v6)              # agent-app

ops@vm$ sudo ufw status numbered     # 규칙 번호 (삭제할 때 사용)
ops@vm$ systemctl is-enabled ufw     # enabled → 재부팅 후에도 유지
ops@vm$ grep ENABLED /etc/ufw/ufw.conf
# ENABLED=yes
```

✅ 체크포인트: `ALLOW IN` 규칙이 **20022/tcp, 15034/tcp (+ v6)** 뿐이고 `Default: deny (incoming)`.

### 2-7. 검증 ② — 실제 패킷으로 확인 (내 PC에서)

`nc`(netcat)의 `-z`(연결만 시도), `-v`(결과 출력), `-w 3`(3초 타임아웃)을 씁니다.

```bash
# (a) 허용 + LISTEN → 성공
mac$ nc -vz -w 3 <VM_IP> 20022
# Connection to <VM_IP> port 20022 [tcp/*] succeeded!

# (b) 허용 + LISTEN 없음(앱 미실행) → refused
mac$ nc -vz -w 3 <VM_IP> 15034
# connect to <VM_IP> port 15034 (tcp) failed: Connection refused

# (c) 차단 → timeout (응답 자체가 없음)
mac$ nc -vz -w 3 <VM_IP> 22
# ... Operation timed out
```

**"기본 차단"을 눈으로 확인하는 실험** — VM에서 임시 웹서버를 띄워 봅니다.

```bash
ops@vm$ python3 -m http.server 8080          # 터미널 B 에서, 실행 상태로 둔다
mac$    nc -vz -w 3 <VM_IP> 8080             # timeout → LISTEN 중이어도 방화벽이 막음
ops@vm$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # 200 → VM 내부에서는 됨
# 확인 후 Ctrl+C 로 종료
```

✅ 체크포인트: (a) succeeded, (b) refused, (c) timeout, 8080 은 외부 timeout / 내부 200.

📸 스크린샷: `ufw status verbose` 와 (a)(b)(c) 결과.

### 2-8. 차단 로그 보기

```bash
ops@vm$ sudo ufw logging low        # 기본값. 차단된 패킷을 커널 로그에 남김
ops@vm$ sudo journalctl -k --since "10 min ago" | grep 'UFW BLOCK' | tail -n 3
# ... [UFW BLOCK] IN=enp0s1 ... SRC=192.168.64.1 DST=192.168.64.5 ... PROTO=TCP SPT=... DPT=22 ...
```

`DPT=22`(목적지 포트), `SRC`(누가) 를 읽을 수 있으면 됩니다. 방금 2-7 (c) 에서 여러분이 보낸 패킷입니다.

---

## 3. 트러블슈팅

| 증상 | 원인/해결 |
|---|---|
| `ufw enable` 후 SSH 끊김 | 20022 규칙 누락. **VM 콘솔**에서 `sudo ufw allow 20022/tcp` |
| `(v6)` 규칙이 없다 | `/etc/ufw/default` 의 `IPV6=yes` 확인 후 `sudo ufw reload` |
| 22 규칙이 남아 있다 | `sudo ufw status numbered` → `sudo ufw delete <번호>` (번호는 삭제할 때마다 바뀌니 매번 다시 조회) |
| 15034 가 계속 refused | 정상. 앱은 05장에서 실행한다 |

---

## 🤖 현장 노트 — 로봇의 방화벽은 서버보다 까다롭다

**1) 원격 방화벽 변경의 안전장치: dead man's switch**

```bash
# 활성화 직전에 "5분 뒤 자동 비활성화"를 예약
echo 'ufw disable' | sudo at now + 5 minutes
sudo ufw enable
# 새 SSH 세션으로 접속되는지 확인한 뒤 예약 취소
sudo atq && sudo atrm <번호>
```
잘못된 규칙으로 잠겨도 5분 뒤 스스로 풀립니다. 원격 기기 운영에서 가장 많이 쓰이는 패턴입니다.

**2) "어디서" 들어오는지까지 제한** — 미션은 `Anywhere` 지만 현장은 다릅니다.
```bash
sudo ufw allow in on wg0 to any port 20022 proto tcp          # VPN 인터페이스로만 SSH
sudo ufw allow from 10.20.0.0/16 to any port 15034 proto tcp  # 관제 서버 대역에서만 앱 접근
sudo ufw limit 20022/tcp    # 30초에 6회 이상 연결 시도하는 IP 일시 차단(rate limit)
```

**3) Docker는 UFW를 우회한다** ⚠️ — 로봇 소프트웨어를 Docker로 배포하는 회사가 많습니다. `docker run -p 8080:80` 으로 공개한 포트는 Docker가 iptables 에 **UFW보다 먼저 평가되는 규칙**을 넣기 때문에 `ufw deny` 로 막히지 않습니다. `ufw status` 만 보고 "안전하다" 판단하면 안 되며, 반드시 **외부에서 nc/nmap 으로 실측**해야 합니다(2-7 의 방식).

**4) ROS 2 / DDS** — ROS 2 노드는 UDP 멀티캐스트(7400번대 포트)로 서로를 찾습니다. Default Deny 를 켜면 로봇 내부 통신(예: 본체 PC ↔ 센서 보드)이 끊깁니다. 현장에서는 **내부 인터페이스(eth1 등)만 DDS 포트를 허용**하고, 외부(Wi-Fi) 인터페이스는 막습니다.

**5) 정기 감사** — "허용 규칙 목록"과 "실제 LISTEN 포트"를 주기적으로 비교해, 허용되지 않은 LISTEN(=누군가 몰래 띄운 서비스) 이나 쓰이지 않는 허용 규칙(=정리 대상)을 찾아냅니다. 06장의 monitor.sh 가 방화벽 활성 상태를 점검하는 이유이기도 합니다.

---

## 📝 수행 내역서에 기록할 것

- 실행한 `ufw default ...`, `ufw allow ...`, `ufw enable` 명령
- 증거: `ufw status verbose` 출력 (v6 포함)
- 증거: 내 PC에서 `nc` 로 20022(성공) / 22(차단) 확인 결과
- UFW를 선택한 이유 한 줄

## 🧠 자기 점검

1. `default deny incoming` 인데도 VM에서 `apt update` 가 되는 이유는?
2. 외부에서 봤을 때 "Connection refused" 와 "timeout" 은 각각 무엇을 의미하는가?
3. `ufw allow 15034` 와 `ufw allow 15034/tcp` 의 차이는?
4. `ufw status` 가 active 이면 모든 포트가 안전하다고 말할 수 없는 사례를 하나 드시오.
5. 방화벽 규칙을 검증하는 두 가지 방법(설정 확인 / 실측)을 설명하시오.

⬅️ 이전: [01_SSH_보안설정](01_SSH_보안설정.md) | ➡️ 다음: [03_계정과_그룹](03_계정과_그룹.md)
