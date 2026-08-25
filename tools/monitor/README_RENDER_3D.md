# 스윕을 3D 애니메이션까지 다시 만들기 (`render_demo.jl`)

대시보드 Factory View 의 3D 창이 비어 있는 이유는 하나다: **애니메이션 파일이 없다.**
밤샘 스윕(630판)은 `tools/monitor/run_demo.jl` 로 돌았고 그 엔진은 모니터 스트림만 쓴다.
3D 를 만드는 엔진은 `tools/monitor/render_demo.jl` 이고, 그것은 **스트림을 후처리하지 않는다 —
시뮬레이션을 다시 돈다.**

그래서 이 문서가 안내하는 것은 "화면 채우기"가 아니라 **재측정**이다. 비용과 의미를 먼저 읽어라.

측정은 전부 2026-08-13 bethpage(56 core / 125 GB, 유휴)에서 `/usr/bin/time -v` 로 잰 값이다.
**추정한 값에는 "추정"이라고 적었다.**

---

## 0. 선결 과제 — `render_demo.jl` 은 지금 HEAD 에서 **돌지 않는다**

```
$ julia +lts --project=. tools/monitor/render_demo.jl
ERROR: LoadError: cannot document the following expression:
include(joinpath("…/tools/monitor", "run_header.jl"))
  @ …/tools/monitor/render_demo.jl:263
```

`render_demo.jl:263` 의 docstring 이 `:264-265` 의 `include(...)` **앞**에 붙어 있다. Julia 는
그 문자열을 include 표현식의 문서로 붙이려다 죽는다. 그 docstring 의 임자는 `:267` 의
`pending_command_kind` 다. 커밋 `0063e6a` 에서 include 두 줄이 사이에 끼며 생겼고,
작업 트리 수정이 아니라 **커밋된 상태**다. 즉 그 커밋 이후 이 경로는 한 번도 돌지 않았다
(대시보드의 `POST /run` 도 같은 파일을 부르므로 라이브 렌더도 같이 죽어 있다).

고치는 법 — 263행의 그 문자열 한 줄을 지우고 include 두 줄 **아래**로 옮긴다. 의미는 안 바뀐다:

```julia
 include(joinpath(@__DIR__, "run_header.jl"))
 include(joinpath(@__DIR__, "zone_command.jl"))

+"명령 파일에 이미 들어와 있는 조작자 명령의 종류. `:abort` 가 하나라도 있으면 그게 이긴다."
 function pending_command_kind(path)
```

이 문서의 실측은 그 한 줄만 옮긴 사본으로 냈다. 아래 명령들은 **수정 후에** 돈다.

---

## 1. ⚠ 먼저 읽을 것 — `streams/` 심링크가 밤샘 데이터를 먹는다

`tools/monitor/streams/` 의 `*.jsonl` 21개는 전부 **심링크**이고, 끝은
`wm4spacecraft_manufacturing/results_4pol/shards/<case>/s1/logs/stream_s1_<policy>.jsonl` —
어젯밤 스윕의 원본이다(`publish_streams.sh` 가 건 것).

스트림을 여는 코드는 `src/monitor/monitor.jl:32` 의 `open(path, "w")` 다. POSIX 의 O_TRUNC 는
**심링크를 따라간다**. 버릴 심링크로 실측했다:

```
$ ln -s .../real_target.jsonl link.jsonl          # real_target = "PRECIOUS ORIGINAL DATA"
$ julia -e 'io=open(ARGS[1],"w"); write(io,"CLOBBERED BY JULIA\n"); close(io)' link.jsonl
$ cat real_target.jsonl
CLOBBERED BY JULIA                                 # ← 원본이 잘렸다. 링크는 그대로 있다.
```

즉 `render_demo.jl` 이 `streams/tractor__battery__dspy.jsonl` 에 쓰면 그 이름이 심링크인 한
**어젯밤 원본이 그 순간 0 바이트가 된다.** 그리고:

- 그 shard 스트림은 **git 에 없다** — `.gitignore:46` 이 `results_4pol/*` 를 배제한다
  (`git ls-files …/results_4pol/shards` → 0개). `git checkout` 으로 되돌릴 수 없다.
