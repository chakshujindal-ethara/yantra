from yantra_common.migrations import run
from yantra_notify.models import Base

run("notify", Base.metadata)
