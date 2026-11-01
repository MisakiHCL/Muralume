#!/usr/bin/env bash

set -euo pipefail

readonly project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/MuralumeLocalizationTests.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT

python3 - "${project_root}/Scripts/lib/check_localizations.py" "${test_root}" <<'PY'
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import sys

checker, temporary = Path(sys.argv[1]), Path(sys.argv[2])
project = temporary / "Project"
resources = project / "Muralume/Resources"
language_source = project / "Muralume/Application/Settings/AppLanguage.swift"
english = {
    "plain.title": "Videos",
    "count": "%d files",
    "reorder": "%@ has %02d files",
    "long": "%ld records",
    "literal": "Progress: %d%%",
    "dynamic": "%*.*f",
    "pair": "%d / %d",
}
plural = {
    "count": {
        "NSStringLocalizedFormatKey": "%#@count@",
        "count": {
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "d",
            "one": "%d file", "other": "%d files",
        },
    },
}


def write_strings(locale, values):
    path = resources / f"{locale}.lproj/Localizable.strings"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(
        f"{json.dumps(key)} = {json.dumps(value, ensure_ascii=False)};"
        for key, value in values.items()
    ) + "\n")
    return path


def write_plural(locale, values):
    path = resources / f"{locale}.lproj/Localizable.stringsdict"
    path.write_bytes(plistlib.dumps(values))
    return path


def fixture():
    shutil.rmtree(project, ignore_errors=True)
    language_source.parent.mkdir(parents=True)
    language_source.write_text('''enum AppLanguage: String {
    case system
    case english = "en"
    case french = "fr"
    var key: String {
        switch self {
        case .system: "system"
        case .english: "English"
        case .french: "French"
        }
    }
}
''')
    for locale in ("en", "fr"):
        write_strings(locale, english)
        write_plural(locale, plural)


def run(*arguments, rejected=None):
    result = subprocess.run(
        [sys.executable, str(checker), "--project-root", str(project), *map(str, arguments)],
        capture_output=True, text=True,
    )
    output = result.stdout + result.stderr
    if rejected is None:
        assert result.returncode == 0, output
    else:
        assert result.returncode != 0, f"Invalid localization was accepted: {rejected}"
        assert rejected in output, (rejected, output)
    return result


def bad_string(key, value, diagnostic="printf"):
    fixture()
    write_strings("fr", {**english, key: value})
    run(rejected=diagnostic)


def bad_plural(change, diagnostic):
    fixture()
    value = plistlib.loads(plistlib.dumps(plural))
    change(value)
    write_plural("fr", value)
    run(rejected=diagnostic)


fixture()
run()
assert run("--list-locales").stdout.splitlines() == ["en", "fr"]
# A new AppLanguage case must require resources without changing the validator.
language_source.write_text(language_source.read_text().replace(
    'case french = "fr"', 'case french = "fr"\n    case italian = "it"'
))
run(rejected="it.lproj")
fixture()
shutil.rmtree(resources / "fr.lproj")
run(rejected="Missing localization resource")
fixture()
(resources / "fr.lproj/Localizable.stringsdict").unlink()
run(rejected="Missing localization resource")
fixture()
write_strings("fr", {key: value for key, value in english.items() if key != "plain.title"})
run(rejected="missing keys")
fixture()
write_strings("fr", {**english, "unexpected": "Extra"})
run(rejected="extra keys")
fixture()
path = resources / "fr.lproj/Localizable.strings"
with path.open("a") as output:
    output.write('/* Not a key: "ignored" = "ignored"; */\n')
    output.write('"plain\\U002Etitle" = "Escaped duplicate";\n')
