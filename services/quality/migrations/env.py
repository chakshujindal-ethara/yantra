from yantra_common.migrations import run
from yantra_quality.models import Base

run("quality", Base.metadata)
