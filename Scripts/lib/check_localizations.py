#!/usr/bin/env python3
"""Validate supported source localizations and, optionally, compiled resources."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


class ValidationError(ValueError):
    pass


PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many", "other"}
FORMAT = re.compile(
    r"%(?:(?P<position>[1-9]\d*)\$)?(?P<flags>[-+#0 ']*)(?P<width>\*(?:[1-9]\d*\$)?|\d+)?"
    r"(?:\.(?P<precision>\*(?:[1-9]\d*\$)?|\d*))?"
    r"(?P<length>hh|ll|[hljztLq])?(?P<conversion>[@diuoxXfFeEgGaAcCsSpDUO])"
)
PLURAL_REFERENCE = re.compile(r"%(?:(?P<position>[1-9]\d*)\$)?#@(?P<name>[A-Za-z_]\w*)@")


def supported_locales(path: Path) -> list[str]:
    text = re.sub(r"/\*.*?\*/|//[^\n]*", "", path.read_text(), flags=re.S)
    declaration = re.search(r"\benum\s+AppLanguage\s*:\s*String\b[^\{]*\{", text)
    if declaration is None:
        raise ValidationError("Cannot find the String-backed AppLanguage enum")
    locales = []
    depth = 0
    saw_system = False
    for line in text[declaration.end():].splitlines():
        stripped = line.strip()
        if depth == 0 and stripped.startswith("case "):
            for definition in stripped[5:].split(","):
                match = re.fullmatch(r'\s*(\w+)(?:\s*=\s*"([A-Za-z0-9-]+)")?\s*', definition)
                if match is None:
                    raise ValidationError("Cannot parse an AppLanguage case raw value")
                name, locale = match.groups()
                if name == "system":
                    saw_system = True
                    continue
                if locale is None or not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*", locale):
                    raise ValidationError(f"AppLanguage case {name} needs an explicit locale raw value")
                if locale in locales:
                    raise ValidationError(f"Duplicate AppLanguage locale: {locale}")
                locales.append(locale)
        # AppLanguage's declarations use no braces inside string literals.
        depth += line.count("{") - line.count("}")
        if depth < 0:
            break
    if not saw_system or "en" not in locales or not locales:
        raise ValidationError("AppLanguage must declare system and English localizations")
    return locales


def format_arguments(value: str) -> Counter:
    """Return bound argument indices, exact conversion/length, and argument roles."""
    arguments = []
    position_modes = set()
    next_index = 1

    def add(position, kind, role):
        nonlocal next_index
        position_modes.add(position is not None)
        index = int(position) if position is not None else next_index
        if position is None:
            next_index += 1
        arguments.append((index, kind, role))

    offset = 0
    while offset < len(value):
        if value[offset] != "%":
            offset += 1
            continue
        if value.startswith("%%", offset):
            offset += 2
            continue
        match = FORMAT.match(value, offset)
        if match is None:
            raise ValidationError(f"Invalid printf conversion near {value[offset:offset + 16]!r}")
        conversion = match["conversion"]
        length = match["length"] or ""
        allowed = ("", "h", "hh", "l", "ll", "q", "j", "z", "t") if conversion in "diuoxX" else (
            ("", "l", "L") if conversion in "fFeEgGaA" else (
                ("", "l") if conversion in "cs" else ("",)
            )
        )
        if length not in allowed:
            raise ValidationError(f"Invalid printf length {length!r} for %{conversion}")
        for role in ("width", "precision"):
            specification = match[role]
            if specification and specification.startswith("*"):
                explicit = specification[1:-1] if specification.endswith("$") else None
                add(explicit, "d", role)
        add(match["position"], length + conversion, "value")
        offset = match.end()
    if len(position_modes) > 1:
        raise ValidationError("Mixed positional and implicit printf arguments")
    indices = {argument[0] for argument in arguments}
    if indices and max(indices) != len(indices):
        raise ValidationError("Printf argument indices must be contiguous starting at 1")
    types_by_index = {}
    for index, kind, _ in arguments:
        if index in types_by_index and types_by_index[index] != kind:
            raise ValidationError(f"Conflicting printf types for argument {index}")
        types_by_index[index] = kind
    return Counter(arguments)


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"Duplicate key: {key}")
        result[key] = value
    return result


def check_xml_duplicates(element, path: Path):
    if element.tag == "dict":
        seen = set()
        children = list(element)
        if len(children) % 2:
            raise ValidationError(f"{path}: malformed plist dictionary")
        for index in range(0, len(children), 2):
            key = children[index]
            if key.tag != "key":
                raise ValidationError(f"{path}: expected a plist dictionary key")
            if key.text in seen:
                raise ValidationError(f"{path}: duplicate key {key.text!r}")
            seen.add(key.text)
    for child in element:
        check_xml_duplicates(child, path)


def openstep_keys(text: str) -> list[str]:
    """Read quoted .strings pairs before plutil can collapse duplicate keys."""
    offset = 0

    def skip_space():
        nonlocal offset
        while offset < len(text):
            if text[offset].isspace():
                offset += 1
            elif text.startswith("//", offset):
                newline = text.find("\n", offset + 2)
                offset = len(text) if newline < 0 else newline + 1
            elif text.startswith("/*", offset):
                end = text.find("*/", offset + 2)
                if end < 0:
                    raise ValidationError("Unterminated .strings comment")
                offset = end + 2
            else:
                break

    def expect(character):
        nonlocal offset
        skip_space()
        if offset >= len(text) or text[offset] != character:
            raise ValidationError(f"Expected {character!r} in .strings at character {offset}")
        offset += 1

    def quoted():
        nonlocal offset
        expect('"')
        result = []
        escapes = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v"}
        while offset < len(text):
            character = text[offset]
            offset += 1
            if character == '"':
                return "".join(result).encode("utf-16-le", "surrogatepass").decode("utf-16-le")
            if character != "\\":
                result.append(character)
                continue
            if offset >= len(text):
                break
            character = text[offset]
            offset += 1
            if character in escapes:
                result.append(escapes[character])
            elif character in "uU":
                digits = text[offset:offset + 4]
                if not re.fullmatch(r"[0-9A-Fa-f]{4}", digits):
                    raise ValidationError("Invalid Unicode escape in .strings")
                result.append(chr(int(digits, 16)))
                offset += 4
            elif character in "01234567":
                digits = character
                while len(digits) < 3 and offset < len(text) and text[offset] in "01234567":
                    digits += text[offset]
                    offset += 1
                result.append(chr(int(digits, 8)))
            elif character == "\n":
                continue
            else:
                raise ValidationError(f"Unsupported .strings escape: \\{character}")
        raise ValidationError("Unterminated .strings value")

    keys = []
    skip_space()
    while offset < len(text):
        keys.append(quoted())
        expect("=")
        quoted()
        expect(";")
        skip_space()
    return keys


def load_plist(path: Path, source: bool):
    if not path.is_file():
        raise ValidationError(f"Missing localization resource: {path}")
    raw = path.read_bytes()
    if raw.startswith(b"bplist"):
        if source:
            raise ValidationError(f"{path}: source resources must be text to check duplicate keys")
    else:
        text = raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig")
        if text.lstrip().startswith("<"):
            # CopyStringsFile can emit UTF-16 with an unchanged UTF-8 XML
            # declaration. Inspect the BOM-decoded text for duplicate keys;
            # plutil below remains the authority for accepting the actual file.
            check_xml_duplicates(ET.fromstring(text), path)
        else:
            if path.suffix != ".strings":
                raise ValidationError(f"{path}: expected an XML .stringsdict")
            keys = openstep_keys(text)
            if len(keys) != len(set(keys)):
                raise ValidationError(f"{path}: duplicate .strings key")
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True, check=False
    )
    if result.returncode:
        raise ValidationError(f"{path}: plutil could not parse the resource: {result.stderr.strip()}")
    value = json.loads(result.stdout, object_pairs_hook=unique_json_object)
    if not isinstance(value, dict) or not value:
        raise ValidationError(f"{path}: expected a nonempty localization dictionary")
    return value


def require_same_keys(actual, expected, context):
    missing, extra = set(expected) - set(actual), set(actual) - set(expected)
    if missing or extra:
        raise ValidationError(f"{context}: missing keys {sorted(missing)}; extra keys {sorted(extra)}")


def validate_strings(values, baseline, context):
    require_same_keys(values, baseline, context)
    for key, value in values.items():
        if not isinstance(value, str) or not value.strip():
            raise ValidationError(f"{context}: empty or non-string value for {key}")
        try:
            if format_arguments(value) != format_arguments(baseline[key]):
                raise ValidationError("printf argument bindings differ from English")
        except ValidationError as error:
            raise ValidationError(f"{context}: {key}: {error}") from error


def validate_plurals(values, baseline, plain, context):
    require_same_keys(values, baseline, context)
    expected_count = Counter({(1, "d", "value"): 1})
    for key, definition in values.items():
        if key not in plain or format_arguments(plain[key]) != expected_count:
            raise ValidationError(f"{context}: {key}: plural key must take one decimal count in .strings")
        if not isinstance(definition, dict):
            raise ValidationError(f"{context}: {key}: expected a plural dictionary")
        localized_format = definition.get("NSStringLocalizedFormatKey")
        if not isinstance(localized_format, str) or not localized_format.strip():
            raise ValidationError(f"{context}: {key}: missing or empty NSStringLocalizedFormatKey")
        references = list(PLURAL_REFERENCE.finditer(localized_format))
        variables = {reference["name"] for reference in references}
        if not variables or set(definition) != variables | {"NSStringLocalizedFormatKey"}:
            raise ValidationError(f"{context}: {key}: plural variables do not match the localized format")
        expanded = PLURAL_REFERENCE.sub(
            lambda match: "%" + (match["position"] + "$" if match["position"] else "") + "d",
            localized_format
        )
        if format_arguments(expanded) != expected_count:
            raise ValidationError(f"{context}: {key}: plural format has incorrect count bindings")
        for name in variables:
            rule = definition[name]
            if not isinstance(rule, dict) or rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType" \
                    or rule.get("NSStringFormatValueTypeKey") != "d":
                raise ValidationError(f"{context}: {key}.{name}: expected NSStringPluralRuleType with value type d")
            branches = set(rule) - {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
            if "other" not in branches or not branches <= PLURAL_CATEGORIES:
                raise ValidationError(f"{context}: {key}.{name}: plural rules need other and valid categories")
            for branch in branches:
                text = rule[branch]
                if not isinstance(text, str) or not text.strip():
                    raise ValidationError(f"{context}: {key}.{name}.{branch}: empty plural value")
                if format_arguments(text) != expected_count:
                    raise ValidationError(f"{context}: {key}.{name}.{branch}: plural argument bindings differ from .strings")


def validate_resources(resources: Path, locales: list[str], english, english_plurals, source: bool):
    for locale in locales:
        directory = resources / (locale + ".lproj")
        strings = load_plist(directory / "Localizable.strings", source)
        plurals = load_plist(directory / "Localizable.stringsdict", source)
        validate_strings(strings, english, str(directory))
        validate_plurals(plurals, english_plurals, strings, str(directory))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--bundle-resources", type=Path)
    parser.add_argument("--list-locales", action="store_true")
    arguments = parser.parse_args()
    root = arguments.project_root
    locales = supported_locales(root / "Muralume/Application/Settings/AppLanguage.swift")
    if arguments.list_locales:
        print("\n".join(locales))
        return
    resources = root / "Muralume/Resources"
    english = load_plist(resources / "en.lproj/Localizable.strings", True)
    english_plurals = load_plist(resources / "en.lproj/Localizable.stringsdict", True)
    validate_resources(resources, locales, english, english_plurals, True)
    if arguments.bundle_resources is not None:
        validate_resources(arguments.bundle_resources, locales, english, english_plurals, False)
    print(f"Validated {len(locales)} localizations, {len(english)} strings and {len(english_plurals)} plural keys per locale.")


if __name__ == "__main__":
    try:
        main()
    except (ValidationError, OSError, UnicodeError, ET.ParseError, json.JSONDecodeError) as error:
        print(f"Localization validation failed: {error}", file=sys.stderr)
        sys.exit(1)
