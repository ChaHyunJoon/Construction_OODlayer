# Python setup

This repo needs **two separate Python environments**. They cannot be merged: the
RVO2 collision-avoidance binding is a Cython extension built against Python 3.7,
while the analysis stack needs a modern scikit-learn/pandas that no longer
supports 3.7.

| | purpose | Python | installed via |
|---|---|---|---|
| **analysis env** | surrogate training, oracle analysis, drift/novelty, DSPy decision service | 3.10 | `requirements.txt` |
| **simulator env** | `rvo2` only — reached from Julia through PyCall | 3.7 | built from Python-RVO2 source |

On the machine these results were produced on, those were
`…/venv/hjcrl` (3.10.11) and the conda env `lego_rvo2` (3.7.12).

---

## 1. Analysis environment

```bash
python -m venv .venv          # or conda create -n cbots-analysis python=3.10
. .venv/Scripts/activate      # Windows;  source .venv/bin/activate elsewhere
pip install -r requirements.txt
```

Check it:

```bash
python -c "import sklearn, pandas, numpy; print(sklearn.__version__, pandas.__version__, numpy.__version__)"
# expected: 1.6.1 2.2.3 2.x
```

`scikit-learn` and `pandas` are pinned exactly. The deployed surrogate is a
RandomForest, and its splits — hence the reported decision regret — can shift
between minor releases. Unpin only if you intend to re-measure.

### numpy: the recorded environment is not pip-reproducible

The machine that produced the 2026-07 results ran these versions:

| package | recorded | note |
|---|---|---|
| scikit-learn | 1.6.1 | pinned |
| pandas | 2.2.3 | pinned |
| **numpy** | **1.23.5** | **cannot be installed alongside dspy** |
| scipy | 1.15.1 | |
| dspy | 3.2.1 | declares `numpy>=1.26.0` |
| openai / anthropic | 2.48.0 / 0.112.0 | |
| fastapi / uvicorn / pydantic | 0.138.1 / 0.49.0 / 2.13.4 | |
| matplotlib / python-pptx / psutil | 3.10.0 / 1.0.2 / 6.1.1 | |

`dspy 3.2.1` requires `numpy>=1.26.0`, so `pip install` of that exact set fails
with `ResolutionImpossible`. The two only coexisted because they were installed
at different times and pip never re-checked. `requirements.txt` therefore floors
numpy at 1.26 (scipy caps it below 2.5), which is what a clean machine gets.

This matters if a number moves. The surrogate is a RandomForest with a fixed
`random_state`, so its structure is not expected to change — but floating-point
summation order can differ across numpy majors, and no one has re-measured
decision regret under numpy 2.x. If a result disagrees with the recorded one,
check this before assuming a code bug. To force the original numpy, install it
last with its dependency check bypassed:

```bash
pip install -r requirements.txt
pip install --no-deps --force-reinstall numpy==1.23.5   # reproduces the recorded state
```

## 2. Simulator environment (rvo2 + PyCall)

`rvo2` is not on PyPI. It is built from
[Python-RVO2](https://github.com/sybrenstuvel/Python-RVO2), which is **not
vendored here** (separate license, and it needs a compiler):

```bash
conda create -n lego_rvo2 python=3.7 cython=0.29
conda activate lego_rvo2
git clone https://github.com/sybrenstuvel/Python-RVO2
cd Python-RVO2 && python setup.py build && python setup.py install
python -c "import rvo2; print('rvo2 OK')"
```

Then point PyCall at that interpreter **once**, from the repo root:

```julia
ENV["PYTHON"] = raw"C:\path\to\envs\lego_rvo2\python.exe"   # full path to the 3.7 interpreter
using Pkg; Pkg.build("PyCall")
```

Verify:

```julia
using PyCall; pyimport("rvo2")        # must not throw
```

If PyCall points at the analysis environment instead, every simulation that runs
with `rvo2_flag = true` fails — and note that turning RVO off is not a valid
workaround for labelling: with collision avoidance disabled the oracle's
best-macro answers change.

## 3. Julia side

Julia dependencies come from `Project.toml`. **Use the LTS release** — installing
under 1.12 breaks the build quietly:

```bash
julia +lts --project=. -e 'using Pkg; Pkg.instantiate()'
```

## 4. Known machine-specific leftovers

Two helper scripts still carry absolute interpreter paths from the original
machine and need editing after a move:

- `tools/translate_eval.py:13`
- `tools/verify_battery_translation.py:12`

Everything else derives its paths from the script or package location.
