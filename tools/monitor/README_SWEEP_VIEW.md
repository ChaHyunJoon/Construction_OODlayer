> 경로 변경(2026-09-23): 이 문서에는 과거 실행 경로가 포함되어 있습니다. 현재 구조는 [폴더 구조 안내](../../docs/simulation_layout.md)를 참고하세요.

# 30시드 스윕(results_4pol)을 모니터 대시보드로 보기

2026-08-12 밤 스윕이 남긴 판 630개(7 case × 30 seed × 3 policy, `tractor.mpd`, D=20)를
`tools/monitor/dashboard.html` 에서 **재생**하기 위한 절차다. 시뮬레이션을 다시 돌리지 않는다 —
데이터는 이미 디스크에 있고, 문제는 **이름과 자리**뿐이다.

---

## 1. 왜 발행(publish) 단계가 필요한가 — 어긋난 두 이름 규칙

스윕(`run_4pol.sh` → `run_shard.sh`)은 판마다 샤드 폴더에 스트림을 쓴다:

```
wm4spacecraft_manufacturing/results_4pol/shards/<case>/s<seed>/logs/stream_s<seed>_<policy>.jsonl
```

대시보드는 그 자리를 **모른다**. 서버(`server.jl`)의 `/artifact` 핸들러가 이름을 푸는 규칙은
완전히 다르다(`server.jl:242-248`, `seed_suffix` 는 `server.jl:69`):

```
streams/<base>__<case>__<policy><nsuf>.jsonl

  base = safe_base(model)              "tractor.mpd" → "tractor"   (확장자 제거 + 비영숫자 → "_")
  nsuf = (n>0 ? "_n<n>" : "") * seed_suffix(seed)
  seed_suffix(1) = ""   (그 외 = "_s<seed>")
```

대시보드가 `/artifact` 로 보내는 `n`·`seed` 는 상단 컨트롤의 값이고, **기본값은 `OOD events = 0`,
`OOD seed = 1`** 이다(`dashboard.html:340,344`). 즉 기본 화면에서 `nsuf` 는 빈 문자열이다:

| 스윕이 쓴 파일 | 대시보드가 찾는 파일 |
|---|---|
| `results_4pol/shards/all/s1/logs/stream_s1_noop.jsonl` | `tools/monitor/streams/tractor__all__noop.jsonl` |

`publish_streams.sh` 가 하는 일은 이 대응을 **심링크로** 걸어 주는 것뿐이다. 판 하나가 1~4 MB 라
630판이면 수백 MB 이므로 복사하지 않는다. 발행물은 `.gitignore` 로 배제돼 있다
(`tools/monitor/streams/`) — 커밋 대상이 아니다.

> **주의:** 대시보드 상단의 `OOD events` 를 0 이 아닌 값으로 바꾸면 서버는 `_n<N>` 이 붙은
> **다른 파일**을 찾는다. 그런 파일은 발행하지 않았으므로 "stream not found" 가 뜬다.
> 스윕 녹화를 볼 때는 **OOD events = 0, OOD seed = 1** 로 두어야 한다(둘 다 기본값이다).

---

## 2. 발행하기

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing
./render/publish_streams.sh --clean
```

기본 발행 범위 = **7 case × 3 policy × seed 1 = 21판** (대표 부분집합):

- case: `battery, fault, all, fault_battery, fault_zone, battery_zone, zone`
- policy: `noop, surrogate, dspy`
- seed: `1`

630판을 다 걸 필요는 없다 — 대시보드는 한 번에 한 판만 재생하고, seed 1 이 접미사 없는
"기본 녹화" 자리를 차지한다.

**더 발행하기:**

```bash
./render/publish_streams.sh --seeds 1,2,3                 # seed 2,3 은 tractor__<case>__<policy>_s2.jsonl 로
./render/publish_streams.sh --cases all,zone --policies noop,dspy
./render/publish_streams.sh --seeds $(seq -s, 1 30)       # 30시드 전부(90판/case, 심링크라 디스크는 안 쓴다)
```

시드 2 이상을 발행했으면 대시보드의 **`OOD seed` 를 그 숫자로** 바꿔야 그 파일을 가리킨다.

플래그: `--seeds`(기본 `1`) · `--cases`(기본 7종) · `--policies`(기본 `noop,surrogate,dspy`) ·
`--shards-dir`(기본 `results_4pol/shards`) · `--clean`(발행 폴더의 `*.jsonl` 을 먼저 비운다).

---

## 3. 서버 띄우기

```bash
cd /home/chahj578/Construction_OODlayer
julia +lts --project=. tools/monitor/server.jl
```

`[server] http://127.0.0.1:8080` 이 찍히면 준비된 것이다(첫 실행은 Julia 컴파일로 수 분 걸린다).
8080 이 이미 쓰이고 있으면 `MONITOR_PORT=8081 julia +lts --project=. tools/monitor/server.jl`.