- git 에 있는 것은 병합된 케이스 요약 7개(`results_4pol/{all,battery,…}.jsonl`)뿐이다.
  **논문 표의 숫자는 그쪽에 있으므로 안전하다.** 잃는 것은 판별 재생 스트림이다.
- 복구는 재실행뿐이고, 재실행은 같은 세계를 만들지 못한다(런 간 재현성 미확보).

### 안전 절차 — 둘 중 하나를 반드시 쓴다

**(A) 이름을 겹치지 않게 한다 (권장, 기본값).**
스윕은 `--events 4` 로 돌았다(`llm_ood_eval.py:494` 기본값 → `DEMO_N=4`). `DEMO_N>0` 이면
산출물 이름에 `_n4` 가 붙는다(`render_demo.jl:58`). 발행된 심링크는 `_n` 이 없다. 따라서
`--events 4` 로 렌더하면 **두 집합이 애초에 겹치지 않는다** — 심링크는 손대지 않고, 새 녹화와
어젯밤 녹화를 대시보드에서 나란히 비교할 수도 있다.
대신 대시보드 상단 **`OOD events` 를 4** 로 놓아야 새 녹화가 보인다(0 이면 옛 심링크를 본다).

**(B) 발행물을 먼저 걷는다.**
```bash
cd wm4spacecraft_manufacturing && ./render/publish_streams.sh --clean   # 심링크 제거
#  … 렌더 …
./render/publish_streams.sh                                             # 필요하면 다시 발행
```

`render_all.sh` 는 계획한 산출물 이름 중 **하나라도 심링크면 한 판도 돌리지 않고 중단한다**
(실측 확인). 손으로 `render_demo.jl` 을 부를 때는 그 보호가 없다 — 이름을 직접 확인하라:

```bash
ls -l tools/monitor/streams/tractor__<case>__<policy>*.jsonl
```

---

## 2. `render_demo.jl` 이 실제로 하는 일

한 번 부르면 **판 하나를 처음부터 다시 시뮬레이션**하고 두 개를 남긴다
(`render_demo.jl:115` 와 `:1037`):

```
tools/monitor/streams/<base>__<CASE_TAG><NSUF>.jsonl     # 모니터 스트림 (run_demo.jl 과 같은 seam)
tools/monitor/anim/<base>__<CASE_TAG><NSUF>.html         # MeshCat 정적 3D (≈5 MB)
```

- `base` = `DEMO_MODEL` 의 파일명에서 확장자를 떼고 비영숫자를 `_` 로 바꾼 것 → `tractor`
- `CASE_TAG` = `ENV["DEMO_CASE_TAG"]`, 없으면 `DEMO_OOD` (`:112`)
- `NSUF` = `(DEMO_N>0 ? "_n$DEMO_N" : "") * (DEMO_SEED==1 ? "" : "_s$DEMO_SEED")` (`:57-58`)

애니메이션은 `DEMO_ANIM`(기본 켜짐)이 가른다. `MONITOR_INTERACTIVE=1` 은 사람이 붙는 라이브
모드이고 배치 재생성과는 무관하다(`MONITOR_WAIT` 대기도 그 모드에서만 걸린다).

### 이름에 정책을 넣는 법 — `DEMO_CASE_TAG`

대시보드는 `streams/<base>__<case>__<policy><nsuf>.jsonl` 을 찾는다(`server.jl:242-248`).
`render_demo.jl` 에는 "정책"이라는 이름 축이 없고 `CASE_TAG` 하나뿐이므로, **`case__policy` 를
통째로 `DEMO_CASE_TAG` 에 넣는다.** `__` 가 들어가도 문제 없다(실측):

- 파일 이름에 그대로 들어간다 → `tractor__battery__dspy_n4.{jsonl,html}` ✔
- `render_demo.jl:250` 이 `"case" => CASE_TAG` 를 넣는 payload 는 **평면도 파일**이고,
  이것은 `MONITOR_COMMAND_FILE` 이 있을 때(= 서버가 띄운 라이브 세션)만 쓰인다(`:950` 은
  `if INTERACTIVE` 안이다). 배치 렌더에서는 아예 만들어지지 않는다.
  → `case` 필드가 `battery__dspy` 로 보일 일 자체가 없다. 대시보드는 멀쩡하다.

