# The JSON API the Flutter client consumes, plus the ACL-checked media proxies
# the admin client needs for private-S3 images and clips.
#
# THE SERVER-RENDERED CANDIDATE SURFACE IS GONE. `portal` and `candidate_portal`
# rendered a second, complete exam runner - around 6,000 lines with its templates
# and stylesheet - duplicating what the Flutter client does over `/api/v1`. Two
# implementations of one exam is a drift generator rather than a fallback: the
# violation dedupe, the auto-submit and the answer-diffing rule were each written
# twice and each pair drifted, and the repairs are recorded in those very
# methods. `legacy_redirects` keeps all nine of their paths registered and sends
# them to the app - see its docstring for why that is mandatory rather than
# tidy-minded (upstream `etp_assessment_pro` declares the same nine, and losing
# them to it fails silently with an HTTP 200).
#
# The token-scoped exam media stays in `exam_media` and the admin media in
# `admin_media`: pro's copies of both were dropped during the port rather than
# ported onto the same URLs, which would leave two handlers per path. Neither is
# part of the retirement - the Flutter client uses both.
#
# IMPORT ORDER IS LOAD ORDER, and only the last entry cares. `load_shed` patches
# `Request._serve_db`, so it must be imported after everything that defines a
# route; the rest are independent and their order is alphabetical-ish by age.
from . import api
from . import admin_media
from . import exam_media
from . import legacy_redirects
# Liveness and readiness. Separate module because these are the only routes that
# must answer WITHOUT the database - see the file's docstring for why a probe
# that borrows a connection is worse than no probe at all.
from . import health

# LAST, and it is not a controller. `load_shed` patches `Request._serve_db` so
# a full connection pool answers 503 instead of 500 - the exhaustion happens
# before any controller is matched, so it cannot be a route. Imported here
# because this package is what the module loads.
from . import load_shed
