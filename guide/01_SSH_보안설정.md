# 01. SSH 보안 설정 — 포트 20022, Root 원격 로그인 차단

## 이 장의 목표

| 미션 요구사항 | 확인 방법 |
|---|---|
| SSH 접속 포트를 **20022** 로 변경 | `sshd -T`, `ss -tulnp` 에서 sshd 가 20022 에서 LISTEN |
| **Root 원격 로그인 차단** | `sshd -T` 에서 `permitrootlogin no`, 실제 root 접속 거부 |

그리고 다음을 **설명할 수 있어야** 합니다.
> SSH 포트 변경과 Root 원격 접속 차단이 왜 기본 보안에 해당하는가?

---

## 1. 개념

### 1-1. SSH와 sshd

```
 내 PC (ssh 클라이언트)  ──TCP──▶  VM (sshd 데몬, 기본 22번 포트에서 대기)
                                    │
                                    ├ /etc/ssh/sshd_config          메인 설정
                                    └ /etc/ssh/sshd_config.d/*.conf  추가(drop-in) 설정
```

- `sshd` 는 접속을 기다리는 **데몬(서버 프로세스)** 입니다. 접속이 오면 **자식 프로세스를 fork** 해 그 세션을 맡깁니다.
  → 그래서 `sshd` 를 재시작해도 **이미 연결된 세션은 끊기지 않습니다.** (이 성질 덕분에 안전하게 설정을 바꿀 수 있습니다.)
- Ubuntu 22.04에서 서비스 이름은 `ssh.service` 입니다. (`sshd` 가 아님)

### 1-2. 왜 포트를 바꾸는가 — 정확히 이해하기

인터넷에 노출된 22번 포트에는 **봇이 초 단위로** 로그인을 시도합니다. 포트를 바꾸면:

| 효과 | 설명 |
|---|---|
| ✅ 자동화 공격(무차별 대입) 소음 급감 | 대부분의 봇은 22번만 두드린다 |
| ✅ 로그가 깨끗해짐 | 진짜 이상 징후가 소음에 묻히지 않는다 |
| ❌ 표적 공격은 못 막음 | 포트 스캔(nmap) 한 번이면 20022 가 보인다 |

즉 포트 변경은 **"은폐를 통한 보안(Security through obscurity)"** 으로, **단독으로는 보안이 아니고** 방화벽·키 인증·root 차단과 **겹쳐 쓸 때(심층 방어, Defense in Depth)** 의미가 있습니다. 면접이나 리뷰에서 "포트 바꿨으니 안전하다"고 말하면 감점입니다.

### 1-3. 왜 root 원격 로그인을 막는가

| 이유 | 설명 |
|---|---|
| **이름이 알려진 계정** | 공격자는 사용자 이름을 추측할 필요 없이 비밀번호만 맞히면 된다 |
| **최고 권한** | 뚫리는 순간 시스템 전체가 넘어간다. 중간 방어선이 없다 |
| **책임 추적 불가** | 여러 명이 root 로 들어오면 "누가 했는지" 로그에 남지 않는다 |

올바른 흐름: **개인 계정으로 로그인 → 필요한 순간에만 `sudo`** → `sudo` 사용 기록이 `/var/log/auth.log` 에 사용자 이름과 함께 남는다.

> Ubuntu 는 설치 시 root 비밀번호가 잠겨 있어 원래도 root 비밀번호 로그인이 어렵습니다. 그래도 `PermitRootLogin no` 를 명시하는 이유는, **누군가 나중에 root 비밀번호를 설정하거나 root 에 SSH 키를 추가해도** 원격 로그인이 막히도록 "정책"으로 고정하기 위해서입니다.

### 1-4. sshd 설정 읽는 규칙 (중요)

1. `sshd_config` 는 **위에서 아래로** 읽고, 같은 키워드는 **처음 나온 값이 이깁니다** (first match wins).
2. Ubuntu 22.04 의 `sshd_config` 맨 위쪽에 `Include /etc/ssh/sshd_config.d/*.conf` 가 있어, drop-in 파일이 **메인 파일보다 먼저** 읽힙니다.
3. drop-in 파일은 **이름순**으로 읽힙니다. 클라우드 이미지에는 `50-cloud-init.conf` 가 있을 수 있으므로 우리 파일은 `10-` 으로 시작해 먼저 읽히게 합니다.
4. ⚠️ **`Port` 는 예외로 누적됩니다.** 메인 파일에 `Port 22` 가 주석 해제되어 있으면 22 와 20022 를 **둘 다** 엽니다.

> 왜 메인 파일을 직접 고치지 않고 drop-in 을 쓰나?
> `apt upgrade` 로 openssh-server 가 업데이트될 때 메인 파일 수정분과 충돌하면 설치가 멈추고 질문을 던집니다. 원격 로봇에서 이런 대화형 프롬프트는 자동 업데이트를 망가뜨립니다. **우리 설정은 우리 파일에** 두면 패키지 업데이트와 충돌하지 않습니다.

---

## 2. 실습

