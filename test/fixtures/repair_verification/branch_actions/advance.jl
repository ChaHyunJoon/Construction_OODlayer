# T4 fixture: advance the engine inside the action without the trusted adapter → the worker's engine-advance guard
# must refuse to continue (batch alignment would be wrong) → error.json(stage=action) → UNKNOWN.
using ConstructionBots
branch_action!(env) = (ConstructionBots.step_environment!(env); nothing)