확인(모니터 서버 `POST /artifact`, 실측):

```
$ curl -s -XPOST 127.0.0.1:8080/artifact -H 'Content-Type: application/json' \
    -d '{"model":"tractor.mpd","case":"fault_zone","n":4,"seed":1,"policy":"dspy"}'
{"stream":"streams/tractor__fault_zone__dspy_n4.jsonl","stream_exists":true,
 "anim":"anim/tractor__fault_zone__dspy_n4.html","anim_exists":true,"anim_stale":false}
```
같은 요청을 `"n":0` 으로 하면 `anim_exists:false` — 그것이 지금 3D 창이 빈 이유 그대로다.

> `anim_exists` 는 존재검사가 아니라 **신선도 검사**다(`server.jl:260`):
> `mtime(anim) >= mtime(stream)` 이어야 참이다. 렌더는 스트림을 먼저 쓰고 애니를 마지막에
> 쓰므로 항상 참이 된다. 반대로 "어젯밤 스트림 심링크 + 오늘 만든 애니" 를 짝지으면 검사는
> 통과하지만 **두 개가 서로 다른 세계**다 — 하지 마라.

### 스윕(`run_demo.jl`)과 같지 않다 — 이게 핵심이다

| 축 | 스윕(`run_demo.jl`) | 렌더(`render_demo.jl`) |
|---|---|---|
| OOD 추첨 시드 | `DEMO_OOD_SEED` (`run_demo.jl:66`) | **읽지 않는다.** `DEMO_SEED` 가 추첨을 정한다(`:45,896`) |
| `DEMO_SEED` 의 뜻 | 월드(로봇 초기 배치). 스윕은 1 로 고정 | **OOD 발화 시점 추첨 시드** |
| 세 종류 혼합 추첨 | `DEMO_OOD_STREAM3=1` (`:431`) | 그런 모드가 없다 |
| `DEMO_OOD=all` | `[:fault,:battery,:zone]` (`:99`) | **`fault` 하나로 떨어진다** — `case_kinds` 에 `all` 분기가 없어 `return [:fault]` 로 간다(실측: `>>> OOD armed: zone×0 + fault×4`) |
| reform | **없다.** `run_demo.jl` 이 `DEMO_REFORM` 을 안 읽고(Task 6), 스윕 드라이버의 `--reform`/`--reform-max` 도 2026-08-24 에 지워졌다 | 아직 `DEMO_REFORM`(기본 400) / `DEMO_REFORM_MAX`(기본 3) 을 읽는다 (`:83,87`) — 렌더 전용 손잡이다 |
| MeshCat | 없다 | 애니를 켜면 `Visualizer()` 를 만든다(`full_demo.jl:194,235`) |

**시드 축을 돌리려면 `DEMO_SEED=k` 를 준다**(스윕의 `DEMO_OOD_SEED=k` 가 아니다). 그러면 이름도
`_sk` 가 붙는다. 다만 추첨 메커니즘 자체가 다르므로 `DEMO_SEED=k` 판과 스윕의 `seed=k` 판은
**같은 판이 아니다.**

> **결론: 여기서 나오는 것은 새 런이다.** 어젯밤 판의 3D 재생이 아니다. 숫자도 다르게 나온다.
> `md/RESULTS_30SEED_D20_2026-08-13.md` 의 표는 계속 `results_4pol/` 이 근거다. 이 렌더는
> **시각 자료**로만 쓴다.

---

## 3. 판 하나 — 복붙

