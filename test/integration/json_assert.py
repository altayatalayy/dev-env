#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load(path: str):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def get(value, dotted: str):
    for part in dotted.split(".") if dotted else []:
        if isinstance(value, list):
            value = value[int(part)]
        else:
            value = value[part]
    return value


def parse_scalar(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def fail(msg: str) -> int:
    print(msg, file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) < 4:
        return fail("usage: json_assert.py <exists|equals|contains|not-contains|contains-field|len> <file> <path> [value...]")
    command, file_name, path = sys.argv[1:4]
    actual = get(load(file_name), path)

    if command == "exists":
        return 0
    if command == "contains-field":
        if len(sys.argv) != 6:
            return fail("contains-field requires <file> <list-path> <field> <value>")
        field = sys.argv[4]
        expected = parse_scalar(sys.argv[5])
        if not isinstance(actual, list):
            return fail(f"{path}: expected list, got {type(actual).__name__}")
        for item in actual:
            if isinstance(item, dict) and item.get(field) == expected:
                return 0
        return fail(f"{path}: no object with {field}={expected!r} in {actual!r}")
    if command == "len":
        expected = int(sys.argv[4])
        return 0 if len(actual) == expected else fail(f"{path}: expected length {expected}, got {len(actual)}")
    if len(sys.argv) != 5:
        return fail(f"{command} requires a value")
    expected = parse_scalar(sys.argv[4])
    if command == "equals":
        return 0 if actual == expected else fail(f"{path}: expected {expected!r}, got {actual!r}")
    if command == "contains":
        return 0 if expected in actual else fail(f"{path}: {expected!r} not in {actual!r}")
    if command == "not-contains":
        return 0 if expected not in actual else fail(f"{path}: {expected!r} unexpectedly in {actual!r}")
    return fail(f"unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
