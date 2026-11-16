from yantra_common.migrations import run
from yantra_payout.models import Base

run("payout", Base.metadata)
