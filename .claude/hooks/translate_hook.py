#!/usr/bin/env python
"""
translate_hook.py -- Claude Code PostToolUse hook.

When an Edit/Write touches the LLM prompt or schema
(src/respec/llm_service/propose.py or schema.py), auto-run the FAST env-free
translation smoke (tools/translate_eval.py --quick) and feed the result back into
Claude's context via `additionalContext`. No-op for any other file.

Wired in .claude/settings.json; invoked with the hjcnlp interpreter (the one that
has `anthropic`), which is therefore sys.executable here.
"""
# =============================================================================
# [한국어 설명]
#  이 파일이 하는 일:
#   - Claude Code의 "PostToolUse 훅(hook)". 파일 편집이 끝난 직후 자동 실행된다.
#   - 방금 편집한 파일이 LLM 프롬프트/스키마(propose.py 또는 schema.py)이면,
#     빠른 번역 스모크 테스트(tools/translate_eval.py --quick)를 자동으로 돌리고,
#     그 결과를 Claude의 문맥(context)에 additionalContext로 되돌려 넣어 준다.
#   - 그 두 파일이 아니면 아무것도 안 하고 조용히 종료(no-op).
#
#  프로젝트에서의 역할:
#   - re-spec(LLM) 레이어의 프롬프트를 고칠 때마다 사람이 테스트를 까먹지 않도록,
#     편집 즉시 "번역이 여전히 잘 되는가"를 자동 점검하는 안전장치.
#
#  훅 동작 방식:
#   - Claude Code가 이 스크립트를 실행하며 표준입력(stdin)으로 JSON payload를 준다
#     (어떤 도구가 어떤 파일을 건드렸는지 등).
#   - 스크립트는 표준출력(stdout)으로 JSON을 한 번 찍어 결과를 돌려준다.
#
#  문법 참고 (파이썬 초보용):
#   · json.load(sys.stdin)  = 표준입력으로 들어온 JSON을 dict로 읽음.
#   · json.dumps(dict)      = dict를 JSON 문자열로 바꿔 print(=stdout으로 반환).
#   · subprocess.run(...)   = 외부 명령 실행 후 결과(returncode/stdout/stderr) 수집.
#   · 문자열[-2500:]        = 슬라이싱, 뒤에서 2500글자만(로그가 너무 길지 않게 자름).
#   · "%d" % 값             = 옛 스타일 문자열 포매팅(= f-string의 옛 방식).
#   · sys.exit(0)           = 정상 종료. 훅은 대부분 0으로 끝냄(실패로 막지 않으려고).
# =============================================================================
import json
import os
import subprocess
import sys

# 이 파일(.claude/hooks/translate_hook.py)에서 상위 폴더 3번 올라가면 프로젝트 최상위.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# Claude Code에 결과 메시지를 되돌려 주는 헬퍼: 정해진 JSON 형식으로 stdout에 한 줄 출력.
def emit(msg):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse", "additionalContext": msg}}))


# 훅 본체: stdin의 payload를 읽고, 편집 대상이 번역 레이어면 스모크 테스트를 돌린다.
def main():
    try:
        payload = json.load(sys.stdin)   # Claude Code가 넘겨준 훅 입력(JSON)
    except Exception:
        sys.exit(0)   # 입력이 이상하면 조용히 통과(훅이 작업을 막지 않도록)
    # 편집된 파일 경로를 꺼내고 역슬래시를 슬래시로 통일(윈도우 경로 대응). None이면 "" 처리.
    fp = (payload.get("tool_input", {}).get("file_path", "") or "").replace("\\", "/")
    if not (fp.endswith("src/respec/llm_service/propose.py")
            or fp.endswith("src/respec/llm_service/schema.py")):
        sys.exit(0)  # not a translation-layer edit  # 번역 레이어 파일이 아니면 그냥 종료

    if not os.environ.get("ANTHROPIC_API_KEY"):   # 키가 없으면 테스트를 못 도니 안내만 하고 종료
        emit("Auto translation smoke SKIPPED: ANTHROPIC_API_KEY is not set in Claude "
             "Code's environment. Restart Claude Code from a shell that exported the "
             "key to enable the auto smoke, or run tools/translate_eval.py manually.")
        sys.exit(0)

    harness = os.path.join(ROOT, "tools", "translate_eval.py")     # 돌릴 스모크 스크립트
    fixture = os.path.join(ROOT, "tools", "llm_fixture.json")      # 필요한 fixture 데이터
    if not os.path.exists(fixture):   # fixture가 없으면 만드는 법 안내 후 종료
        emit("Auto translation smoke SKIPPED: tools/llm_fixture.json missing. Build it "
             "once with: julia +lts --project=. tools/dump_llm_fixture.jl")
        sys.exit(0)

    try:
        # translate_eval.py --quick 를 자식 프로세스로 실행(같은 인터프리터 sys.executable 사용).
        r = subprocess.run([sys.executable, harness, "--quick"],
                           capture_output=True, text=True, timeout=180)  # 출력 캡처, 최대 180초
        out = (r.stdout or "")[-2500:]   # 표준출력 뒤쪽 2500글자만(문맥에 과하게 넣지 않게)
        if r.stderr:
            out += "\n[stderr]\n" + r.stderr[-600:]   # 에러 출력도 뒤 600글자 덧붙임
        verdict = "ALL PASS" if r.returncode == 0 else "FAILURES (exit %d)" % r.returncode  # 종료코드로 판정
    except subprocess.TimeoutExpired:
        out, verdict = "(timed out after 180s)", "TIMEOUT"   # 시간 초과 시

    # 결과 요약을 Claude 문맥으로 돌려줌. os.path.basename(fp) = 편집한 파일 이름만.
    emit(f"Auto translation smoke ran after editing {os.path.basename(fp)} "
         f"(env-free, precede, propose() in-process) -> {verdict}:\n\n{out}")


if __name__ == "__main__":   # 훅으로 직접 실행될 때만 main() 호출
    main()