```bash
cd /home/chahj578/Construction_OODlayer

JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 \
DEMO_MODEL=tractor.mpd \
DEMO_OOD=fault_battery \
DEMO_CASE_TAG=fault_battery__dspy \
DEMO_N=4 DEMO_SEED=1 \
DEMO_POLICY=dspy DEMO_ROUTER=0 \
DEMO_SPARES=3 DEMO_REFORM=300 DEMO_REFORM_MAX=6 DEMO_BSOC=0.9 DEMO_OOD_SEVFRAC=0.5 \
CARRIER_RESCUE=1 RELOCATE_GATE=1 \
DSPY_URL=http://127.0.0.1:8090 LLM_NL_MODE=observation \
DEMO_ANIM=1 MONITOR_INTERACTIVE=0 \
julia +lts --project=. --startup-file=no tools/monitor/render_demo.jl
```

→ `streams/tractor__fault_battery__dspy_n4.jsonl` + `anim/tractor__fault_battery__dspy_n4.html`

환경변수는 스윕이 넘긴 것(`llm_ood_eval.py:91-114`)을 그대로 미러한 것이다. `DEMO_OOD_SEED` ·
`DEMO_OOD_STREAM3` 은 `render_demo.jl` 이 읽지 않으므로 뺐다(줘도 무시된다).

### DSPy 서비스

`dspy` 레인은 `http://127.0.0.1:8090` 이 필요하다. 지금은 떠 있다(실측):

```
$ curl -s 127.0.0.1:8090/health
{"status":"ok","policy":"dspy:gpt-4o","program":"(seed only)","demos":0,"calls":12964, …}
```

없으면 `policy.jl` 이 canonical 로 폴백하고 verdict 에 그 사실을 남긴다 — 즉 **조용히 다른 판이
된다**. 반드시 먼저 확인하고, 없으면 띄운다:

```bash
cd wm4spacecraft_manufacturing
DSPY_PROGRAM=__seed_only__ ../.venv/bin/python -m uvicorn dspy_service:app --host 127.0.0.1 --port 8090
```

`noop` · `surrogate` 레인은 서비스가 필요 없다.

---

## 4. 여러 판 — `wm4spacecraft_manufacturing/render_all.sh`

```bash
cd /home/chahj578/Construction_OODlayer/wm4spacecraft_manufacturing

bash render/render_all.sh --dry-run                 # 계획만 (판 수 · 위험한 이름 검사)
bash render/render_all.sh --jobs 8                  # 기본 21판 (7 case × 3 policy × seed 1)
bash render/render_all.sh --seeds 1,2,3 --jobs 8    # 63판
bash render/render_all.sh --cases battery --policies dspy --jobs 1
bash render/render_all.sh --force                   # 이미 있는 anim 도 다시
```

- **재개**: `anim/<이름>.html` 이 이미 있고 비어 있지 않으면 건너뛴다(`--force` 로 무시).
- **안전 게이트**: 계획한 이름 중 하나라도 심링크면 **아무것도 돌리지 않고 중단**(§1).
- **로그**: 판마다 `_night/render_logs/<이름>.log`, 상태는 `_night/status_render.jsonl`,
  끝에 ok/fail 과 판당 벽시계 중앙값·합을 요약한다.
- **스레드 고정**: `JULIA_NUM_THREADS=1` 등 (`run_shard.sh` 와 같은 이유 — 안 걸면 프로세스마다
  코어 수만큼 스레드를 띄워 K 배로 코어를 뺏는다).
- `--events` 기본 4 = 스윕과 같은 값 = `_n4` 이름 = 심링크와 안 겹침(§1-A).

---

## 5. 병렬성 — 포트는 문제가 아니고, **결과 폴더가 문제다**

**포트 8700 은 제약이 아니다.** MeshCat 은 `find_open_port(host, 8700, 500)` 으로 8700부터
빈 포트를 찾아 연다(`MeshCat/src/visualizer.jl:1-13`, `MeshCat.jl:122`). 즉 동시에 500개까지
서로 다른 포트를 잡는다. `server.jl:92` 가 렌더를 동시 1개로 묶는 것은 대시보드 라이브 세션이
"8700 에 붙는다"는 약속을 지키기 위한 것이지, 배치 렌더의 물리적 제약이 아니다.

**진짜 제약은 애니메이션 중간 산출물 경로다.** `render_demo.jl:1034` 는 애니를 고정 경로에서
집어 온다:

