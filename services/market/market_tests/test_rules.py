from decimal import Decimal

from yantra_market.rules import check_answer, check_schema, depth, margin, validate_lines

SCHEMA = {"type": "object", "required": ["text"], "properties": {"text": {"type": "string", "minLength": 1}}}


def test_validate_lines_numbers_lines_from_one_and_names_the_field():
    lines: list[dict[str, object]] = [
        {"external_ref": "a", "payload": {"text": "ok"}},
        {"external_ref": "b", "payload": {"text": ""}},
        {"payload": {}},
        {"external_ref": "c"},
        {"external_ref": "d", "payload": {"text": "x"}, "assigned_worker_id": "not-a-uuid"},
        {"external_ref": "x" * 201, "payload": {"text": "x"}},
    ]
    report, accepted = validate_lines(SCHEMA, lines, existing_refs=set())
    assert (report.total, report.accepted) == (6, 1)
    assert [e.line for e in report.errors] == [2, 3, 4, 5, 6]
    assert report.errors[0].reason.startswith("payload: text:")
    assert report.errors[1].reason.startswith("external_ref: missing")
    assert report.errors[2].reason == "payload: must be an object"
    assert report.errors[3].reason == "assigned_worker_id: not a UUID"
    assert len(report.errors[4].external_ref) == 200
    assert [a.external_ref for a in accepted] == ["a"]


def test_a_permissive_schema_still_requires_a_payload_object():
    report, _ = validate_lines({}, [{"external_ref": "a"}, {"external_ref": "b", "payload": "str"}], set())
    assert [e.reason for e in report.errors] == ["payload: must be an object", "payload: must be an object"]


def test_validate_lines_rejects_refs_already_in_the_batch_and_deep_payloads():
    deep: dict[str, object] = {"text": "x"}
    for _ in range(40):
        deep = {"n": deep}
    report, _ = validate_lines(
        SCHEMA,
        [{"external_ref": "a", "payload": {"text": "x"}}, {"external_ref": "b", "payload": deep}],
        existing_refs={"a"},
    )
    assert [e.reason for e in report.errors] == ["duplicate external_ref", "payload: nests deeper than 32 levels"]


def test_margin_is_a_fraction_of_price_and_never_divides_by_zero():
    assert margin(Decimal("60"), Decimal("28"), Decimal("6")) == Decimal("0.4333")
    assert margin(Decimal("0"), Decimal("1"), Decimal("0")) == Decimal("0")
    assert margin(Decimal("10"), Decimal("12"), Decimal("0")) == Decimal("-0.2000")


def test_check_schema_refuses_refs_long_patterns_and_invalid_schemas():
    assert check_schema(SCHEMA) is None
    assert check_schema({"$ref": "https://evil/x"}) == "$ref is not allowed"
    assert check_schema({"properties": {"a": {"$ref": "#/x"}}}) == "$ref is not allowed"
    assert check_schema({"type": "string", "pattern": "a" * 201}) == "pattern longer than 200 characters"
    assert check_schema({"patternProperties": {"b" * 201: {}}}) == "patternProperties longer than 200 characters"
    assert str(check_schema({"type": "not-a-type"})).startswith("not a valid JSON Schema")
    deep: dict[str, object] = {}
    for _ in range(40):
        deep = {"properties": {"a": deep}}
    assert check_schema(deep) == "schema nests deeper than 32 levels"


def test_depth_counts_nesting_of_dicts_and_lists():
    assert depth(1) == 0
    assert depth({}) == 1
    assert depth({"a": [1, {"b": 2}]}) == 3


def test_check_answer_names_the_first_problem_by_path():
    schema = {
        "type": "object",
        "required": ["a"],
        "properties": {"a": {"type": "string"}, "b": {"type": "array", "items": {"type": "integer"}}},
    }
    assert check_answer(schema, {"a": "x"}) is None
    assert check_answer(schema, {}) == "'a' is a required property"
    assert check_answer(schema, {"a": "x", "b": [1, "two", 3.5]}) == "b/1: 'two' is not of type 'integer'"
    assert check_answer(schema, {"a": 1, "b": ["z"]}) == "a: 1 is not of type 'string'"
