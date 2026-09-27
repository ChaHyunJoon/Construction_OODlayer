#!/usr/bin/env python3
"""zrv_sandbox.py — branch worker 를 이 호스트에서 **무권한으로 강제 가능한** OS 경계 안에서 exec 한다(T4, 설계 §6.1).

    zrv_sandbox.py --write DIR [...] [--read DIR ...] [--list DIR ...] [--proc-file F ...] --cpu SECONDS --mem BYTES -- CMD ARGS...

무엇을 강제하나(전부 exec 전에 걸리고 자식 프로세스에 상속된다; 각각 음성 시험이 `test/repair_rollout.jl` 에 있다):
  * 새 세션/프로세스 그룹(`setsid`) — supervisor 가 `kill(-pgid)` 로 하위 트리째 정리한다.
  * PR_SET_PDEATHSIG=SIGKILL — supervisor 가 죽으면 worker 도 죽는다(setsid 로 떨어진 고아 방지; 직계만).
  * RLIMIT_CPU(초) · RLIMIT_AS(바이트) — 무한 loop·폭주 할당을 커널이 끊는다.
  * no_new_privs + Landlock(커널 LSM, 무권한 사용 가능 — `/sys/kernel/security/lsm` 에 `landlock`):
      - 파일 쓰기/생성/삭제: `--write` 디렉터리 아래만.
      - 디렉터리 **목록**(이름만, 내용 아님): `--list` 아래(선택 — 최종 리뷰 I5 뒤 branch runner 는 쓰지 않는다:
        git 지문은 부모가 계산해 넘기고 분기는 `.git` 을 못 읽는다).
      - 파일 읽기/실행: `--read` 디렉터리 아래 + `/proc/<자기 pid>` + `--proc-file` 뿐. 그래서 같은 uid 의
        다른 프로세스 `/proc/<pid>/environ`(API 키가 들어 있다)·`~/.ssh`·`~/.dspy_cache` 를 못 읽는다.
      - TCP connect: 전부 거절(ABI ≥ 4). bind 는 다루지 않는다(로컬 listen 은 유출 경로가 아니다).
      - scope(ABI ≥ 6): 도메인 밖 프로세스에 signal 금지, 도메인 밖 abstract unix socket 연결 금지.
무엇을 **못** 막나(그래서 enforce 모드를 열지 않는다 — `BranchRunner.sandbox_capabilities`):
  UDP·raw 소켓, pathname unix socket 연결, `--write` 안에서의 임의 쓰기, 같은 프로세스 안의 메서드 override.
Landlock 을 못 걸면(커널·ABI) **exec 하지 않고** 종료 코드 97 로 죽는다 — 경계 없이 조용히 돌지 않는다.
"""
import ctypes, os, resource, sys

SYS_create, SYS_add, SYS_restrict = 444, 445, 446          # x86_64 (landlock_*)
PR_SET_NO_NEW_PRIVS, PR_SET_PDEATHSIG = 38, 1
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long

FS = dict(EXECUTE=1 << 0, WRITE_FILE=1 << 1, READ_FILE=1 << 2, READ_DIR=1 << 3, REMOVE_DIR=1 << 4,
          REMOVE_FILE=1 << 5, MAKE_CHAR=1 << 6, MAKE_DIR=1 << 7, MAKE_REG=1 << 8, MAKE_SOCK=1 << 9,
          MAKE_FIFO=1 << 10, MAKE_BLOCK=1 << 11, MAKE_SYM=1 << 12, REFER=1 << 13, TRUNCATE=1 << 14,
          IOCTL_DEV=1 << 15)
FS_ABI = {1: 13, 2: 14, 3: 15, 5: 16}                     # 비트 수(ABI 별 추가분)
NET_CONNECT_TCP = 1 << 1
SCOPE_ABSTRACT_UNIX, SCOPE_SIGNAL = 1 << 0, 1 << 1


class Attr(ctypes.Structure):
    _fields_ = [("fs", ctypes.c_uint64), ("net", ctypes.c_uint64), ("scoped", ctypes.c_uint64)]


