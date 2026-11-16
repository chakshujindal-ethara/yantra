"""The trusted role header: parsed into a set, rendered in a fixed order, and the role guards."""

import pytest

from yantra_common.deps import (
    parse_roles,
    require_admin,
    require_admin_or_ops,
    require_any,
    require_client,
    require_finance,
    require_finance_or_ops,
    require_ops,
    require_reviewer,
    require_worker,
    role_header,
    roles,
)
from yantra_common.errors import Forbidden


def test_parse_roles_splits_on_commas_and_ignores_blanks():
    assert parse_roles("ops,client,worker") == frozenset({"ops", "client", "worker"})
    assert parse_roles(" worker , ops ") == frozenset({"worker", "ops"})
    assert parse_roles("") == frozenset() and parse_roles(None) == frozenset() and parse_roles(",,") == frozenset()
    assert roles("client") == frozenset({"client"}) and roles(None) == frozenset()


def test_role_header_keeps_known_roles_in_a_fixed_order_and_drops_the_rest():
    assert role_header({"worker", "client"}) == "client,worker"
    assert role_header(frozenset({"worker", "ops", "client"})) == "ops,client,worker"
    assert role_header({"worker", "reviewer", "finance", "ops", "admin", "client"}) == (
        "admin,ops,finance,reviewer,client,worker"
    )
    assert role_header({"ops"}) == "ops"
    assert role_header({"offline_access", "mfa-required"}) == ""
    assert role_header(set()) == ""


def test_require_any_passes_on_any_listed_role_and_names_the_requirement():
    guard = require_any("a", "b", message="a or b required")
    guard("a")
    guard("x,b")
    with pytest.raises(Forbidden, match="a or b required"):
        guard("x")


@pytest.mark.parametrize(
    ("guard", "passes", "fails", "message"),
    [
        (
            require_ops,
            ["ops", "ops,client,worker"],
            [None, "", "worker", "client,worker", "admin", "finance"],
            "operator",
        ),
        (require_finance, ["finance", "ops,finance"], [None, "ops", "admin", "worker"], "finance role required"),
        (require_finance_or_ops, ["finance", "ops"], [None, "admin", "worker", "client"], "finance or operator"),
        (require_reviewer, ["reviewer", "worker,reviewer", "ops"], [None, "worker", "client", "admin"], "reviewer"),
        (require_admin, ["admin"], [None, "ops", "finance", "worker"], "admin role required"),
        (require_admin_or_ops, ["admin", "ops"], [None, "finance", "worker"], "admin or operator"),
        (require_client, ["client", "client,worker", "ops"], [None, "", "worker", "admin"], "client role required"),
        (require_worker, ["worker", "client,worker", "ops"], [None, "", "client", "admin", "reviewer"], "worker role"),
    ],
)
def test_each_guard_passes_its_roles_and_refuses_the_rest(guard, passes, fails, message):
    for held in passes:
        guard(held)
    for held in fails:
        with pytest.raises(Forbidden, match=message):
            guard(held)