---

## 4. 노트북에서 보기 (SSH 포트 포워딩)

서버는 **`127.0.0.1` 에만 바인딩한다**(`server.jl:278`). 서버 머신의 IP 로는 접속되지 않으므로
노트북에서 보려면 터널을 뚫어야 한다.

**노트북 터미널에서:**

```bash
ssh -N -L 8080:127.0.0.1:8080 <user>@<host>
```

그대로 두고(-N = 셸 없이 터널만), 노트북 브라우저에서 **<http://127.0.0.1:8080/>**.

노트북의 8080 이 이미 쓰이는 중이면 왼쪽 숫자만 바꾼다: `-L 9090:127.0.0.1:8080` → `http://127.0.0.1:9090/`.
서버 쪽 포트를 `MONITOR_PORT` 로 바꿨다면 오른쪽 숫자를 그 값으로 맞춘다.

**VS Code Remote-SSH 를 쓰는 경우** 터널을 직접 뚫을 필요가 없다. 원격 터미널에서 서버를 띄우면
VS Code 가 8080 을 자동 포워딩한다. 하단 **PORTS** 패널에 8080 행이 뜨고, 그 행의 지구본/링크
아이콘을 누르면 로컬 브라우저가 열린다. 자동으로 안 잡히면 PORTS 패널의 **Forward a Port** 로
`8080` 을 직접 추가한다.

---

## 5. ⚠ 3D 애니메이션은 없다 (빈 창이 정상이다)

스윕은 `run_demo.jl` 로 돌았다. **`run_demo.jl` 에는 MeshCat 렌더링이 없다** — 3D 녹화는
`render_demo.jl` 쪽 기능이고, 스윕은 그걸 쓰지 않았다(그래서 630판이 하룻밤에 들어갔다).

따라서:

- `/artifact` 응답의 **`anim_exists` 는 항상 `false`** 다.
- 화면 오른쪽 **Factory View 는 3D 장면 대신 안내문**("No 3D animation for this combination")을 띄운다.
- **이건 고장이 아니다.** 왼쪽의 2D/데이터 패널(로봇 상태, 배터리, 창고, RE-SPEC 결정 패널,
  후보 순위표)은 전부 정상 동작한다 — 스윕이 남긴 것은 그 데이터다.

3D 가 꼭 필요하면 그 조합만 `render_demo.jl` 로 따로 다시 돌려야 한다(판당 수 분 ~ 수십 분).

---

## 6. 대시보드 쪽 보완 (2026-08-13)

스윕을 보려면 `dashboard.html` 두 곳이 모자랐다:

- **`OOD_CASES` 에 `all` 추가** (⑧ All mixed). 세 종류가 한 스트림에서 섞이는 케이스로
  스윕 7 케이스 중 하나인데 목록에 없었다. 기존 `battery_mild`(⑦)는 그대로 뒀다.
  단, `server.jl` 의 `VALID_CASES` 에는 `all` 이 없으므로 **재생 전용**이다 —
  이 케이스에서 "Start live" 를 누르면 `400 unknown OOD case` 가 난다.
- **`POLICIES` · `Enacted policy` 선택기에 `noop` 추가.** 스윕의 기준(바닥선) 레인이 `noop` 인데
  둘 다 `canonical / surrogate / dspy` 뿐이었다. `Enacted policy` 에 없으면 `noop` 녹화 파일을
  **가리킬 방법 자체가 없다**(파일 이름이 그 선택기에서 나온다). `canonical` 은 스윕에 판이
  없더라도 남겨 뒀다 — 스트림의 정책 블록에는 canonical 의 반사실 선택이 들어 있다.

---

## 7. 보는 순서 (요약)

1. `./render/publish_streams.sh --clean` (발행 21판 확인)
2. `julia +lts --project=. tools/monitor/server.jl` (배너 대기)
3. 노트북: `ssh -N -L 8080:127.0.0.1:8080 <user>@<host>` → `http://127.0.0.1:8080/`
4. 대시보드에서: **Model = Tractor (test)** · **OOD events = 0** · **OOD seed = 1** ·
   **Enacted policy = noop / surrogate / dspy** 중 하나 · 케이스 버튼 하나 클릭
5. Factory View 의 "No 3D animation" 은 정상(§5). 데이터는 왼쪽 패널에 있다.
