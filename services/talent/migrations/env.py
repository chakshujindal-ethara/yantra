from yantra_common.migrations import run
from yantra_talent.models import Base

run("talent", Base.metadata)
