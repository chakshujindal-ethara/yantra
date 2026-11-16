from yantra_common.migrations import run
from yantra_market.models import Base

run("market", Base.metadata)
