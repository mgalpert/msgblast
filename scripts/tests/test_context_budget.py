from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_context_budget.py'
LEAN = SCRIPT.with_name('lean_run.py')


class ContextTests(unittest.TestCase):
    def test_instruction_limits_and_nested_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            for name, content, expected in [('AGENTS.md', 'a' * 6144, 0),
                                             ('AGENTS.md', 'a' * 6145, 1),
                                             ('nested/CLAUDE.md', 'é' * 3073, 1)]:
                (root / 'AGENTS.md').write_text('short')
                path = root / name
                path.parent.mkdir(exist_ok=True)
                path.write_text(content)
                subprocess.run(['git', 'add', '.'], cwd=root, check=True)
                tree = subprocess.check_output(['git', 'write-tree'], cwd=root, text=True).strip()
                result = subprocess.run(['python3', str(SCRIPT), '--head', tree], cwd=root, capture_output=True)
                self.assertEqual(result.returncode, expected, result.stdout)

    def check_tree(self, files, links=()):
        import os
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            for name, content in files.items():
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).write_text(content)
            for name, target in links:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                os.symlink(target, root / name)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            tree = subprocess.check_output(['git', 'write-tree'], cwd=root, text=True).strip()
            return subprocess.run(['python3', str(SCRIPT), '--head', tree], cwd=root, capture_output=True)

    def test_other_spellings_and_instruction_files_count(self):
        for name in ['agents.md', 'Claude.md', 'CLAUDE.local.md', 'GEMINI.md', '.cursorrules',
                     '.github/copilot-instructions.md', '.claude/rules/x.md', 'app/.cursor/rules/x.mdc']:
            with self.subTest(name=name):
                self.assertEqual(self.check_tree({name: 'a' * 6145}).returncode, 1)
        self.assertEqual(self.check_tree({'docs/notes.md': 'a' * 9000}).returncode, 0)

    def test_linked_rules_and_lfs_pointers_fail(self):
        result = self.check_tree({'docs/huge.md': 'a' * 9000}, [('.cursor/rules', '../docs')])
        self.assertEqual(result.returncode, 1, result.stdout)
        pointer = 'version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 99999\n'
        self.assertEqual(self.check_tree({'AGENTS.md': pointer}).returncode, 1)

    def test_aggregate_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            for number in range(5):
                folder = root / str(number)
                folder.mkdir()
                (folder / 'AGENTS.md').write_text('a' * 5000)
            subprocess.run(['git', 'add', '.'], cwd=root, check=True)
            tree = subprocess.check_output(['git', 'write-tree'], cwd=root, text=True).strip()
            result = subprocess.run(['python3', str(SCRIPT), '--head', tree], cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'aggregate', result.stdout)

    def test_console_cap_retains_full_log_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'run.log'
            result = subprocess.run(['python3', str(LEAN), '--log', str(log), '--',
                                     'python3', '-c', "import sys; print('x'*200000); sys.exit(7)"], capture_output=True)
            self.assertEqual(result.returncode, 7)
            self.assertLess(len(result.stdout), 103000)
            self.assertEqual(log.stat().st_size, 200001)
            self.assertIn(b'output truncated', result.stdout)

    def test_short_success_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['python3', str(LEAN), '--log', directory + '/run.log', '--',
                                     'python3', '-c', "print('ok')"], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'ok\n')


if __name__ == '__main__':
    unittest.main()