run(rejected="duplicate .strings key")
bad_string("plain.title", " \t\n ", "empty")
bad_string("reorder", "%d has %d files")
bad_string("reorder", "%@ has files")
bad_string("reorder", "%@ has %d files %d")
bad_string("long", "%lld records")
bad_string("reorder", "%2$@ has %1$d files")
bad_string("reorder", "%2$d files for %@", "Mixed positional")
bad_string("reorder", "%1$d files for %1$@", "Conflicting printf types")
bad_string("reorder", "%3$d files for %1$@", "indices must be contiguous")
bad_string("count", "%q files", "Invalid printf conversion")
bad_string("dynamic", "%3$*2$.*1$f")
bad_string("pair", "%1$d / %1$d")
fixture()
write_strings("fr", {
    **english, "reorder": "%2$02d fichiers pour %1$@",
    "literal": "%1$d%% terminé", "dynamic": "%3$*1$.*2$f",
})
run()  # Explicit reordering, width padding, stars and %% are safe.
bad_plural(lambda value: value["count"]["count"].pop("other"), "need other")
bad_plural(lambda value: value["count"]["count"].update(other=" "), "empty plural")
bad_plural(lambda value: value["count"]["count"].update(other="%ld files"), "plural argument bindings")
bad_plural(lambda value: value["count"]["count"].update(other="files"), "plural argument bindings")
bad_plural(lambda value: value["count"]["count"].update(NSStringFormatValueTypeKey="ld"), "value type d")
bad_plural(lambda value: value["count"]["count"].update(NSStringFormatSpecTypeKey="NSStringGenderRuleType"), "NSStringPluralRuleType")
bad_plural(lambda value: value["count"].update(NSStringLocalizedFormatKey="%#@missing@"), "variables do not match")
bad_plural(lambda value: value.update(extra=value["count"]), "extra keys")
fixture()
write_plural("fr", {})
run(rejected="nonempty localization dictionary")
fixture()
for locale in ("en", "fr"):
    write_strings(locale, {**english, "count": "%@ files"})
run(rejected="plural key must take one decimal count")
fixture()
path = resources / "fr.lproj/Localizable.stringsdict"
path.write_text(path.read_text().replace(
    "</dict>", "<key>other</key><string>%d duplicate</string></dict>", 1
))
run(rejected="duplicate key")
fixture()
# Text plist resources may be UTF-16; duplicate checks still precede plutil.
path = resources / "fr.lproj/Localizable.stringsdict"
path.write_bytes(path.read_text().replace('encoding="UTF-8"', 'encoding="UTF-16"').encode("utf-16"))
run()
fixture()
path = resources / "fr.lproj/Localizable.strings"
path.write_bytes(plistlib.dumps(english))
run()
path.write_text(path.read_text().replace(
    "</dict>", "<key>plain.title</key><string>Duplicate</string></dict>", 1
))
run(rejected="duplicate key")
fixture()
subprocess.run(["plutil", "-convert", "binary1", str(resources / "fr.lproj/Localizable.strings")], check=True)
run(rejected="source resources must be text")
# Bundle validation derives the same locale set and accepts Xcode's binary
# .strings output while continuing to inspect every plural resource.
fixture()
bundle = temporary / "BundleResources"
shutil.copytree(resources, bundle)
for locale in ("en", "fr"):
    subprocess.run(["plutil", "-convert", "binary1", str(bundle / f"{locale}.lproj/Localizable.strings")], check=True)
    path = bundle / f"{locale}.lproj/Localizable.stringsdict"
    # Xcode's CopyStringsFile output keeps the UTF-8 declaration even though
    # the bytes have a UTF-16 BOM. Apple plutil accepts this compiled resource.
    path.write_bytes(path.read_text().encode("utf-16"))
run("--bundle-resources", bundle)
# The encoding accommodation must not bypass duplicate detection in sources.
path = resources / "fr.lproj/Localizable.stringsdict"
path.write_bytes(path.read_text().replace(
    "</dict>", "<key>other</key><string>%d duplicate</string></dict>", 1
).encode("utf-16"))
run(rejected="duplicate key")
write_plural("fr", plural)
(bundle / "fr.lproj/Localizable.stringsdict").unlink()
run("--bundle-resources", bundle, rejected="Missing localization resource")
shutil.rmtree(bundle / "fr.lproj")
run("--bundle-resources", bundle, rejected="Missing localization resource")
print("PASS: supported locales, key coverage, duplicate keys, printf bindings, plural rules, and bundled localizations")
PY