### 2-0. 준비: 비상 출입구 확보

- [ ] VM 콘솔 창에 `ops` 로 로그인되어 있다.
- [ ] 내 PC에서 SSH 터미널 A 가 열려 있다.

### 2-1. 현재 상태 관찰 (변경 전 기록)

```bash
ops@vm$ sudo ss -tulnp | grep sshd
# tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=...,fd=3))
# tcp LISTEN 0 128    [::]:22    [::]:* users:(("sshd",pid=...,fd=4))

ops@vm$ grep -n 'Include' /etc/ssh/sshd_config
# 12:Include /etc/ssh/sshd_config.d/*.conf    ← 위쪽에 있는 것 확인

ops@vm$ ls -l /etc/ssh/sshd_config.d/

# 메인 파일에 "활성화된" Port / PermitRootLogin 이 있는지 (주석 # 이 아닌 줄)
ops@vm$ grep -nE '^[[:space:]]*(Port|PermitRootLogin)' /etc/ssh/sshd_config
# 아무것도 안 나오면 정상 (22.04 기본값은 모두 주석 처리되어 있음)

ops@vm$ sudo sshd -T | grep -Ei '^(port|permitrootlogin) '
# port 22
# permitrootlogin without-password    ← 기본값: 키로는 root 로그인 허용 상태!
```

> `ss -tulnp` 옵션: **t**cp, **u**dp, **l**isten 상태만, **n**umeric(포트 번호를 이름으로 바꾸지 않음), **p**rocess(어떤 프로세스인지, root 권한 필요)
>
> `sshd -T` 는 설정 파일들을 모두 합쳐 **sshd 가 실제로 적용할 최종 값**을 출력합니다. 파일을 grep 하는 것보다 훨씬 정확한 검증 방법입니다.

### 2-2. 백업

```bash
ops@vm$ sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)
```

### 2-3. drop-in 설정 파일 작성

직접 작성해 보는 것을 권장합니다.

```bash
ops@vm$ sudo nano /etc/ssh/sshd_config.d/10-agent-hardening.conf
```

```
# 미션 필수
Port 20022
PermitRootLogin no

# 현업 권장 (선택)
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
```

또는 저장소의 원본을 설치합니다 (주석으로 각 줄의 의미가 설명되어 있음).

```bash
ops@vm$ sudo install -m 644 -o root -g root \
          $REPO/config/ssh/10-agent-hardening.conf /etc/ssh/sshd_config.d/
```

> `install` 명령은 **복사 + 소유자 + 권한 설정**을 한 번에 합니다. `cp` 후 `chown`, `chmod` 를 따로 하다가 중간 상태(잘못된 권한의 파일)가 생기는 것을 막습니다.

2-1 에서 메인 파일에 활성화된 `Port 22` 가 있었다면 주석 처리합니다.

```bash
ops@vm$ sudo sed -i 's/^[[:space:]]*Port 22/#Port 22/' /etc/ssh/sshd_config
```

### 2-4. 적용 전 검증 (절대 생략 금지)

```bash
# 1) 문법 검사: 아무 출력이 없으면 정상
ops@vm$ sudo sshd -t

# 2) 적용될 최종 값 미리 보기
ops@vm$ sudo sshd -T | grep -Ei '^(port|permitrootlogin|maxauthtries|x11forwarding) '
# port 20022
# permitrootlogin no
# maxauthtries 3
# x11forwarding no

# 3) 방화벽이 이미 켜져 있다면 새 포트부터 연다 (지금은 inactive 일 것)
ops@vm$ sudo ufw status
# Status: inactive  → 그대로 진행
# Status: active    → sudo ufw allow 20022/tcp  를 먼저 실행!
```

✅ 체크포인트: `sshd -t` 가 조용하고, `sshd -T` 에 `port 20022`, `permitrootlogin no` 가 보인다.

### 2-5. 적용

```bash
ops@vm$ sudo systemctl restart ssh
ops@vm$ systemctl status ssh --no-pager | head -n 5    # active (running)
ops@vm$ sudo ss -tulnp | grep sshd
# tcp LISTEN 0 128 0.0.0.0:20022 0.0.0.0:* users:(("sshd",...))
# tcp LISTEN 0 128    [::]:20022    [::]:* users:(("sshd",...))
```

22번이 사라지고 20022 만 남아야 합니다. **터미널 A 는 아직 끊지 마세요.**

### 2-6. 새 접속으로 검증 (터미널 B)

```bash
# ① 새 포트로 접속 → 성공해야 함
mac$ ssh -p 20022 ops@<VM_IP>

# ② 옛 포트 → 거부되어야 함
mac$ ssh -p 22 ops@<VM_IP>
# ssh: connect to host ... port 22: Connection refused

# ③ root 접속 → 거부되어야 함
mac$ ssh -p 20022 root@<VM_IP>
# root@...'s password:  (아무거나 입력)
# Permission denied, please try again.
```

③ 의 거부 기록을 서버 로그에서 확인합니다.

