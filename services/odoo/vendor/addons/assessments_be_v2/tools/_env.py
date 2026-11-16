"""Where the probe scripts point, and who they sign in as.

Every script here used to carry `http://localhost:7070`, `admin`/`admin` and a
candidate password as literals, from when they lived in a private checkout. In
the repo they are shared, so the values move to the environment and the
literals become localhost-only defaults.

    ETP_API                 default http://localhost:8069
    ETP_DB                  default etp_local
    ETP_ADMIN_LOGIN         default admin
    ETP_ADMIN_PASSWORD      default admin
    ETP_CANDIDATE_LOGIN     default priya.sharma@example.com
    ETP_CANDIDATE_PASSWORD  no default

`require_local_or_explicit()` is the guard that matters: the defaults are only
safe because nothing but a local dev server answers on localhost with
admin/admin. Point ETP_API at anything else and the script refuses to run until
the credentials are given explicitly, so a copy-pasted command cannot drive a
shared environment with a guessed password.
"""
import os
import sys
from urllib.parse import urlparse

API = os.environ.get("ETP_API", "http://localhost:8069").rstrip("/")
# NOT ethara_ops. That was the deleted private checkout's database and it still
# carries that checkout's shape: the Project OS addons installed, and
# employee_extension uninstalled - so assessments_be_v2 cannot load there
# against this repo's manifest. etp_local matches the repo.
DB = os.environ.get("ETP_DB", "etp_local")

ADMIN_LOGIN = os.environ.get("ETP_ADMIN_LOGIN", "admin")
ADMIN_PASSWORD = os.environ.get("ETP_ADMIN_PASSWORD", "admin")

CANDIDATE_LOGIN = os.environ.get("ETP_CANDIDATE_LOGIN",
                                 "priya.sharma@example.com")
CANDIDATE_PASSWORD = os.environ.get("ETP_CANDIDATE_PASSWORD", "")

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "[::1]"}


def is_local(url=None):
    return (urlparse(url or API).hostname or "") in _LOCAL_HOSTS


def require_local_or_explicit():
    """Refuse a non-local target unless the operator named the credentials."""
    if is_local():
        return
    missing = [name for name, value in
               (("ETP_ADMIN_LOGIN", os.environ.get("ETP_ADMIN_LOGIN")),
                ("ETP_ADMIN_PASSWORD", os.environ.get("ETP_ADMIN_PASSWORD")))
               if not value]
    if missing:
        sys.exit(
            "refusing to run against %s with default credentials.\n"
            "Set %s, or point ETP_API at a local server."
            % (API, " and ".join(missing)))
