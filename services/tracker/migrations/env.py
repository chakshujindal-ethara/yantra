from yantra_common.migrations import run
from yantra_tracker.models import Base

run("tracker", Base.metadata)