```
<repo>/results/<model_base>_render/greedy_RVO_Dispersion_TangentBug/visualization.html
```

`model_base` 는 `DEMO_MODEL` 의 파일명에서만 나온다(`:107`). 같은 모델을 동시에 렌더하면
**모두 같은 파일에 쓰고 같은 파일을 집어 간다.** 게다가 저장은 원자적이지 않다
(`demo_utils.jl:413`):

```julia
open(path, "w") do io
    write(io, static_html(visualizer))   # ← 파일을 먼저 비운 뒤, 5 MB 문자열을 만들어 쓴다
end
```

`open(...,"w")` 가 파일을 즉시 0 으로 만들고, 그 다음에야 `static_html` 이 수 MB 를 조립한다.
그 구간에 다른 판이 `cp` 를 하면 **빈/잘린 애니를 자기 판의 결과로 발행한다. 오류 없이, 조용히.**
K=16 · 판당 150 s 이면 630판에서 수십 판이 이 창에 걸린다(추정) — 실패가 아니라 오염이라
사후에 알아채기도 어렵다.

### 해법 — 워커마다 모델 별칭

`render_all.sh` 는 워커마다 심링크 별칭을 만든다:

```
LDraw_files/_render_workers/tractor_w<K>.mpd  ->  ../tractor.mpd
```

별칭이면 `model_base` 가 `tractor_w3` 이 되어 결과 폴더가 `results/tractor_w3_render/` 로 갈린다
= 공유 경로가 사라진다. 판이 끝나면 산출물 이름을 정규 이름(`tractor__…`)으로 되돌리고 그
워커 결과 폴더를 지운다.

**시뮬레이션은 바뀌지 않는다.** 별칭 파일명은 `get_project_params` 에 없어 조회가 실패하고
`render_demo.jl:104-106` 의 폴백으로 떨어지는데, 그 폴백값이 tractor 의 실제 파라미터와 같다:

| | `project_params.jl:59-63` (tractor) | `render_demo.jl:104-106` 폴백 |
|---|---|---|
| `model_scale` | 0.008 | 0.008 |
| `num_robots`  | 10 | `DEMO_ROBOTS` 기본 10 |

실측으로도 별칭 런의 헤더가 `scale=0.008 robots=10` 으로 원본과 같았다. **다른 모델에서는 이
등식이 성립하지 않으므로** `render_all.sh` 는 `--model` 이 `tractor.mpd` 가 아니면 별칭을 끄고
K=1 로 내린다.

### 안전 동시성 — K=6 실측

`render_all.sh --cases battery,fault,zone --policies noop,dspy --jobs 6` (6판 동시):

```
[render] OK    tractor__battery__dspy_n4 anim=4829KB 137s
[render] OK    tractor__fault__noop_n4   anim=4814KB 142s
[render] OK    tractor__fault__dspy_n4   anim=4828KB 142s
[render] OK    tractor__battery__noop_n4 anim=4829KB 144s
[render] OK    tractor__zone__dspy_n4    anim=4864KB 150s
[render] OK    tractor__zone__noop_n4    anim=4817KB 154s
=== 종료 (154s 경과) ===   ok 6 · fail 0   판당 중앙값 144s · 합 869s
```

확인한 것:
- `results/tractor_w1_render` … `tractor_w6_render` 6개가 **따로** 생겼다 = 공유 경로 소멸.
  판이 끝나면서 전부 지워졌다(`results/` 에 남은 것 없음).
- 애니 6개의 md5 가 **전부 다르다**(`battery__dspy` 와 `battery__noop` 은 바이트 수까지
  4,944,966 로 같지만 md5 는 다르다 — 크기만 보면 속는다).
- 판당 벽시계 평균 869/6 = **144.8 s**, 단독 실행 3판 평균 **145.1 s**. → K=6 에서 경합 손실
  사실상 0.
- 발행된 심링크 21개의 대상 파일은 크기·mtime 모두 **변하지 않았다**(전후 대조).

