"""The work deployable's tests: the HTTP surface and the event loop against the migrated test database
(market and quality schemas) and the local NATS."""

from yantra_analytics.models import TABLES as ANALYTICS_TABLES
from yantra_analytics.testing import ALEMBIC_INI as ANALYTICS_INI
from yantra_assess.models import TABLES as ASSESS_TABLES
from yantra_assess.testing import ALEMBIC_INI as ASSESS_INI
from yantra_market.testing import database_fixtures
from yantra_notify.models import TABLES as NOTIFY_TABLES
from yantra_notify.testing import ALEMBIC_INI as NOTIFY_INI
from yantra_quality.models import TABLES as QUALITY_TABLES
from yantra_quality.testing import ALEMBIC_INI as QUALITY_INI
from yantra_talent.models import TABLES as TALENT_TABLES
from yantra_talent.testing import ALEMBIC_INI as TALENT_INI
from yantra_tracker.models import TABLES as TRACKER_TABLES
from yantra_tracker.testing import ALEMBIC_INI as TRACKER_INI

engine, factory, clean_tables = database_fixtures(
    "yantra_work_test",
    [TALENT_INI, ASSESS_INI, QUALITY_INI, NOTIFY_INI, TRACKER_INI, ANALYTICS_INI],
    [*TALENT_TABLES, *ASSESS_TABLES, *QUALITY_TABLES, *NOTIFY_TABLES, *TRACKER_TABLES, *ANALYTICS_TABLES],
)
