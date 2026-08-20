"""wmpath.py -- 폴더로 나눈 뒤에도 **맨이름 import** 가 그대로 되게 하는 단일 부트스트랩.

왜 있는가 (2026-08-18 역할별 폴더 분류)
---------------------------------------
분류 전에는 모든 py 가 `wm4spacecraft_manufacturing/` 한 폴더에 평평하게 있었고, 그래서
`import objective` · `import e1_analyze` 같은 **맨이름 import** 가 그냥 됐다 — 스크립트 자기
폴더가 언제나 `sys.path[0]` 이기 때문이다. 파일을 `core/` · `surrogate/` · `reporting/` 등으로
나누면 그 전제가 깨진다.

선택지는 둘이었다: (a) 전부 패키지로 만들고 상대 import 로 바꾼다, (b) 코드 폴더 전부를
`sys.path` 에 올려 **맨이름 import 관례를 보존**한다. (b)를 골랐다 — (a)는 `python
llm_ood_eval.py run` 처럼 **스크립트로 직접 실행하는** 진입점 전부(`run_shard.sh` ·
`finish_tables.sh` · `build_final_table.py` 의 서브프로세스 호출)를 `-m` 형태로 갈아엎어야
하고, 레포 밖 소비처(`src/respec/llm_service/dspy_service.py`)까지 같이 깨진다.

쓰는 법 — 자기 폴더 밖 모듈을 import 하는 파일 머리에 이 세 줄:

    import os, sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "core"))
    import wmpath                       # noqa: E402  (코드 폴더 전부를 sys.path 에 올린다)

`wmpath.WM` 은 `wm4spacecraft_manufacturing/` 폴더 절대경로다. 분류 전에 `HERE` 로 부르던
"레포 폴더" 가 이제 이 값이다 — `results_4pol/` · `artifacts_4pol/` · `dp_oracle/` · `md/`
같은 **데이터 폴더 기준점**은 전부 `wmpath.WM` 으로 잡는다(`HERE` 는 이제 자기 하위폴더다).

`insert(0, ...)` 인 이유: 분류 전 각 파일이 하던 `sys.path.insert(0, HERE)` 와 같은 우선순위를
유지한다. 단 레포 밖에서 부를 때는 얘기가 다르다 — `dspy_service.py` 는 dspy/litellm 스택과
동명 모듈이 부딪힐 위험 때문에 **일부러 append** 를 쓰므로 이 모듈을 거치지 않고 필요한 폴더만
직접 append 한다(그 파일 머리말 참조).
"""
import os
import sys

WM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 코드가 사는 폴더 전부. 데이터 전용 폴더(results_*/ artifacts_*/ measurements/ md/ 등)는 넣지 않는다.
CODE_DIRS = ("core", "surrogate", "novelty", "sweep", "reporting", "dp_oracle")

for _d in CODE_DIRS:
    _p = os.path.join(WM, _d)
    if _p not in sys.path:
        sys.path.insert(0, _p)
