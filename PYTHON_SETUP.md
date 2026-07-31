# Python setup

Two things need Python: the **analysis stack** (surrogate training, oracle
analysis, drift/novelty, the DSPy decision service) and the **`rvo2` collision
-avoidance binding**, which Julia reaches through PyCall.

Whether that is one environment or two depends on the machine.

| | how it was set up on the original Windows machine | what to do on a fresh machine |
|---|---|---|
| analysis | `…/venv/hjcrl`, Python 3.10.11 | one env from `requirements.txt` |
| `rvo2` | conda `lego_rvo2`, Python **3.7.12** | **same env** — see below |

**The 3.7 was incidental, not a requirement.** Python-RVO2 declares no
`python_requires`; its classifiers list 2.7/3.4 and the README says it was tested
on 2.7/3.4/3.6. That environment simply happened to be old. On a new machine,
build `rvo2` into the analysis environment and keep **one** environment.

The one hard rule is that PyCall's interpreter must be the one `rvo2` is
installed into, and it must match Julia's architecture (arm64 Julia needs arm64
Python — not an x86 build under Rosetta).

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

## 1b. macOS / Apple Silicon (Mac Studio) — single environment

Python 3.7 is not available for arm64 (conda-forge's osx-arm64 starts at 3.8),
so the original two-environment split cannot be reproduced here — and does not
need to be. Use **Python 3.11**: it is the newest version `Cython 0.29.x`
supports, and `Cython 3.x` breaks this binding's old-style sources.
scikit-learn 1.6, pandas 2.2 and numpy ≥1.26 all support 3.11, so one
environment covers everything.

```bash
brew install cmake juliaup            # cmake is required to build RVO2
juliaup add lts

# arm64 Python 3.11 (miniforge, python.org universal2 or brew all work)
conda create -n cbots python=3.11 -y && conda activate cbots
python -c "import platform; print(platform.machine())"     # must print arm64

pip install -r requirements.txt
pip install "Cython<3"                # 0.29.x — Cython 3 breaks the RVO2 sources

git clone https://github.com/sybrenstuvel/Python-RVO2 /tmp/Python-RVO2
cd /tmp/Python-RVO2 && python setup.py build && python setup.py install && cd -
python -c "import rvo2; print('rvo2 OK')"
```

Then bind PyCall to that interpreter, from the repo root:

```bash
julia +lts --project=. -e 'ENV["PYTHON"]=strip(read(`which python`,String)); using Pkg; Pkg.build("PyCall")'
julia +lts --project=. -e 'using PyCall; pyimport("rvo2"); println("PyCall+rvo2 OK")'
```

> Not yet verified on Apple Silicon — the build has only been run on Windows.
> If `setup.py build` fails, the likely causes in order are: `cmake` missing,
> Cython 3 installed instead of 0.29.x, or an architecture mismatch between the
> Python and the compiler. Dropping to Python 3.10 or 3.9 is the next thing to
> try; falling back to a separate 3.7 environment is a last resort and would
> require an x86 Julia under Rosetta to match it.

## 2. Simulator environment (rvo2 + PyCall) — Windows / two-environment case

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
