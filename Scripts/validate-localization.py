#!/usr/bin/env python3
"""Validate the app-owned localization catalog and SwiftUI string usage."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"
LANGUAGES = ("en", "zh-Hans")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|u|f|\.\d+f)")
VISIBLE_LITERAL = re.compile(
    r'(?:Text|Button|Label|Picker|Section|LabeledContent|ContentUnavailableView|confirmationDialog|alert)'
    r'\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"'
    r'|\bvalue\s*:\s*"((?:[^"\\]|\\.)*)"'
)

VISIBLE_SWIFT_ROOTS = (
    ROOT / "App" / "Views",
    ROOT / "App" / "BrandUI.swift",
    ROOT / "App" / "NetworkClientApp.swift",
)
PRODUCTION_SWIFT_ROOTS = (
    ROOT / "App",
    ROOT / "SharedDomain",
    ROOT / "SharedServices",
    ROOT / "iOSAdapters",
    ROOT / "TunnelContract",
    ROOT / "NetworkPacketTunnel",
)
ALL_SWIFT_ROOTS = PRODUCTION_SWIFT_ROOTS + (
    ROOT / "Tests",
    ROOT / "UITests",
)


def swift_files(roots: tuple[Path, ...]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        elif root.exists():
            files.extend(root.rglob("*.swift"))
    return sorted(set(files))


def placeholders(value: str) -> Counter[str]:
    return Counter(PLACEHOLDER.findall(value.replace("%%", "")))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings: dict[str, dict] = catalog["strings"]
    missing: dict[str, list[str]] = {language: [] for language in LANGUAGES}
    empty: dict[str, list[str]] = {language: [] for language in LANGUAGES}
    unfinished: dict[str, list[str]] = {language: [] for language in LANGUAGES}
    mismatched_placeholders: list[str] = []

    for key, entry in strings.items():
        values: dict[str, str] = {}
        for language in LANGUAGES:
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit")
            if unit is None:
                missing[language].append(key)
                continue
            value = unit.get("value", "")
            values[language] = value
            if not value.strip():
                empty[language].append(key)
            if unit.get("state") != "translated":
                unfinished[language].append(key)
        if all(language in values for language in LANGUAGES):
            if placeholders(values["en"]) != placeholders(values["zh-Hans"]):
                mismatched_placeholders.append(key)

    all_swift = swift_files(ALL_SWIFT_ROOTS)
    source_text = "\n".join(path.read_text(encoding="utf-8") for path in all_swift)
    production_source_text = "\n".join(
        path.read_text(encoding="utf-8") for path in swift_files(PRODUCTION_SWIFT_ROOTS)
    )
    unused = sorted(key for key in strings if key not in source_text)

    missing_visible_literals: list[str] = []
    for path in swift_files(VISIBLE_SWIFT_ROOTS):
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for match in VISIBLE_LITERAL.finditer(line):
                literal = next(value for value in match.groups() if value is not None)
                # An intentionally empty navigation title has no user-visible prose.
                if not literal:
                    continue
                # A value made only from interpolation is service/runtime data, not client prose.
                if r"\(" in literal:
                    continue
                if literal not in strings:
                    missing_visible_literals.append(f"{path.relative_to(ROOT)}:{line_number}:{literal}")

    referenced_keys: set[str] = set()
    key_patterns = (
        re.compile(r'LocalizedStringKey\("([^"]+)"\)'),
        re.compile(r'\.localized\("([^"]+)"\)'),
        re.compile(r'AppLocalization\.string\("([^"]+)"'),
    )
    for pattern in key_patterns:
        referenced_keys.update(pattern.findall(production_source_text))
    l10n_key_source = (ROOT / "SharedDomain" / "LocalizedMessage.swift").read_text(
        encoding="utf-8"
    )
    referenced_keys.update(re.findall(
        r'static let \w+ = "([a-z][a-z0-9_.]*(?: %@| %lld)?)"',
        l10n_key_source,
    ))
    missing_referenced_keys = sorted(key for key in referenced_keys if key not in strings)

    unsafe_dynamic_patterns = {
        "Text(model.message": r"Text\(model\.message",
        "Text(model.configSource": r"Text\(model\.configSource",
        "Text(vpn.state.title": r"Text\(vpn\.state\.title\)",
        "raw order status": r"AppModel\.orderStatus\(",
    }
    unsafe_dynamic = sorted(
        name for name, pattern in unsafe_dynamic_patterns.items()
        if re.search(pattern, production_source_text)
    )

    report = {
        "totalKeys": len(strings),
        "missing": {language: len(values) for language, values in missing.items()},
        "empty": {language: len(values) for language, values in empty.items()},
        "unfinished": {language: len(values) for language, values in unfinished.items()},
        "placeholderMismatches": mismatched_placeholders,
        "missingVisibleLiterals": missing_visible_literals,
        "missingReferencedKeys": missing_referenced_keys,
        "unsafeDynamicLocalization": unsafe_dynamic,
        "unusedKeys": unused,
        "unusedKeyCount": len(unused),
    }
    failed = any(missing.values()) or any(empty.values()) or any(unfinished.values())
    failed = failed or bool(mismatched_placeholders or missing_visible_literals)
    failed = failed or bool(missing_referenced_keys or unsafe_dynamic)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"Localization keys: {report['totalKeys']}")
        for language in LANGUAGES:
            print(
                f"{language}: missing={report['missing'][language]} "
                f"empty={report['empty'][language]} unfinished={report['unfinished'][language]}"
            )
        print(f"Placeholder mismatches: {len(mismatched_placeholders)}")
        print(f"Visible literals outside catalog: {len(missing_visible_literals)}")
        print(f"Referenced keys outside catalog: {len(missing_referenced_keys)}")
        print(f"Unsafe dynamic localization patterns: {len(unsafe_dynamic)}")
        print(f"Literal keys not referenced by active Swift sources: {len(unused)}")
        for label, values in (
            ("placeholder", mismatched_placeholders),
            ("visible", missing_visible_literals),
            ("referenced", missing_referenced_keys),
            ("dynamic", unsafe_dynamic),
        ):
            for value in values:
                print(f"ERROR {label}: {value}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
