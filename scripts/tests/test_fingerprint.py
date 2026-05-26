from scripts.lib.fingerprint import fingerprint, normalize


def test_normalize_strips_blank_lines_and_whitespace() -> None:
    snippet = "  foo( 1 )  \n\n\tbar(\"x\")  \n"
    assert normalize(snippet) == 'foo( N )\nbar("S")'


def test_normalize_keeps_identifiers_while_normalizing_literals() -> None:
    left = 'alpha = fetch_value("prod", 42)'
    right = 'beta = fetch_value("stage", 99)'
    assert normalize(left) == 'alpha = fetch_value("S", N)'
    assert normalize(right) == 'beta = fetch_value("S", N)'


def test_fingerprint_ignores_string_literal_only_changes() -> None:
    before = 'println("hello")'
    after_a = 'println("world")'
    after_b = 'println("again")'
    assert fingerprint(before, after_a) == fingerprint(before, after_b)


def test_fingerprint_changes_for_different_api_calls() -> None:
    existing = "val y = x"
    improved_a = "requireNotNull(x)"
    improved_b = "checkNotNull(x)"
    assert fingerprint(existing, improved_a) != fingerprint(existing, improved_b)


def test_fingerprint_empty_payload_is_stable() -> None:
    value = fingerprint("", "")
    assert value
    assert value == fingerprint("", "")
