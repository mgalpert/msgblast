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


def code_only(line):
    """The line without a trailing `//` comment or the contents of string literals."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    return line.split('//', 1)[0]


def modifier_chains(text):
    """Yields (line number, chain text) for each statement: a line plus everything that
    continues it, meaning `.modifier` lines, lines inside a closure or argument list that a
    modifier opened, and blank or comment lines between them. Comments and strings are dropped."""
    start, chain, depth = 0, [], 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = code_only(raw)
        stripped = line.strip()
        continues = chain and (depth > 0 or stripped.startswith('.') or not stripped)
        if not continues:
            if chain:
                yield start, '\n'.join(chain)
            start, chain, depth = number, [], 0
        chain.append(line)
        if continues or len(chain) > 1 or stripped.startswith('.'):
            # Only a modifier's own closures and argument lists hold the chain open, not the
            # braces of the type or function the statement sits in.
            depth = max(0, depth + line.count('{') + line.count('(') - line.count('}') - line.count(')'))
    if chain:
        yield start, '\n'.join(chain)


def offenders(text):
    return [line for line, chain in modifier_chains(text)
            if re.search(r'\.textSelection\(\s*\.enabled\s*\)', chain) and '.accessibilityLabel(' in chain]


class SelectableTextLabelTests(unittest.TestCase):
    def test_detects_a_selectable_text_with_its_own_label(self):
        source = 'Text("Key").font(.caption).textSelection(.enabled)\n    .accessibilityLabel("Mac key")\n'
        self.assertEqual(offenders(source), [1])

    def test_follows_the_chain_across_closures_comments_and_blank_lines(self):
        source = ('Text(prompt)\n    .textSelection(.enabled)\n    .overlay {\n        Color.clear\n    }\n\n'
                  '    // spoken name\n    .accessibilityLabel("Prompt")\n')
        self.assertEqual(offenders(source), [1])

    def test_ignores_the_pattern_inside_comments_and_strings(self):
        source = ('Text("Key").textSelection(.enabled) // not .accessibilityLabel(\n'
                  'Text(".accessibilityLabel(").textSelection(.enabled)\n')
        self.assertEqual(offenders(source), [])

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
