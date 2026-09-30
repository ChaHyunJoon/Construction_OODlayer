"""S3 판정에 쓰는 두 통계 (spec §9.4). 사전 등록값 — 바꾸면 게이트의 의미가 바뀐다."""
import math


def wilson_lower(k, n, z=1.959964):
    """이항 비율 k/n 의 Wilson 95% 하한. n=0 → 0.0."""
    if n == 0:
        return 0.0
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    return (c - z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / d


def mcnemar_one_sided(b, c):
    """정확 McNemar 단측: P(X ≥ b | X ~ Bin(b+c, ½)). b = 앞 팔만 완주, c = 뒤 팔만 완주."""
    n = b + c
    if n == 0:
        return 1.0
    return sum(math.comb(n, i) for i in range(b, n + 1)) / 2 ** n
