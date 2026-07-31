#!/usr/bin/env python
"""
llm_probe.py — measure a REAL LLM planner's per-decision latency and token cost, so the cost
comparison uses a measured LLM baseline instead of only published figures.

Sends N realistic OOD-planning prompts (identical to what an LLM planner would receive at a mid-build
OOD event: the state summary + the 5-macro repertoire + "pick one, briefly justify") and records
wall-clock latency and prompt/completion token counts. Writes llm_probe.json consumed by cost_eval.py.

Uses the OpenAI SDK if OPENAI_API_KEY is set. Falls back to writing nothing (cost_eval.py then uses
published tiers). Kept deliberately small (N events) — this is a latency/cost probe, not a benchmark.

Usage:  python llm_probe.py [--model gpt-4o-mini] [--n 6] [-o llm_probe.json]
"""
# =============================================================================
# llm_probe.py — 실제 LLM planner의 "결정 1건당 지연시간·토큰 비용" 실측 스크립트
# -----------------------------------------------------------------------------
# [이 파일이 하는 일]
#   빌드 도중 OOD 사건이 터졌을 때 LLM planner가 받을 법한 프롬프트(현재 상태 요약 +
#   5개 복구 macro 목록 + "하나만 골라 한 문장으로 정당화")를 실제 LLM API에 N번 보내고,
#   각 호출의 벽시계 지연시간(latency)과 입력/출력 토큰 수를 측정한다.
#   결과를 llm_probe.json으로 저장하고, 이 파일은 나중에 cost_eval.py가 읽어서
#   비용 비교(LLM vs surrogate)에 "실측 LLM 기준선"으로 사용한다.
#
# [프로젝트 맥락]
#   surrogate 모델은 결정 1건을 0.1ms급으로 처리하는 반면, LLM은 초 단위가 걸린다.
#   이 대비를 "논문에 실린 공개 수치"가 아니라 "직접 잰 수치"로 뒷받침하기 위한 작은 probe다.
#   (벤치마크가 아니라 latency/cost 샘플러라서 호출 수 N을 일부러 작게 둔다.)
#
# [동작 조건]
#   환경변수 OPENAI_API_KEY가 있으면 실제 API를 호출한다.
#   없으면 아무것도 안 하고 조용히 종료 -> 이 경우 cost_eval.py는 공개 가격표(published tiers)를 쓴다.
#
# [실행 방법]
#   python llm_probe.py [--model gpt-4o-mini] [--n 6] [-o llm_probe.json]
#     --model : 사용할 모델 이름(가격표 PRICE의 key와 맞춰야 정확한 $ 계산)
#     --n     : API 호출 횟수(EVENTS 목록을 순환하며 채움)
#     -o/--out: 결과 json 저장 경로
#
# [문법 참고 — 처음 보는 사람을 위해]
#   - import statistics as st: 표준 통계 모듈을 짧은 별칭 st로 가져옴(st.median 등).
#   - argparse: 커맨드라인 인자(--model 등)를 파싱해 주는 표준 라이브러리.
#   - (a, b) 튜플: PRICE 값처럼 "입력가격, 출력가격" 두 값을 한 묶음으로 보관.
#   - f-string 포맷 {dt:5.2f}: 숫자를 소수 둘째자리·폭 5로 정렬해 예쁘게 출력.
#   - zip(itok, otok): 두 리스트를 짝지어 (입력토큰, 출력토큰)씩 함께 순회.
#   - getattr(obj, name, default): 속성이 없을 수도 있을 때 안전하게 꺼내는 함수.
# =============================================================================
import os, sys, json, time, argparse, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))  # 이 스크립트가 있는 폴더 절대경로(기본 출력 위치용).

# published $/1M tokens for the probe models (2026-01); used to convert measured tokens -> $.
# 모델별 공개 단가표: (입력 100만 토큰당 $, 출력 100만 토큰당 $). 측정 토큰 수를 $로 환산할 때 쓴다.
PRICE = {
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4o":      (2.50, 10.00),
    "gpt-4.1-mini":(0.40, 1.60),
    "o4-mini":     (1.10, 4.40),
}

# system 프롬프트: LLM에게 역할과 규칙을 알려주는 고정 지시문.
#   "빌드 중 재계획자가 되어, OOD 사건 발생 시 5개 macro 중 정확히 하나만 골라 한 문장으로 정당화하라."
#   -> 여러 줄 문자열을 괄호로 이어붙여 하나의 긴 문자열로 만든다(파이썬은 인접 문자열 리터럴을 자동 연결).
SYS = ("You are a mid-build replanner for a multi-robot spacecraft-assembly line. An out-of-"
       "distribution event has just fired. Choose exactly ONE recovery macro from the repertoire and "
       "justify in one sentence. Repertoire: 0=NOOP (do nothing), 1=Replace (swap in a spare robot), "
       "2=Deprioritize (defer the affected tasks), 3=ForbidZone (route around a no-go region), "
       "4=ReformTeam (re-form the transport team). Answer as: <macro_id> - <one sentence>.")