- **K=8 을 권장 기본값**으로 둔다(`render_all.sh --jobs 8` 이 기본). 실측 K=6 에서 한 칸 올린 값.
- **K=16 도 자원상 성립한다(추정)**: 판당 peak RSS 1.2–1.5 GiB × 16 ≈ 24 GiB < 가용 119 GiB,
  프로세스 16 < 56 코어. 어젯밤 스윕이 같은 모양의 프로세스로 K=16 을 완주했고 판당 벽시계가
  137–162 s 로 단독 렌더(138–158 s)와 사실상 같았다 — 즉 K=16 에서도 경합 손실이 거의 없다.
  별칭 격리가 있으면 애니 오염 경로도 없다. 다만 K=16 은 이 문서에서 **직접 실측하지 않았다.**
- **별칭 없이는 K=1 이 유일한 안전값이다.**

---

## 6. 실측 — 판당 비용

전부 `tractor.mpd`, `DEMO_N=4`, `DEMO_SEED=1`, `DEMO_POLICY=dspy`, 스레드 1로 고정,
`/usr/bin/time -v`. 단독 실행(다른 부하 없음).

| case | anim | 벽시계 | peak RSS | anim html | stream | 프레임 | 완주 |
|---|---|---:|---:|---:|---:|---:|---|
| `battery` | ON  | **137.9 s** | 1.44 GiB | 4,944,966 B | 952 KB | 17 | ✔ |
| `all`(→`fault`) | ON | **139.8 s** | 1.41 GiB | 4,944,698 B | 1,013 KB | 18 | ✔ |
| `fault_zone` | ON | **157.7 s** | 1.20 GiB | 4,995,552 B | 2,728 KB | 42 | ✔ |
| `battery` | **OFF** | **125.2 s** | 1.36 GiB | — | 952 KB | 17 | ✔ |

**애니메이션 오버헤드 = 137.9 − 125.2 = 12.7 s (≈ +10%)** — 같은 case·같은 설정에서 `DEMO_ANIM`
만 바꾼 대조군이다. 이것이 이 문서에서 유일하게 통제된 비교다.

스윕의 판당 비용과 비교(어젯밤 `_night/status_shards.jsonl` 의 샤드 벽시계 ÷ 3판, K=16 실측):

| case | 스윕 판당 (anim 없음, K=16) | 렌더 판당 (anim 있음, 단독) |
|---|---:|---:|
| `battery` | 137.0 s | 137.9 s |
| `fault` | 148.7 s | (= `all` 런의 139.8 s) |
| `fault_zone` | 162.0 s | 157.7 s |
| `all` | 160.3 s | — (렌더는 `all` 을 `fault` 로 떨군다) |

→ **애니메이션은 판당 비용을 사실상 늘리지 않는다.** 두 엔진이 만드는 세계가 달라 1:1 비교는
아니지만, 통제된 대조군(+12.7 s)과 이 표가 같은 방향을 가리킨다.

K=6 동시 렌더 6판(§5)도 같은 자리에 있다 — 137 / 142 / 142 / 144 / 150 / **154 s**, 평균 144.8 s.

### 계획용 상수

- 단독 3판 평균 = (137.9 + 139.8 + 157.7)/3 = **145.1 s**
- K=6 6판 평균 = 869/6 = **144.8 s**

둘이 같으므로 경합 보정 없이 쓴다. 여유를 두어 **판당 150 s** 로 잡는다.

| 규모 | 판 수 | 코어·초 (150 s × 판) | K=1 | K=8 | K=16(추정) |
|---|---:|---:|---:|---:|---:|
| seed 1 (7 case × 3 policy) | 21 | 3,150 s | 52분 | **7.5분** (3파도×150 s) | 5분 (2파도) |
| seed 1–3 | 63 | 9,450 s | 2시간 38분 | **20분** (8파도×150 s) | 10분 (4파도) |
| 전체 (30 seed) | 630 | 94,500 s | 26시간 15분 | **3시간 18분** (79파도×150 s) | 1시간 40분 (40파도) |