class PathBeneath(ctypes.Structure):
    _pack_ = 1
    _fields_ = [("allowed", ctypes.c_uint64), ("fd", ctypes.c_int32)]


def die(msg, code=97):
    sys.stderr.write("[zrv-sandbox] " + msg + "\n")
    sys.exit(code)


def abi():
    v = libc.syscall(SYS_create, None, 0, 1)                # LANDLOCK_CREATE_RULESET_VERSION
    return v if v > 0 else 0


def fs_mask(a):
    n = max(b for k, b in FS_ABI.items() if a >= k)
    return (1 << n) - 1


def add_path(rs, path, allowed, handled):
    try:
        fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    except FileNotFoundError:
        return
    # 파일에는 디렉터리 전용 권한을 줄 수 없다(EINVAL).
    if not os.path.isdir(path):
        allowed &= FS["EXECUTE"] | FS["WRITE_FILE"] | FS["READ_FILE"] | FS["TRUNCATE"] | FS["IOCTL_DEV"]
    pb = PathBeneath(allowed & handled, fd)
    if libc.syscall(SYS_add, rs, 1, ctypes.byref(pb), 0) != 0:
        die(f"landlock_add_rule({path}) errno={ctypes.get_errno()}")
    os.close(fd)


def main(argv):
    if "--" not in argv:
        die("usage: zrv_sandbox.py --write DIR ... --cpu S --mem B -- CMD ...", 2)
    i = argv.index("--")
    opts, cmd = argv[:i], argv[i + 1:]
    writes, reads, lists, procf, cpu, mem = [], [], [], [], None, None
    it = iter(opts)
    for o in it:
        v = next(it)
        if o == "--write": writes.append(v)
        elif o == "--read": reads.append(v)
        elif o == "--list": lists.append(v)
        elif o == "--proc-file": procf.append(v)
        elif o == "--cpu": cpu = int(v)
        elif o == "--mem": mem = int(v)
        else: die(f"unknown option {o}", 2)
    if not writes or cpu is None or mem is None or not cmd:
        die("--write, --cpu, --mem and a command are required", 2)

    os.setsid()
    libc.prctl(PR_SET_PDEATHSIG, 9, 0, 0, 0)
    if os.getppid() == 1:
        die("supervisor already gone")
    resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu + 5))
    resource.setrlimit(resource.RLIMIT_AS, (mem, mem))
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        die("prctl(NO_NEW_PRIVS) failed")
    a = abi()
    if a < 4:
        die(f"landlock ABI {a} < 4 (TCP connect cannot be restricted) — refusing to run unconfined")
    handled = fs_mask(a)
    attr = Attr(handled, NET_CONNECT_TCP, (SCOPE_ABSTRACT_UNIX | SCOPE_SIGNAL) if a >= 6 else 0)
    size = ctypes.sizeof(Attr) if a >= 6 else 16
    rs = libc.syscall(SYS_create, ctypes.byref(attr), size, 0)
    if rs < 0:
        die(f"landlock_create_ruleset errno={ctypes.get_errno()}")
    RX = FS["EXECUTE"] | FS["READ_FILE"] | FS["READ_DIR"]
    for p in reads:
        add_path(rs, p, RX, handled)
    for p in lists:
        add_path(rs, p, FS["READ_DIR"], handled)
    add_path(rs, f"/proc/{os.getpid()}", RX, handled)       # exec 뒤에도 같은 pid
    for p in procf:
        add_path(rs, p, FS["READ_FILE"], handled)
    for p in writes:
        add_path(rs, p, handled, handled)
    if libc.syscall(SYS_restrict, rs, 0) != 0:
        die(f"landlock_restrict_self errno={ctypes.get_errno()}")
    os.close(rs)
    sys.stdout.write(f"[zrv-sandbox] landlock_abi={a} scoped={'yes' if a >= 6 else 'no'} pid={os.getpid()}\n")
    sys.stdout.flush()
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
