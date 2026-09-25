# T4 fixture: the branch action throws → worker writes error.json(stage=action) and exits non-zero → UNKNOWN.
branch_action!(env) = error("zrv fixture: deliberate exception inside the branch action")