산수: 파도 수 = ⌈판 수 ÷ K⌉, 시간 = 파도 수 × 150 s. (판마다 비용이 달라 실제로는 이보다
조금 짧다 — 위 표는 상한에 가깝다.) K=8 은 실측 K=6 에서 한 칸 올린 값이고, K=16 열은
자원 산술과 어젯밤 스윕 실적에 기댄 **추정**이다.

---

## 7. 디스크

실측 판 7개(`battery`·`fault`·`zone` × `noop`/`dspy` + `fault_zone`/`dspy`):

- `anim/*.html` : 4,929,786 … 4,995,552 B → 평균 **4,953,454 B ≈ 4.95 MB** (편차 ±1.5% 이내)
- `streams/*.jsonl` : 900,729 … 3,471,141 B → 평균 **1,779,143 B ≈ 1.78 MB** (case 따라 4배 차)
- 합 **≈ 6.73 MB / 판**

| 규모 | 판 수 | anim (4.95 MB×판) | stream (1.78 MB×판) | 합 |
|---|---:|---:|---:|---:|
| seed 1 | 21 | 104 MB | 37 MB | **141 MB** |
| seed 1–3 | 63 | 312 MB | 112 MB | **424 MB** |
| 전체 | 630 | 3.12 GB | 1.12 GB | **4.24 GB** |

anim 은 판마다 거의 일정하므로 위 수치가 정확에 가깝고, stream 은 표본 7개의 평균이라
전체 규모에서는 ±50% 정도 흔들릴 수 있다(추정).

`tools/monitor/anim/` · `tools/monitor/streams/` 는 둘 다 `.gitignore` 에 있다(`:30-31`) —
커밋 대상이 아니다. 디스크 여유는 1.6 TB(실측)라 전체를 만들어도 문제 없다.

---

## 8. 얻는 것과 못 얻는 것

**얻는 것**
- Factory View 의 3D 창이 찬다. `OOD events` 를 렌더에 쓴 값(기본 4)으로 맞추면 된다.
- 왼쪽 스트림 패널과 3D 가 **같은 런**이다(`anim_stale` 이 뜨지 않는다).
- 심링크 발행본(어젯밤)과 `_n4` 새 녹화가 공존하므로 같은 case·policy 를 두 세계로 볼 수 있다.

**못 얻는 것**
- **어젯밤 판의 3D 가 아니다.** 재시뮬레이션이고, OOD 추첨 메커니즘 자체가 다르다(§2 표).
- `all` 케이스는 3D 로 정직하게 재현되지 않는다 — 렌더 엔진이 `fault` 로 떨군다.
- 여기서 나온 스트림의 수치를 표에 넣으면 안 된다. **`md/RESULTS_30SEED_D20_2026-08-13.md` 의
  근거는 계속 `results_4pol/` 이다.**

---

## 9. 빠른 시작 — 21판만

```bash
cd /home/chahj578/Construction_OODlayer

# 0) 선결: render_demo.jl:263 docstring 을 include 두 줄 아래로 옮긴다 (§0)

# 1) DSPy 서비스 확인 (dspy 레인에 필요)
curl -s 127.0.0.1:8090/health

# 2) 계획 확인 — 판 수와 "위험 0" 을 눈으로 본다
cd wm4spacecraft_manufacturing
bash render/render_all.sh --dry-run --jobs 8

# 3) 실행 (≈7.5분, 추정 상한. 실측 판당 137–158 s)
bash render/render_all.sh --jobs 8

# 4) 대시보드에서 상단 OOD events 를 4 로 놓는다  →  Factory View 3D 가 찬다
```

`--events 4` 를 그대로 두는 한 어젯밤 발행 심링크는 건드리지 않는다(§1-A). 그래도 불안하면
`./render/publish_streams.sh --clean` 을 먼저 돌려라 — 나중에 다시 걸면 그만이다.

> 이 문서를 만들면서 21판 중 **7판은 이미 렌더돼 있다**
> (`battery`·`fault`·`zone` × `noop`/`dspy`, `fault_zone`/`dspy`). 재개가 그것들을 건너뛰므로
> 위 실행은 실제로는 14판만 돈다(≈5분). 다시 만들고 싶으면 `--force`.
