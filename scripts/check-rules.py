#!/usr/bin/env python3
"""Checks the project rules that can be read from the files themselves.

    python3 scripts/check-rules.py          check, exit 1 on a violation
    python3 scripts/check-rules.py --list   print the rules with their reason

A deliberate exception goes into the rule's EXCEPTIONS with a reason, in the same commit.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'
CORE = SOURCES / 'BackglowCore'
CATALOGS = sorted((ROOT / 'AppBundle/Localization').glob('*.xcstrings'))
FIRMWARE = ROOT / 'AppBundle/Firmware'

MAX_LINES = 500
# File → reason. Remove the entry once the file is split.
LONG_FILE_EXCEPTIONS = {
    'Sources/Backglow/BackglowApp.swift': 'all settings pages in one file; to be split by page',
    'Sources/Backglow/LightingModel.swift': 'model plus capture, output and auto-connect wiring; to be split',
}
CORE_IMPORTS = {'Foundation', 'CryptoKit'}
TRANSLATIONS = ('en',)

RULES = {
    'no-crash': 'No try!, as! or fatalError in the app: a bad settings file, port or frame must not crash it.',
    'no-print': 'No print() in Sources: a menu bar app has no console; show problems on the Diagnostics page.',
    'markers': 'TODO and FIXME only with an issue reference, e.g. TODO(#12), so open work is tracked somewhere.',
    'file-length': f'No source file over {MAX_LINES} lines (aim for about 400); exceptions listed with reason.',
    'core-imports': f'BackglowCore imports only {", ".join(sorted(CORE_IMPORTS))}: it stays pure and testable '
                    'without a display, GPU or serial port.',
    'no-network': 'The app does not talk to the network (README, privacy page): no URLSession, Network or '
                  'http(s) URLs in Sources.',
    'translations': 'Every string in the String Catalogs that is not stale is translated into English.',
    'firmware-images': 'Every file in AppBundle/Firmware/manifest.json exists and matches its SHA-256.',
}


def swift_files(folder=SOURCES):
    return sorted(folder.rglob('*.swift'))


def rel(path):
    return path.relative_to(ROOT).as_posix()


def code_lines(path):
    """Lines with comments and string literals blanked, so rules only see code."""
    text = path.read_text()
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    for number, line in enumerate(text.splitlines(), 1):
        line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        yield number, line.split('//', 1)[0]


def check_no_crash():
    for path in swift_files():
        for number, line in code_lines(path):
            if re.search(r'\btry!|\bas!|\bfatalError\(', line):
                yield f'{rel(path)}:{number}: {line.strip()}'


def check_no_print():
    for path in swift_files():
        for number, line in code_lines(path):
            if re.search(r'(?<![\w.])print\(', line):
                yield f'{rel(path)}:{number}: {line.strip()}'


def check_markers():
    for path in swift_files() + sorted((ROOT / 'Firmware/BackglowController/src').rglob('*.[ch]*')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for marker in re.finditer(r'\b(TODO|FIXME)\b(\((?:#\d+|[A-Z]+-\d+)\))?', line):
                if not marker.group(2):
                    yield f'{rel(path)}:{number}: {marker.group(1)} without issue reference'


def check_file_length():
    for path in swift_files():
        lines = len(path.read_text().splitlines())
        if lines > MAX_LINES and rel(path) not in LONG_FILE_EXCEPTIONS:
            yield f'{rel(path)}: {lines} lines'
    for name in LONG_FILE_EXCEPTIONS:
        path = ROOT / name
        if not path.exists() or len(path.read_text().splitlines()) <= MAX_LINES:
            yield f'{name}: listed as exception but no longer over {MAX_LINES} lines; remove the entry'


def check_core_imports():
    for path in swift_files(CORE):
        for number, line in code_lines(path):
            match = re.match(r'\s*(?:@\w+\s+)*import\s+(\w+)', line)
            if match and match.group(1) not in CORE_IMPORTS:
                yield f'{rel(path)}:{number}: import {match.group(1)}'


def check_no_network():
    for path in swift_files():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r'\bURLSession\b|\bimport Network\b|\bNWConnection\b|https?://', line):
                yield f'{rel(path)}:{number}: {line.strip()}'


def translated(entry):
    """True when a localization (string unit, plural or device variations) is fully translated."""
    if 'stringUnit' in entry:
        return entry['stringUnit'].get('state') == 'translated'
    variations = entry.get('variations', {})
    return bool(variations) and all(translated(case) for kind in variations.values() for case in kind.values())


def check_translations():
    for catalog in CATALOGS:
        strings = json.loads(catalog.read_text())['strings']
        for key, value in strings.items():
            if value.get('extractionState') == 'stale' or value.get('shouldTranslate') is False:
                continue
            for language in TRANSLATIONS:
                entry = value.get('localizations', {}).get(language)
                if not entry or not translated(entry):
                    yield f'{rel(catalog)}: {key!r} not translated into {language}'


def check_firmware_images():
    manifest_path = FIRMWARE / 'manifest.json'
    if not manifest_path.exists():
        return
    manifest = json.loads(manifest_path.read_text())
    listed = set()
    for image in manifest.get('images', []):
        for part in image.get('parts', []):
            path = FIRMWARE / part['file']
            listed.add(path)
            if not path.exists():
                yield f'{rel(path)}: listed in manifest.json but missing'
            elif hashlib.sha256(path.read_bytes()).hexdigest() != part['sha256']:
                yield f'{rel(path)}: SHA-256 differs from manifest.json; rebuild with scripts/build-firmware.sh'
    for path in sorted(FIRMWARE.rglob('*.bin')):
        if path not in listed:
            yield f'{rel(path)}: not listed in manifest.json'



CHECKS = {
    'no-crash': check_no_crash,
    'no-print': check_no_print,
    'markers': check_markers,
    'file-length': check_file_length,
    'core-imports': check_core_imports,
    'no-network': check_no_network,
    'translations': check_translations,
    'firmware-images': check_firmware_images,
}


def main():
    if '--list' in sys.argv:
        for name, reason in RULES.items():
            print(f'{name}: {reason}')
        for name, reason in LONG_FILE_EXCEPTIONS.items():
            print(f'  file-length exception {name}: {reason}')
        return 0
    failures = 0
    for name, check in CHECKS.items():
        for problem in check():
            print(f'[{name}] {problem}')
            failures += 1
    if failures:
        print(f'\n{failures} rule violation(s). Reasons: python3 scripts/check-rules.py --list', file=sys.stderr)
        return 1
    print(f'{len(CHECKS)} rules passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
