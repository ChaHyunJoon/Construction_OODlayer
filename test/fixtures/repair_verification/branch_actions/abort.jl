# T4 fixture: hard crash (SIGABRT) inside the branch action → no error.json → UNKNOWN worker_crash.
branch_action!(env) = ccall(:abort, Cvoid, ())
