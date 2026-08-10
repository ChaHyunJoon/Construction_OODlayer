# 오염된 산출물 격리 (2026-08-10 08:27)

`run_step_d_zcausal.sh` 가 `--dry-run` 플래그를 무시하고 실제로 `julia tools/restage.jl causal` 을
실행했다. 그 결과 08:16~08:27 사이에 **julia 시뮬 2개가 동시에** 돌았다:

- zcausal 팔 (blk_noop 완주 08:23, blk_reloc 중단)
- STEP E 라우터 레인 (seed 1: 08:13-08:19, seed 2: 08:21-)

README 함정 30 위반. HiGHS 가 CPU 경합에 따라 **다른 스케줄**을 내므로 이 구간에 나온 값은
정책/팔 비교에 쓸 수 없다. 특히 zcausal 은 팔끼리 반사실 비교를 하는 실험이라 치명적이다.

따라서 아래는 전부 폐기하고 **단독 순차 실행으로 재측정**한다. 참고용으로만 남긴다.

- `zcausal_reform/blk_noop.json` — 경합 중 생성 (재실행 필요)
- `llm_ood_eval_router.jsonl` — seed 1·2, 경합 구간 (재실행 필요)
