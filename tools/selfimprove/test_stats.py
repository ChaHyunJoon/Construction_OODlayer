from tools.selfimprove import stats

def test_wilson_lower_matches_review_numbers():
    assert abs(stats.wilson_lower(44, 47) - 0.83) < 0.01
    assert abs(stats.wilson_lower(20, 60) - 0.227) < 0.005
    assert stats.wilson_lower(0, 0) == 0.0

def test_mcnemar_one_sided_exact():
    assert abs(stats.mcnemar_one_sided(5, 0) - 1 / 32) < 1e-12
    assert stats.mcnemar_one_sided(0, 0) == 1.0
    assert abs(stats.mcnemar_one_sided(3, 1) - 5 / 16) < 1e-12
