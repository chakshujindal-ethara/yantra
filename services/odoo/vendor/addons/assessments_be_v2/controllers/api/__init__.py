# -*- coding: utf-8 -*-
"""The JSON API the Flutter client talks to.

It lives INSIDE assessments_be_v2 rather than in a separate addon because it
is not an independent product: every route here reads or writes this module's
own models and calls this module's own ``action_*`` methods. A second addon
would have to be installed, versioned and migrated in lockstep with this one
for no benefit, and would break the moment a field moved.

``common`` is imported first: it defines the envelope decorator the other
three depend on at import time.
"""

from . import common
from . import auth
from . import candidate
from . import admin
from . import write
from . import forms
from . import task_templates
