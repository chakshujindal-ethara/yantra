from yantra_analytics.models import Base
from yantra_common.migrations import run

run("analytics", Base.metadata)
