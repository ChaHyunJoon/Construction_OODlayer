"""버전 신원의 모델 쪽 보조 검사 (spec §5.4 규칙 6). 정책 전체의 신원은 manifest 필드가 진다."""
import hashlib, json

def probe_sha256(model, rows):
    p = model.predict_complete_proba(rows)
    j = model.predict_J(rows)
    vals = [[round(float(a), 9), round(float(b), 6)] for a, b in zip(p, j)]
    return hashlib.sha256(json.dumps(vals).encode()).hexdigest()