```bash
ops@vm$ sudo journalctl -u ssh --since "10 min ago" --no-pager | tail -n 20
# ... Failed password for root from 192.168.x.x port ... ssh2
# 또는 ROOT LOGIN REFUSED ...
```

✅ 체크포인트: ① 성공, ② Connection refused, ③ Permission denied. **이제서야** 터미널 A 를 닫아도 됩니다.

### 2-7. 내 PC의 SSH 설정 편의화

매번 `-p 20022` 를 치지 않도록 내 PC의 `~/.ssh/config` 에 추가합니다.

```
Host robot-01
    HostName <VM_IP>
    Port 20022
    User ops
```

```bash
mac$ ssh robot-01
mac$ scp -P 20022 파일 robot-01:~/     # scp 는 대문자 -P (config 가 있으면 생략 가능)
```

---

## 3. 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `sshd -t` 가 `Bad configuration option` | 오타 | 콘솔에서 파일 수정 후 다시 `sshd -t` |
| 22 와 20022 가 둘 다 열림 | 메인 파일에 활성 `Port 22` | 2-3 의 sed 로 주석 처리 후 재시작 |
| `sshd -T` 에 `permitrootlogin` 이 여전히 기본값 | drop-in 보다 먼저 읽히는 다른 파일에 설정이 있음 | `sudo grep -rn PermitRootLogin /etc/ssh/` 로 찾기 |
| 20022 로 접속 시 timeout | 방화벽(UFW 또는 하이퍼바이저 포트포워딩) | `sudo ufw status`, VM 네트워크 설정 확인 |
| 완전히 잠김 | — | **VM 콘솔**로 로그인 → 백업 파일 복원 또는 drop-in 삭제 → `systemctl restart ssh` |

---

## 🤖 현장 노트 — 원격 로봇의 SSH 변경 절차

현장의 로봇 100대에 SSH 설정을 배포한다고 생각해 봅시다. 한 대라도 잠기면 기술자가 현장에 가야 합니다.

1. **변경 전 롤백 경로 확보** — OOB 채널 확인, 또는 "N분 뒤 자동 원복" 예약:
   ```bash
   # 5분 뒤 drop-in 을 치우고 ssh 재시작 (확인 완료 후 atrm 으로 취소)
   echo 'rm -f /etc/ssh/sshd_config.d/10-agent-hardening.conf && systemctl restart ssh' | sudo at now + 5 minutes
   sudo atq            # 예약 번호 확인
   sudo atrm <번호>     # 새 접속 검증이 끝나면 취소
   ```
2. **순서** — 방화벽에 새 포트 허용 → sshd 설정 → `sshd -t` → 재시작 → **새 세션**으로 검증 → 기존 세션 종료.
3. **카나리 배포** — 1대 → 5% → 전체. 한 번에 전체에 배포하지 않는다.
4. **포트보다 중요한 것** — 현장에서는 포트 변경보다 아래가 훨씬 강력합니다. ([F2 문서](field/F2_원격접속과_네트워크.md)에서 실습)
   - **공개키 인증만 허용** (`PasswordAuthentication no`)
   - SSH를 **VPN(WireGuard 등) 인터페이스에서만** 받기 → 현장 Wi-Fi에서는 아예 안 보임
   - `AllowGroups` 로 접속 가능 그룹 제한
   - `fail2ban` 으로 반복 실패 IP 차단
5. **Ubuntu 22.10 이후 주의** — `ssh.socket`(소켓 활성화)이 기본이라 포트를 `sshd_config` 가 아니라 소켓 유닛이 엽니다. 22.04 → 24.04 업그레이드 시 포트 설정이 먹지 않는 사고가 실제로 많습니다. (`systemctl daemon-reload && systemctl restart ssh.socket` 필요) — **OS 버전 고정(Jammy)이 현장에서 중요한 이유** 중 하나입니다.

---

## 📝 수행 내역서에 기록할 것

- 작성한 `/etc/ssh/sshd_config.d/10-agent-hardening.conf` 내용
- 실행한 명령: `sshd -t`, `systemctl restart ssh`
- 증거: `sshd -T | grep -Ei '^(port|permitrootlogin) '` 출력, `ss -tulnp | grep sshd` 출력
- 증거: root 접속 거부 화면 + `journalctl -u ssh` 거부 로그 (스크린샷)
- 왜 drop-in 방식을 택했는지 한 줄

## 🧠 자기 점검

1. 포트를 20022로 바꾸는 것만으로 안전하다고 할 수 없는 이유는?
2. root 원격 로그인을 막으면 "책임 추적성"이 왜 좋아지는가?
3. `sshd` 를 재시작해도 기존 SSH 세션이 끊기지 않는 이유는?
4. 파일을 grep 하는 것보다 `sshd -T` 로 검증하는 것이 나은 이유는?
5. 메인 파일에 `Port 22` 가 살아 있으면 어떻게 되는가?

⬅️ 이전: [00_환경준비](00_환경준비.md) | ➡️ 다음: [02_방화벽_UFW](02_방화벽_UFW.md)
