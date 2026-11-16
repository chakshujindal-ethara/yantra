from yantra_assess.models import Base
from yantra_common.migrations import run

run("assess", Base.metadata)
