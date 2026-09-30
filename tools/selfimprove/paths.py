import os
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
A0_REGISTRY = os.path.join(ROOT, "src", "decision", "core", "action_registry.json")
A0_DATASET = os.path.join(ROOT, "data", "oracle", "oracle_dataset.jsonl")
WORLD_INTERFACE = os.path.join(ROOT, "src", "decision", "core", "world_interface.json")
FEATURE_SCHEMA_FILES = [os.path.join(ROOT, "src", "decision", p) for p in
                        ("core/features_agnostic.py", "surrogate/surrogate_features.py",
                         "surrogate/surrogate_v2.py")]

def data_dir(exp):
    return os.path.join(os.environ.get("SELFIMPROVE_DATA_ROOT",
                                       os.path.join(ROOT, "data", "selfimprove")), exp)

def state_dir(exp):
    return os.path.join(os.environ.get("SELFIMPROVE_STATE_ROOT",
                                       os.path.join(ROOT, "results", "selfimprove")), exp)

def version_dir(exp, v):
    return os.path.join(data_dir(exp), "versions", v)
