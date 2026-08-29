"""레지스트리는 **기전**을 말하고 **정답 조건**을 말하지 않는다.

🔴 왜 (dspy_service.py:155-165 의 실측): 규칙을 문장으로 주면 측정되는 것은 추론이 아니라
프롬프트 준수다. 서술자가 harm=0.02 인데도 "restage 하라"는 지시문을 따라간 관측이 있다.
그런데 레지스트리 doc 이 "Best when …" / "Best on …" 으로 그 선을 넘어 있었고,
doc_lines() 가 그것을 SEED_DOC 에 그대로 실었다.

⚠️ 이 게이트가 못 재는 것 (T1, fix round 4): 이 파일의 모든 어서션은 `_macros().items()` 를
순회한다 -- 즉 **있는** macro 가 틀렸는지는 재지만, **있어야 할** macro 가 빠졌는지는 못 잰다.
`test_registry_is_non_empty` 가 완전히 빈 레지스트리(순수 공허)는 닫지만, **부분** 누락은 이
파일 밖의 문제다: SwapBattery 를 지우고 vocab 도장을 `v4-2arms` 로 같이 바꾸면(이 레지스트리가
창건 실패담으로 세 번 인용하는 바로 그 실패 모양이자 2026-08-24 의 4→3 arm 축소와 같은 편집
모양인데도) `action_registry.py` 의 `assert_vocab_arm_count` 는 도장과 실제 arm 수가 서로
맞으면 통과시킨다 -- 지우는 손이 도장도 같이 고치므로 구조상 통과한다. 이걸 닫으려면 이 파일
밖의 진실원(예: 기대 arm 이름의 독립된 목록)이 있어야 하는데, 그런 걸 지어내지 않는다. 이
파일은 **존재하는 팔의 모양**을 재지, **있어야 할 팔이 다 있는지**는 재지 못한다.

fix round 1 (리뷰어 뮤테이션 테이블 P1-P5): 아래 다섯 군데를 고쳤다. 각각 "뮤테이션을 만들고
빨개지는 걸 보고 되돌린다"로 검증했다 -- 그 로그는 커밋되지 않고 task-3-report.md 에 있다.
  P1 mechanism.2 = "" 가 4개 게이트를 전부 통과했다 -- 빈 mechanism 을 막는 테스트가 없었다.
  P2 VERDICT_WORDS 는 5개 리터럴만 막는 블록리스트였고(M6/M7 이 안 걸림), when_to_use 누출
     검사는 24자 **접두**만 봐서 M8(꼬리만 새는 뮤테이션)을 놓쳤다 -- 슬라이딩 윈도우로 바꿨다.
  P3 컴파일 프로그램 가드가 `PROGRAM == ""` 를 어서션해서, 이 레포의 문서화된 설정
     (DSPY_PROGRAM=__seed_only__, .claude/CLAUDE.md Gotchas)에서 안전한데도 헛불을 냈다 --
     실제로 지켜야 하는 명제(`_state["instructions"] == SEED_DOC`)로 바꿨다.
  P4 test_every_macro_has_both_fields 는 단독으로 못 빨개진다(실패 집합이
     test_mechanism_carries_no_known_verdict_phrasing 과 test_doc_lines_never_renders_when_to_use
     둘의 합집합의 부분집합) -- 독립 핀이 아니라 가독성 래퍼라고 docstring 에 적었다.
  P5 테스트가 읽는 JSON 경로가 로더가 읽는 경로(REGISTRY_PATH, ACTION_REGISTRY 로 오버라이드
     가능)와 달랐다 -- 같은 경로를 읽게 고쳤다.

fix round 2 (Q1-Q4): P1 은 JSON 을 핀했지만 **렌더**를 아무도 안 쟀다 -- doc_lines() 를
gut 해서 "" 를 내거나 이름+비용만 내도 라운드 1 의 다섯 테스트가 전부 초록이었다(SwapBattery
가 프롬프트에서 안 보이는, 이 레지스트리의 창건 실패담 그 자체인데도). 아래를 고쳤다.
  Q1 각 macro 의 mechanism 문자열이 실제로 `doc_lines()` 렌더 결과 안에 있는지 직접 잰다
     (test_doc_lines_renders_every_mechanism, 새로 추가).
  Q2 leak 윈도우 검사가 **같은 macro** 의 mechanism 에도 있는 문구를 오탐했다(mechanism 에
     문구를 추가했을 뿐인데 when_to_use 가 샜다는 메시지가 났다) -- 그 macro 자신의
     mechanism 에도 나타나는 윈도우는 leak 판정에서 뺀다(mechanism 은 원래 렌더되는 필드라
     거기 있는 문구는 새는 게 아니라 의도된 렌더다). **[fix round 5 에서 제거됨 -- 아래 그
     절 참고. 오귀속을 고치려다 훨씬 큰 거짓 음성을 열었다.]**
  Q3 when_to_use = "" 면 `_leak_windows` 가 [] 를 내서 그 macro 의 leak 어서션이 루프
     바디를 한 번도 안 돌고 공허하게 통과했다 -- when_to_use 가 비어있지 않다는 걸 직접 핀했다
     (test_when_to_use_is_non_empty, 새로 추가). Q1 이 render 쪽을 커버해서 이게 덜
     load-bearing 해졌지만 대체하지는 않는다 -- mechanism 이 렌더되는지와 when_to_use 가
     존재하는지는 서로 다른 사실이다.
  Q4 (문서만) 위 P4 절이 "test 2∪3" 처럼 라운드 1 이전 번호를 쓰고 있어서 라운드 1이 테스트를
     추가한 뒤로 번호가 밀렸다 -- 함수 이름으로 다시 썼다(번호는 순서가 바뀌면 또 샌다).
     `_macros()` 는 **테스트 프로세스의** ACTION_REGISTRY 를 읽는다 -- 실제로 떠 있는 서비스가
     다른 ACTION_REGISTRY 로 부팅됐으면 이 파일의 레지스트리 테스트들 전부가 그걸 못 본다.
     `test_no_compiled_program_shadows_seed_doc` 이 DSPY_PROGRAM 에 대해 이미 밝힌 것과 같은
     종류의 크로스-프로세스 한계라 `_macros()` 옆에도 적었다.

fix round 3 (S1-S5): 라운드 2 의 Q2 예외("같은 macro 의 mechanism 에도 있는 윈도우는 leak
판정에서 뺀다")를 지시한 것은 이 라운드를 시킨 바로 그 사람의 실수였다 -- 필터가 지켜야 할
**성질**이 아니라 **메커니즘**을 명명했고, 판별(attribution)과 탐지(detection)가 같은 필터
안에서 서로를 깎아 먹었다. 고친 원칙: 예외는 그대로 두고(판별용), 지켜야 할 성질은 **별도의,
렌더를 안 보는 어서션**으로 분리한다.
  S1 (Important) `mechanism.2 := mechanism.2 + " " + when_to_use.2` 로 정답 조건을 실제
     렌더된 프롬프트에 그대로 실어도 라운드 2 파일은 7개 전부 초록이었다 -- macro 0/1 은
     각자의 when_to_use 가 우연히 "Best when"/"Best on" 으로 시작해서 블록리스트가 대신
     잡아줬을 뿐, 구조적 방어가 아니었다. when_to_use 전체가 자신의 mechanism 안에 그대로
     박혀 있지 않은지를 JSON 만 보고 직접 재는 별도 어서션을 추가했다
     (test_when_to_use_is_not_embedded_in_own_mechanism -- 함수 docstring 에 round 5 로
     갱신된 증명이 있다).
  S2 (Important, **round 5 에서 재해석**) Q3 의 공허함(빈 문자열이면 루프가 안 돈다)이
     당시엔 Q2 의 예외를 통해 재발했다(실측: macro 2 윈도우 48개 중 48개가 스킵되어 실행
     0회). `executed > 0` 를 그때 넣었다 -- round 5 가 Q2 를 없앤 뒤로는 이 어서션이 그냥
     "when_to_use 가 비었을 때만 거짓"이 된다(Q3 와 사실상 같은 명제). 남긴다: 방어선이
     하나 더 있어서 나쁠 게 없다.
  S3 (Minor, **round 5 에서 뒤집힘**) 당시엔 Q2 의 예외가 macro 자기 자신의 mechanism 만
     봐서 크로스-macro 근접(`when_to_use[0]` 과 `mechanism[1]` 이 19자 공유, 20자 창보다
     한 글자 짧다)을 못 걸러낸다고만 문서화했다. round 5 가 Q2 를 없앴으므로 그 19자 근접이
     20자로 자라면 이제 이 파일이 **정당하게** 빨개진다 -- 다만 진짜 원인(누가 뭘 새게
     했는지)은 자동으로 못 가른다. 실패 메시지가 그 근접을 직접 언급한다(아래 test 함수).
  S4 (Minor, 문서만) 위 두 군데(P4 절, `_macros()` 의 docstring)의 "네 개"/"넷" 이 라운드 2
     가 테스트 두 개를 추가한 뒤로 정확히 2 만큼 틀려 있었다(`grep -n "for mid, m in
     _macros().items():"` 로 재확인 -- 이 패턴은 실제 반복문 줄만 잡고 프로즈의 백틱 인용은
     안 잡는다: 라운드 2 커밋(d06341d4)에서 여섯 곳, 이 라운드에서 S1 추가 후 일곱). 셀 때마다
     새로 셀 숫자를 프로즈에 박아두는 대신 숫자를 뺐다.
  S5 (Minor, 문서만) 두 결합을 각 테스트 옆에 적었다: (a) mechanism == "" 면
     `"" in rendered` 가 파이썬에서 언제나 True 라 test_doc_lines_renders_every_mechanism
     (Q1)은 그 macro 에 대해 공허하게 통과한다 -- P1(MIN_LEN=15)이 오늘의 유일한 방어선이고,
     그 문턱이 완화되면 Q1 은 조용히 그 macro 를 안 재게 된다. (b) `action_registry.py:197`
     이 여전히 구세대 `doc` 키로 폴백한다(`m.get("mechanism") or m.get("doc", "")`) --
     mechanism: "" 이면서 doc 키가 있는 macro 는 구세대 prose 를 렌더하므로 위 vacuity 는
     그대로 남는다. action_registry.py 는 이 라운드의 요청 범위 밖이라 안 건드렸다.

fix round 4 (T1-T4 + Q2 판단): 라운드 3 이 Q2 의 판별 예외를 봉인하려고 넣은 기계
(`executed > 0`) 와 새 어서션(S1)이 그 자체로 또 새 결함 세 개(T2/T3/T4)를 냈다 -- 이 파일이
스스로 인정한다: 같은 종류의 실수(불완전한 성질 명명, 검증 없는 프로즈 주장, 필터 아닌 손
계산으로 낸 숫자)가 반복되고 있다.
  T1 (Important, 위에 문서화) `_macros()` 가 빈 dict 를 돌려주면(레지스트리가 완전히 비고
     도장이 `v4-0arms` 로 같이 찍히면) 이 파일의 모든 루프가 빈 순회로 공허하게 통과해서
     8/8 이 초록이었다 -- Q1 이 존재하는 이유(doc_lines() 가 빈 배열을 내는 것)조차 못 잡는
     채로. `assert _macros()`(test_registry_is_non_empty)로 순수 공허는 닫았다; 부분 누락은
     이 파일 밖의 문제라고 위에 적었다(진실원을 지어내지 않는다).
  T2 (Minor, **round 5 에서 증명 갱신**) S1 은 독립 핀이 아니라 P4 와 같은 종류의
     **래퍼**다. 검증 방법에 결함이 있었다 -- 3글자 알파벳 무작위 탐색 5만 쌍으로 반례 0건을
     "증명"이라고 적었는데, 그 탐색이 20자 이상 우연 일치를 낼 확률은 약 3⁻²¹ 이라 애초에
     빨개질 수 없는 시험이었다(코디네이터 지적). 결론(래퍼다)은 맞았지만 증거가 틀렸다 --
     round 5 에서 embedding 을 직접 구성하는 방식으로 다시 쟀다(아래 함수 docstring).
  T3 (Minor, **round 5 에서 메시지 재작성**) `assert executed > 0` 메시지가 원인을 둘로만
     말해서 세 번째 경우(윈도우는 부분적으로만 겹침)를 거짓 진단했다. round 5 가 Q2 를
     없앤 뒤로는 그 세 번째 경우 자체가 없어졌다(스킵이 없으니까) -- 메시지를 그에 맞게
     다시 썼다.
  T4 (Minor) S4 의 "위 세 군데"가 틀렸다 -- 실제로는 두 군데였다. 위에서 고쳤다. 근거로 쓴
     grep 명령이 라운드마다 스스로의 인용에 걸리는 사고를 두 번(라운드 3→4, 그리고 라운드
     4 안에서 또 한 번) 냈다 -- 반복문 줄만 잡는 패턴으로 정리했고, 프로즈에서 그 명령을
     다시 인용할 때는 항상 결과를 다시 재서 붙인다(V3, 아래).

  Q2 를 없앨지 판단(지시받지 않음, 직접 판단): **남긴다.** [**round 5, V1 에서 뒤집힘 --
  이 판단은 측정으로 반증됐다. 아래 fix round 5 절을 볼 것. 이유 (3)이 특히 틀렸다:
  `executed > 0` 은 100% 스킵만 막지 51/52·34/52 스킵은 못 막는다.**] 실측(라이브
  레지스트리, 뮤테이션 없음): 194개 윈도우 중 Q2 예외가 스킵하는 것은 0개다. 그런데도
  남기기로 했던 이유는 세 가지였다: (1) Q2 가 고친 오귀속은 실재했다. (2) S1/S2 는 탐지를
  대신하지 판별은 못한다. (3) executed>0 이 Q2 를 구조적으로 안전하게 만든다고 봤다 --
  이 (3)이 틀렸다.

fix round 5 (V1-V4): round 4 의 Q2 존치 판단을 라운드 5 가 측정으로 뒤집었다.
  V1 (Important, 이전 판단의 번복) `mechanism.2` 에 `when_to_use.2` 를 한 글자 모자라게
     이어붙이자(`w[:-1]`) 9개 테스트 전부 초록이었고, 렌더된 프롬프트에 정답 조건 71자 중
     70자가 그대로 실렸다. 두 조각으로 쪼갠 변종(`w[:35] + " -- " + w[35:]`)도 9개 전부
     초록. 계측: reg_offbyone 은 macro 2 윈도우 52개 중 51개가 Q2 로 스킵됐고 Q2 없이
     검사했으면 51개가 히트했을 것이다; reg_split 은 34/52 스킵, Q2 없이는 34개 히트.
     블록리스트도(macro 2 의 "Cheaper than Replace…" 는 VERDICT_WORDS 에 없다) S1 도(부분
     문자열이지 전체가 아니라서) 안 잡는다. Q2 는 라이브 레지스트리에서 194개 윈도우 중
     0개를 막아온 예외이면서(여러 라운드에 걸쳐 반복 확인) 동시에 이런 규모의 거짓 음성을
     낼 수 있는 유일한 코드였다 -- `if chunk in own_mechanism_lower: continue` 를 없앴다.
     대가로 오귀속(엉뚱한 필드를 지목하는 실패 메시지)이 돌아온다 -- 검사가 놓치는 것보다
     메시지가 틀리는 게 싸다. 실패 메시지가 그 대가를 갚는다(아래 함수): 겹침이 발견되면
     그 macro 의 when_to_use 가 실제로 샌 것일 수도, 어느 macro 든(자기 자신 포함)
     mechanism 문구와의 합법적 겹침일 수도 있다고 두 필드를 다 짚고, 라이브 레지스트리의
     19자 근접(`when_to_use[0]` / `mechanism[1]`)을 직접 언급한다. `executed > 0` 은
     남긴다 -- 지금은 스킵이 아예 없으므로 "when_to_use 가 비었을 때만 거짓"이 되고, 그건
     정직한 상태다.
  V2 (문서만) `test_when_to_use_is_not_embedded_in_own_mechanism` 의 원래(round 3) 문단이
     "render 와 무관하게 성립하는 성질이라 Q2 와 서로 깎아먹지 않는다"고 적어놓고 세 줄 밑
     T2 문단에서 스스로 반증하고 있었다(T2: 이건 다른 검사의 부분집합이다). 그 자리에서
     바로 정정했다(아래 함수 docstring) -- 반증이 세 줄 밑에 있어도, 먼저 읽는 문장이 틀린
     채로 있으면 안 된다. task-3-report.md 의 round 3 self-review 절도 같은 주장("complementary
     rather than redundant")을 했으므로 거기도 정정했다.
  V3 (규칙) 이 파일의 프로즈에 들어가는 숫자는 그 숫자를 낸 명령의 붙여넣은 출력이어야
     한다 -- 손으로 더한 숫자는 안 된다. round 4 의 T4 절이 "11줄(7+4)"이라고 적었는데
     실제로는 13줄(7+6)이었다 -- 네 라운드째 반복된 실수라 숫자를 아예 뺐다(위 T4 절).
     이번 라운드에 새로 넣은 숫자(V1 의 51/52, 34/52, 194, T2 의 5,000쌍)는 전부 이 라운드
     안에서 직접 실행해 얻은 값이고, 각각의 raw 출력은 task-3-report.md 의 round 5 절에
     있다.
  V4 (Minor) `_leak_windows` 가 `len(text) <= window` 면 `[text]` 하나만 돌려주는데, 실패
     메시지는 그 경우에도 항상 "%d자 연속 구간" 에 고정된 `window`(20)를 찍었다 -- 10자짜리
     when_to_use 가 새도 "20자 연속 구간이... 'depot pool'" 처럼 말이 안 되는 메시지가
     났다(직접 구성해 확인). 메시지의 길이를 `window` 대신 `len(chunk)` 로 고쳤다.

  VERDICT_WORDS 가 비어있으면(모듈 상수, 입력 도달 불가) 이 파일에서 유일하게 어떤 T1-류
  가드도 없는 순회 지점이다 -- 요청받지 않았지만 T1 과 같은 한 줄 패턴이고 비용이 사실상
  0 이라 추가했다(아래 test_verdict_words_is_non_empty). 이유는 판단이고, 안 할 이유도
  있었다(요청 범위 밖, 입력 도달 불가라 T1 급 위험이 아님) -- report 에 적는다.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import action_registry  # noqa: E402

# 🔴 P2: 이것은 **블록리스트**다 -- "정답 조건이 없다"의 증명이 아니라 "알려진 몇 가지
# 문구가 없다"의 체크일 뿐이다. mechanism 이 여기 없는 다른 표현으로 정답 조건을 실어도 이
# 테스트는 못 잡는다(그래서 함수 이름이 …no_known_verdict_phrasing 이지 …no_verdict 가 아니다).
# 리뷰 라운드 1 실측: 구 목록(best when/best on/prefer /choose this/use this when)은
# "Best for a real fault…"(M6) 와 "Use it on a real fault…"(M7) 를 놓쳤다 -- 아래에 그
# 표현과 흔한 동의어를 추가했다. 이걸로도 여전히 완전하지 않다(리뷰 라운드 2 실측: 현실적인
# 검증 문구 6개 중 5개가 여전히 통과한다 -- 이 한계는 고치지 않기로 했다. 자연어 "정답 조건
# 다움"의 증명 없는 체크는 LLM 판정기 없이는 불가능하고, 이 유닛테스트엔 과하다).
VERDICT_WORDS = (
    "best when", "best on", "best for",
    "prefer ", "preferred when", "preferred for",
    "choose this", "use this when", "use it on", "use on",
    "ideal when", "ideal for",
    "right choice when", "correct choice when",
    "recommended when", "recommended for",
    "suited when", "suited for",
    "select this when", "pick this when",
)


def _macros():
    """레지스트리 JSON 을 로더와 **같은 경로**로 읽어 macros dict 를 돌려준다.

    🔴 Q4: 이 함수는 **이 테스트를 도는 프로세스의** `ACTION_REGISTRY` 환경변수를 읽는다
    (`action_registry.REGISTRY_PATH` 를 통해). 실제로 떠 있는 서비스 프로세스가 다른
    `ACTION_REGISTRY` 로 부팅됐으면, 이 함수는(따라서 이 파일의 레지스트리 테스트들 전부는)
    그 서비스가 실제로 무엇을 읽고 있는지 볼 수 없다 --
    `test_no_compiled_program_shadows_seed_doc` 이 `DSPY_PROGRAM` 에 대해 이미 밝힌 것과
    같은 종류의 크로스-프로세스 한계다."""
    with open(action_registry.REGISTRY_PATH, encoding="utf-8") as f:
        return json.load(f)["macros"]


def test_registry_is_non_empty():
    """🔴 T1 (fix round 4, Important, 1/2): 이 파일의 모든 어서션은 `_macros().items()` 를
    순회한다 -- 레지스트리가 완전히 비어있으면(`{"macros": {}, "vocab": "v4-0arms"}` 처럼
    도장의 arm 수와 실제 arm 수가 둘 다 0 으로 서로 맞으면 `action_registry.py` 의
    `assert_vocab_arm_count` 도 통과시킨다) 이 파일의 모든 루프 바디가 한 번도 안 돌고 여덟
    테스트 전부가 빈 순회로 공허하게 통과한다 -- `doc_lines() == []` 조차 Q1 을 못 잡는다
    (Q1 의 루프도 안 도니까). 이 한 줄이 그 순수 공허를 닫는다.

    이게 닫는 건 **완전** 공허뿐이다. **부분** 누락(예: SwapBattery 삭제 + 도장을
    `v4-2arms` 로 같이 조정)은 못 닫는다 -- 위 모듈 docstring 의 "이 게이트가 못 재는 것"
    절을 볼 것."""
    assert _macros(), (
        "레지스트리에 macro 가 하나도 없다 -- 이 파일의 모든 테스트가 빈 순회로 공허하게 "
        "통과한다."
    )


def test_every_macro_has_both_fields():
    """🔴 P4: 이 테스트는 단독으로 빨개질 수 없다 -- 가독성 래퍼일 뿐, 독립된 핀이 아니다.
    `mechanism` 이나 `when_to_use` 키가 사라지면 이 테스트도 실패하지만, 그 두 값을 직접
    인덱싱하는 `test_mechanism_carries_no_known_verdict_phrasing` /
    `test_doc_lines_never_renders_when_to_use` 가 같은 뮤테이션에서 먼저(또는 함께) KeyError 로
    죽는다 -- 이 테스트의 실패 집합은 그 둘의 합집합의 부분집합이다."""
    for mid, m in _macros().items():
        assert "mechanism" in m, "macro %s 에 mechanism 이 없다" % mid
        assert "when_to_use" in m, "macro %s 에 when_to_use 가 없다" % mid


def test_mechanism_is_non_empty_and_substantive():
    """🔴 P1: 빈 mechanism 은 그 팔을 프롬프트에서 지운다 -- `doc_lines()` 는
    "- SwapBattery (cost 0.2): " 처럼 이름·비용만 있고 설명이 없는 줄을 낸다. 이것이 정확히
    이 레지스트리가 막으려던 실패 모양이다(SwapBattery 가 어휘에 없어서 battery 적중이
    0/6→6/6 으로 갈렸던 실측, CLAUDE.md 340-341행). 길이 문턱은 임의값이지만 ""와 한 단어짜리
    스텁을 잡기엔 충분하다.

    🔴 Q1: 이 테스트는 JSON 을 핀할 뿐, 렌더를 안 잰다 -- `doc_lines()` 를 gut 해서 `[]` 를
    내거나 이름+비용만 내도 이 테스트는 초록이다(JSON 의 mechanism 자체는 안 건드렸으니까).
    렌더 쪽은 `test_doc_lines_renders_every_mechanism` 이 잰다."""
    MIN_LEN = 15
    for mid, m in _macros().items():
        text = m["mechanism"].strip()
        assert len(text) >= MIN_LEN, (
            "macro %s 의 mechanism 이 비어있거나 너무 짧다(%r) -- 그 팔이 프롬프트에서 "
            "사실상 안 보인다." % (mid, text)
        )


def test_doc_lines_renders_every_mechanism():
    """🔴 Q1 (fix round 2): P1 은 JSON 의 mechanism 이 비어있지 않은지만 잰다 -- 렌더가
    그걸 실제로 실어 나르는지는 아무도 안 쟀다. 리뷰 라운드 2 실측: `doc_lines()` 를
    `return []` 로 gut 하거나 이름+비용만 내게(`"- SwapBattery (cost 0.2):"`) 바꿔도 라운드 1
    의 다섯 테스트가 전부 초록이었다 -- 이 레지스트리의 창건 실패담(SwapBattery 가 프롬프트에서
    안 보여서 battery 적중이 0/6 이었던 실측)과 정확히 같은 모양의 구멍인데 아무 게이트도
    안 물었다. 렌더된 프롬프트 문자열 안에 각 macro 의 mechanism 원문이 실제로 있는지
    직접 잰다(대소문자·공백 그대로 -- `doc_lines()` 는 `text` 를 그대로 삽입하고 소문자화하지
    않는다).

    🔴 S5 (fix round 3, 문서만, 결합 두 개): (a) `mechanism == ""` 면 `"" in rendered` 가
    파이썬에서 언제나 True 라 이 어서션은 그 macro 에 대해 공허하게 통과한다 --
    `test_mechanism_is_non_empty_and_substantive`(P1, MIN_LEN=15)가 오늘의 유일한 방어선이고,
    그 문턱이 나중에 완화되면 이 테스트는 그 macro 에 대해 조용히 아무것도 안 재는 상태가
    된다. (b) `action_registry.py:197` 은 여전히 구세대 `doc` 키로 폴백한다
    (`m.get("mechanism") or m.get("doc", "")`) -- mechanism: "" 이면서 doc 키가 있는 macro 는
    구세대 prose 를 렌더하므로, 그 렌더된 문자열이 "" 가 아니게 되어도 (a)의 vacuity(빈
    mechanism 이 렌더에 실제로 있는지 이 테스트가 못 잰다는 사실)는 바뀌지 않는다.
    `action_registry.py` 는 이 라운드의 요청 범위 밖이라 안 건드렸다."""
    rendered = "\n".join(action_registry.doc_lines())
    for mid, m in _macros().items():
        assert m["mechanism"] in rendered, (
            "macro %s 의 mechanism 이 렌더된 프롬프트 안에 없다 -- doc_lines() 가 이 팔을 "
            "사실상 안 보이게 만들었다." % mid
        )


def test_mechanism_carries_no_known_verdict_phrasing():
    """🔴 P2: 이름을 정직하게 붙였다 -- 이것은 VERDICT_WORDS **블록리스트**의 검사이지,
    "mechanism 에 정답 조건이 전혀 없다"의 증명이 아니다. 블록리스트에 없는 표현으로 정답
    조건을 적으면 이 테스트는 통과한다. (구 이름 test_mechanism_carries_no_applicability_verdict
    는 이 한계를 안 밝혀서 증명인 것처럼 읽혔다.)"""
    for mid, m in _macros().items():
        low = m["mechanism"].lower()
        for w in VERDICT_WORDS:
            assert w not in low, "macro %s 의 mechanism 에 정답 조건이 샜다: %r" % (mid, w)


def test_verdict_words_is_non_empty():
    """🔴 fix round 5 (요청받지 않음, 선택): `VERDICT_WORDS` 는 이 파일에서 T1 류 가드가
    없는 유일한 순회 지점이었다 -- 비우면(`VERDICT_WORDS = ()`) 위 테스트의 안쪽 for 루프가
    한 번도 안 돌아서 공허하게 통과한다. `_macros()`(T1)와 달리 이건 입력으로 도달 불가능한
    **모듈 상수**라 T1 급 위험은 아니지만, 고치는 비용이 T1 과 똑같이 한 줄이라 안 할 이유가
    거의 없었다."""
    assert VERDICT_WORDS, (
        "VERDICT_WORDS 가 비어있다 -- test_mechanism_carries_no_known_verdict_phrasing 의 "
        "안쪽 루프가 공허하게 통과한다."
    )


def _leak_windows(text, window=20):
    """`text` 에서 길이 `window` 인 모든 연속 부분문자열. `text` 가 window 보다 짧으면
    `text` 전체 하나만."""
    text = text.strip()
    if not text:
        return []
    if len(text) <= window:
        return [text]
    return [text[i:i + window] for i in range(len(text) - window + 1)]


def test_when_to_use_is_non_empty():
    """🔴 Q3 (fix round 2): `when_to_use = ""` 면 `_leak_windows("")` 가 `[]` 를 돌려주고,
    `test_doc_lines_never_renders_when_to_use` 의 그 macro 에 대한 루프 바디가 한 번도 안
    돈다 -- 그 macro 의 leak 어서션이 **공허하게** 통과한다(빈 문자열은 정의상 "안 샌다").
    `when_to_use` 자체가 최소한 존재한다는 걸 직접 핀한다. `test_doc_lines_renders_every_mechanism`
    (Q1)이 렌더 쪽을 커버해서 이 핀의 하중이 줄었지만 대체하지는 않는다 -- mechanism 이
    렌더되는가와 when_to_use 가 비어있지 않은가는 서로 다른 사실이다."""
    for mid, m in _macros().items():
        text = m["when_to_use"].strip()
        assert len(text) > 0, (
            "macro %s 의 when_to_use 가 비어있다 -- 비어있으면 그 macro 의 leak 검사가 "
            "공허하게 통과한다(빈 문자열은 정의상 '안 샌다')." % mid
        )


def test_when_to_use_is_not_embedded_in_own_mechanism():
    """🔴 S1 (fix round 3, Important): mechanism 에 when_to_use 전체가 그대로 이어붙는 경우를
    render 를 안 보고 JSON 만으로 직접 잡는다. 실측(round 3): `mechanism.2 := mechanism.2 +
    " " + when_to_use.2` 로 정답 조건이 실제 렌더에 실렸는데도 당시 파일은 7개 전부 초록이었다
    -- macro 0/1 은 각자의 when_to_use 가 우연히 VERDICT_WORDS 문구("Best when"/"Best on")로
    시작해서 블록리스트가 대신 잡아줬을 뿐, 구조적 방어가 아니었다(macro 2 의 "Cheaper than
    Replace…" 는 블록리스트를 안 문다).

    🔴 [round 5, V2 정정] 이 자리에 원래(round 3) "render 와 무관하게 성립해야 하는 성질이라
    render-기반 예외와 서로 깎아먹지 않는다"고 적혀 있었다. 틀렸다 -- 바로 아래 T2 문단이
    이 테스트는 독립 성질이 아니라 다른 검사의 **부분집합**이라고 증명한다. 셋째 줄 밑에서
    스스로 반증되는 주장을 그 자리에 방치하지 않는다(task-3-report.md 의 같은 절도 정정함).

    🔴 T2 (fix round 4, Minor, round 5 에서 증명 갱신): 이 테스트는 독립 핀이 아니라 P4 와
    같은 종류의 **래퍼**다. 증명(round 5): when_to_use 가 mechanism 의 부분문자열이면,
    mechanism 자신이 `doc_lines()` 에 그대로 렌더되므로(Q1) when_to_use 의 모든 윈도우도
    렌더된 텍스트의 부분문자열이 된다 -- 즉 `test_doc_lines_never_renders_when_to_use` 의
    첫 윈도우 검사에서 곧바로(사실은 먼저) 빨개진다. 검증: 무작위 텍스트가 우연히 겹치기를
    기다리는 대신 when_to_use 를 mechanism 안에 실제로 심어 넣은 쌍을 직접 구성했다(5,000쌍,
    길이 3~145자, 단어 조합 텍스트) -- 이 함의를 어긴 사례 0건(raw 출력은
    task-3-report.md 의 round 5 절). [round 4 의 검증은 3글자 알파벳 무작위 탐색이었는데,
    20자 이상 우연 일치가 나올 확률이 약 3⁻²¹ 이라 애초에 빨개질 수 없는 시험이었다(round 5
    지적) -- 결론은 맞았지만 증거가 아니었다.] 그래도 남기는 이유: 탐지력은 안 늘리지만
    mechanism 에 이어붙는 흔한 편집 모양에 대해 즉시 정확한 진단("전체가 박혔다")을 준다 --
    P4 가 세운 관행(래퍼는 스스로 그렇다고 선언한다)을 따른다."""
    for mid, m in _macros().items():
        when_to_use = m["when_to_use"].strip().lower()
        if not when_to_use:
            continue  # 빈 when_to_use 는 test_when_to_use_is_non_empty(Q3)의 몫
        mechanism = m["mechanism"].lower()
        assert when_to_use not in mechanism, (
            "macro %s 의 when_to_use 전체가 자신의 mechanism 안에 그대로 박혀 있다 -- 정답 "
            "조건이 mechanism 에 이어붙은 것이다." % mid
        )


def test_doc_lines_never_renders_when_to_use():
    """🔴 P2 (M8): 구 버전은 `when_to_use.lower()[:24]` 고정 **접두**만 봤다. 리뷰 라운드 1
    실측: `doc_lines()` 가 `when_to_use[10:]` (꼬리만, 접두가 아니라)를 새게 만드는 뮤테이션에서
    4개 게이트가 전부 초록이었다 -- 거의 문장 전체가 나갔는데도. 접두 대신 20자 슬라이딩
    윈도우로 검사한다: `when_to_use` 안의 어떤 연속 20자 구간도 렌더링된 프롬프트에 있으면
    안 된다 -- 접두든 꼬리든 중간이든 위치에 상관없이 잡는다.

    🔴 [round 2~4 는 "그 macro 자신의 mechanism 에도 있는 윈도우는 스킵" 예외(Q2)를
    넣었다가(round 2) 감쌌다가(S2/S3, round 3) 구조적으로 안전하다고 판단했다(round 4) --
    round 5 가 측정으로 그 판단을 뒤집고 예외를 없앴다. 지금 코드는 예외 없이 모든 윈도우를
    검사한다. 옛 역사는 위 모듈 docstring 의 round 2~4 절에 있다(지우지 않는다 -- 감사용).]

    ⚠️ fix round 5, V1 (Important, 이전 판단의 번복): round 4 는 `executed > 0` 가 Q2 를
    구조적으로 안전하게 만든다고 판단해서 남겼다. 측정으로 반증됐다 -- 그 어서션은 **100%
    스킵**만 막지 **거의 100%** 스킵은 못 막는다. 실측(라이브 레지스트리, 뮤테이션):
    `mechanism.2` 에 `when_to_use.2` 를 한 글자 모자라게 이어붙이자(`w[:-1]`) 9개 테스트
    전부 초록이었고, 렌더된 프롬프트에 정답 조건 71자 중 70자가 그대로 실렸다(macro 2 윈도우
    52개 중 51개가 Q2 로 스킵, Q2 없이 검사했으면 51개가 히트했을 것). 두 조각으로 쪼갠
    변종(`w[:35] + " -- " + w[35:]`)도 9개 전부 초록(34/52 스킵, Q2 없이는 34개 히트).
    블록리스트도(macro 2 의 "Cheaper than Replace…" 는 VERDICT_WORDS 에 없다) S1 도(부분
    문자열이지 전체가 아니라서) 안 잡는다. Q2 는 라이브 레지스트리에서 194개 윈도우 중
    0개를 막아온 예외이면서(여러 라운드에 걸쳐 반복 확인) 동시에 이런 규모의 거짓 음성을
    낼 수 있는 유일한 코드였다 -- 없앴다. 대가로 오귀속(엉뚱한 필드를 지목하는 실패 메시지)
    이 돌아온다 -- 검사가 놓치는 것보다 메시지가 틀리는 게 싸다. 아래 실패 메시지가 그
    대가를 갚는다: 겹침이 발견되면 그 macro 의 when_to_use 가 실제로 샌 것일 수도, 어느
    macro 든(자기 자신 포함) mechanism 문구와의 합법적 겹침일 수도 있다고 두 필드를 다
    짚고, 라이브 레지스트리의 19자 근접(`when_to_use[0]` / `mechanism[1]`, `' a scarce
    resource.'`, 20자 창보다 한 글자 짧다)을 직접 언급한다 -- 이 근접이 20자로 자라는
    평범한 mechanism.1 편집 하나가 이제 이 테스트를 정당하게 빨갛게 만들 수 있다는 뜻이다.

    🔴 V4 (Minor): `_leak_windows` 는 `len(text) <= 20` 이면 `text` 전체 하나만 돌려주는데,
    옛 메시지는 그 경우에도 항상 고정된 `window`(20)로 "20자 연속 구간"이라고 말했다 --
    10자짜리 when_to_use 가 새도 "20자 연속 구간이... 'depot pool'"(10자인데) 같은 말이
    안 되는 메시지가 났다(직접 구성해 확인). 메시지 길이를 `window` 대신 실제 `len(chunk)`
    로 고쳤다.

    `executed > 0` 은 남긴다(round 4, S2) -- 지금은 스킵이 아예 없으므로 "when_to_use 가
    비었을 때만 거짓"이 되고(Q3 와 사실상 같은 명제), 그게 정직한 상태다."""
    rendered = "\n".join(action_registry.doc_lines()).lower()
    window = 20
    for mid, m in _macros().items():
        windows = _leak_windows(m["when_to_use"].lower(), window=window)
        executed = 0
        for chunk in windows:
            executed += 1
            assert chunk not in rendered, (
                "macro %s 의 when_to_use 에서 %d자 연속 구간이 프롬프트로 샜다: %r -- 이 "
                "macro 의 when_to_use 가 실제로 샌 것일 수도 있고, 어느 macro 든(같은 macro "
                "자신 포함) mechanism 문구와 우연히 겹치는 합법적 렌더일 수도 있다(mechanism "
                "은 원래 렌더된다). 라이브 레지스트리에서 when_to_use[0] 과 mechanism[1] 이 "
                "이미 19자를 공유하므로(20자 창보다 한 글자 짧다) 이런 근접은 드물지 않다 -- "
                "관련된 macro·필드를 전부 확인할 것." % (mid, len(chunk), chunk)
            )
        assert executed > 0, (
            "macro %s 의 when_to_use 가 비어있어서 leak 검사가 공허하게 통과했다(윈도우 0개)."
            % mid
        )


# ---- SEED_DOC 이 컴파일 산출물에 조용히 갈아치워지지 않는지 ----------------------------
# dspy_service._load_program() 은 PROGRAM 파일이 있으면
# `prog.signature = prog.signature.with_instructions(instr)` 로 SEED_DOC(따라서 이 파일이
# 만든 mechanism/when_to_use 분리)을 통째로 대체한다.
def test_no_compiled_program_shadows_seed_doc():
    """🔴 P3: 예전 버전은 `PROGRAM == ""` 를 어서션했는데, 이 레포의 문서화된 LLM 레인 설정은
    `DSPY_PROGRAM=__seed_only__` 다(.claude/CLAUDE.md Gotchas, 342행). 그 값은 `""` 가 아니고
    `os.path.exists("__seed_only__")` 도 False 라 SEED_DOC 은 실제로 안 갈리는데, 예전 어서션은
    `PROGRAM == ""` 만 봐서 이 문서화된 정상 설정에서 헛불을 냈다(리뷰 라운드 1 실측:
    `PROGRAM='__seed_only__'` 에서 1 failed).

    지켜야 하는 명제는 "PROGRAM 이 빈 문자열이다"가 아니라 "SEED_DOC 이 실제로 안 갈렸다"이므로
    `_load_program()` 을 실행하고 live `_state["instructions"]` 가 `SEED_DOC` 인지 직접 잰다.
    컴파일 산출물이 진짜로 나타나면(`instr` 이 있고 `with_instructions()` 가 불림) 이 값은
    `SEED_DOC` 이 아니게 되고 이 테스트가 빨개진다.

    한계: 이 테스트는 **테스트 프로세스 안에서** `_load_program()` 을 새로 호출해 잰다. 실제로
    떠 있는 dspy_service 프로세스의 `_state` 를 재는 게 아니다 -- 서비스가 이미 다른 PROGRAM
    값으로 부팅된 상태를 이 테스트가 관측하지는 못한다. 서비스 재기동 시점의 환경변수가 이
    테스트를 도는 프로세스의 환경변수와 같다는 전제 위에 서 있다."""
    llm_service_dir = os.path.join(HERE, "..", "..", "src", "respec", "llm_service")
    llm_service_dir = os.path.abspath(llm_service_dir)
    if llm_service_dir not in sys.path:
        sys.path.insert(0, llm_service_dir)
    import dspy_service  # noqa: E402

    dspy_service._load_program()
    assert dspy_service._state["instructions"] == dspy_service.SEED_DOC, (
        "_load_program() 이후 live instructions 가 SEED_DOC 이 아니다 -- 컴파일된 프로그램이 "
        "mechanism/when_to_use 분리를 실제 프롬프트 경로에서 갈아치웠다는 뜻이다."
    )