# 실측에 쓰는 현실적인 OOD 사건(user 프롬프트) 목록. --n이 이 개수보다 크면 순환해서 재사용한다.
# 고장/배터리 방전/통행금지 구역/팀 desync 등 다양한 복구 상황을 대표하도록 골랐다.
EVENTS = [
    "Robot R7 has faulted while solo-transporting 1 remaining part; 12 spares idle; build 45% closed.",
    "Robot R15 battery SoC dropped to 0.02 mid-haul; 12 spares idle; build 19% closed.",
    "Robot R4 battery SoC is 0.52, still hauling; spares idle; build 60% closed.",
    "A no-go zone appeared covering ~0.9 of the active staging area; 3 teams routing through it.",
    "A no-go zone appeared covering ~0.15 of a rarely-used corridor; build 70% closed.",
    "Robot R2 faulted but its tasks are already complete; the victim is idle; build 80% closed.",
    "Robot R11 battery SoC 0.12 mid-haul, no nearby spare within 2 aisles; build 30% closed.",
    "Two robots in a transport team desynced after a zone reroute; part not yet deposited.",
]


# 실제 실행 진입점: 인자 파싱 -> API 키 확인 -> N번 호출·측정 -> 통계 요약을 json으로 저장.
def main():
    ap = argparse.ArgumentParser()  # 커맨드라인 인자 파서 생성.
    ap.add_argument("--model", default="gpt-4o-mini")  # 사용할 모델 이름.
    ap.add_argument("--n", type=int, default=6)         # 호출 횟수.
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "llm_probe.json"))  # 결과 저장 경로.
    a = ap.parse_args()  # 실제 인자를 읽어 a에 담는다(a.model, a.n, a.out으로 접근).

    key = os.environ.get("OPENAI_API_KEY")  # API 키를 환경변수에서 읽음(없으면 None).
    if not key:
        # 키가 없으면 실측을 건너뛴다 -> 이후 cost_eval.py는 공개 가격표로 대체한다.
        print("no OPENAI_API_KEY -> skipping live probe (cost_eval will use published tiers)")
        return
    import urllib.request, urllib.error  # 외부 SDK 없이 표준 라이브러리만으로 HTTP 요청.
    URL = "https://api.openai.com/v1/chat/completions"  # OpenAI 챗 완성 API 엔드포인트.

    # 사건 ev 하나를 API로 보내고 응답(JSON)을 dict로 돌려주는 내부 함수.
    def call(ev):
        body = json.dumps({
            "model": a.model,
            "messages": [{"role": "system", "content": SYS},                # 고정 역할 지시문.
                         {"role": "user", "content": f"EVENT: {ev}\nYour choice:"}],  # 이번 사건.
            "max_tokens": 120, "temperature": 0.0}).encode()  # temperature=0 -> 재현성 높은 결정.
        # 요청 객체 생성: 인증 헤더(Bearer 토큰)와 JSON 콘텐츠 타입 지정.
        req = urllib.request.Request(URL, data=body, headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:  # 최대 60초 대기.
            return json.loads(resp.read())  # 응답 바이트를 JSON으로 파싱해 반환.

    lats, itok, otok = [], [], []  # 각 호출의 지연시간/입력토큰/출력토큰을 모을 리스트.
    for i in range(a.n):
        ev = EVENTS[i % len(EVENTS)]   # i가 EVENTS 개수를 넘으면 % 로 처음부터 순환.
        t0 = time.perf_counter()       # 호출 직전 시각(고해상도 타이머).
        try:
            r = call(ev)
        except Exception as e:
            # 호출 실패 시: 예외 객체에 read()가 있으면 에러 본문 일부를 함께 출력하고 다음으로 넘어감.
            msg = getattr(e, "read", lambda: b"")() if hasattr(e, "read") else b""
            print(f"  call {i} failed: {e} {msg[:200]}"); continue
        dt = time.perf_counter() - t0  # 왕복에 걸린 실제 시간(초).
        lats.append(dt)
        u = r["usage"]                 # 응답 안의 토큰 사용량 정보.
        itok.append(u["prompt_tokens"]); otok.append(u["completion_tokens"])  # 입력/출력 토큰 기록.
        # 이번 호출 요약 출력: 지연시간, 토큰 수, 모델이 고른 macro 응답 앞 70자.
        print(f"  [{i}] {dt:5.2f}s  in={u['prompt_tokens']} out={u['completion_tokens']}  "
              f"-> {r['choices'][0]['message']['content'].strip()[:70]}")
    if not lats:  # 성공한 호출이 하나도 없으면 저장하지 않고 종료.
        print("no successful calls -> not writing probe"); return

    pin, pout = PRICE.get(a.model, (0.15, 0.60))  # 모델 단가(모르는 모델이면 기본값 사용).
    # 호출별 비용($) 계산: (입력토큰/100만 * 입력단가) + (출력토큰/100만 * 출력단가).
    usd = [i / 1e6 * pin + o / 1e6 * pout for i, o in zip(itok, otok)]
    # 측정 결과 요약(중앙값·평균 등)을 dict로 정리. 중앙값(median)은 이상치에 강건해 대표값으로 씀.
    out = dict(model=a.model, n=len(lats),
               latency_s_median=st.median(lats), latency_s_mean=st.mean(lats),
               in_tok=int(st.median(itok)), out_tok=int(st.median(otok)),
               usd_per_call_median=st.median(usd), usd_per_call_mean=st.mean(usd),
               price_in_per_M=pin, price_out_per_M=pout)
    json.dump(out, open(a.out, "w"), indent=1)  # 결과를 json 파일로 저장(indent=1: 보기 좋게 들여쓰기).
    print(f"\nwrote {a.out}: median {out['latency_s_median']:.2f}s, "
          f"${out['usd_per_call_median']:.4f}/call over n={out['n']}")


# 이 파일을 직접 실행할 때만 main()을 부른다(다른 파일이 import할 때는 실행 안 됨).
if __name__ == "__main__":
    main()
