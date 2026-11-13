"""Guards against a SwiftUI accessibility crash seen on macOS 27.2.

A `Text` that is both selectable (`.textSelection(.enabled)`) and given its own
`.accessibilityLabel` recursed inside SwiftUI's label lookup when VoiceOver or any
accessibility client read the label, until the main thread ran out of stack (the
"Key <fingerprint>" text in Settings > Remote, fixed in #126). A UI test cannot
read that label without crashing the test host, so this check reads the source.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / 'msgblast', ROOT / 'msgblastMobile']


def modifier_chains(text):
    """Yields (line number, chain text) for each statement: a line plus the `.modifier`
    lines that continue it."""
    lines = text.splitlines()
    start, chain = 0, []
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith('.') and chain:
            chain.append(line)
            continue
        if chain:
            yield start, '\n'.join(chain)
        start, chain = number, [line]
    if chain:
        yield start, '\n'.join(chain)


def offenders(text):
    return [line for line, chain in modifier_chains(text)
            if re.search(r'\.textSelection\(\s*\.enabled\s*\)', chain) and '.accessibilityLabel(' in chain]


class SelectableTextLabelTests(unittest.TestCase):
    def test_detects_a_selectable_text_with_its_own_label(self):
        source = 'Text("Key").font(.caption).textSelection(.enabled)\n    .accessibilityLabel("Mac key")\n'
        self.assertEqual(offenders(source), [1])

    def test_allows_a_label_on_plain_text_and_selection_without_a_label(self):
        source = ('Text("Key").font(.caption)\n    .accessibilityLabel("Mac key")\n'
                  'Text(path).textSelection(.enabled)\nButton("Copy") {}\n    .accessibilityLabel("Copy")\n')
        self.assertEqual(offenders(source), [])

    def test_no_selectable_text_carries_its_own_accessibility_label(self):
        found = []
        for folder in SOURCES:
            for path in sorted(folder.rglob('*.swift')):
                found += [f'{path.relative_to(ROOT)}:{line}' for line in offenders(path.read_text())]
        self.assertEqual(found, [], 'Selectable Text with its own accessibilityLabel crashes VoiceOver; '
                                    'drop .textSelection or the label')


if __name__ == '__main__':
    unittest.main()
