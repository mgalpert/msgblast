import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_pr_scope.py'


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.commit('base')
        self.base = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True)

    def commit(self, name):
        self.git('add', '.')
        self.git('commit', '-qm', name, '--allow-empty')

    def check(self, lines, body='Scope: change.txt', approved=False):
        (self.root / 'change.txt').write_text('line\n' * lines)
        self.commit('change')
        event = self.root / '.git' / 'event.json'
        event.write_text(json.dumps({'pull_request': {'body': body}}))
        command = ['python3', str(SCRIPT), '--base', self.base, '--head', 'HEAD',
                   '--event-file', str(event)]
        if approved:
            command.append('--size-approved')
        return subprocess.run(command, cwd=self.root, text=True, capture_output=True)

    def test_soft_and_hard_boundaries(self):
        for count, status in [(250, 0), (251, 0), (600, 0), (601, 1)]:
            with self.subTest(count=count):
                result = self.check(count)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual('Advisory:' in result.stdout, count > 250)

    def test_missing_or_wrong_scope(self):
        for body in ['', 'Scope: other.txt']:
            self.assertEqual(self.check(1, body).returncode, 1)

    def test_exception_only_waives_size(self):
        self.assertEqual(self.check(601, approved=True).returncode, 0)
        self.assertEqual(self.check(601, 'Scope: other.txt', True).returncode, 1)

    def test_deletions_count(self):
        (self.root / 'change.txt').write_text('old\n' * 601)
        self.commit('large base')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.assertEqual(self.check(0).returncode, 1)

    def test_binary_reported(self):
        (self.root / 'image.bin').write_bytes(b'\0' * 123)
        result = self.check(1, 'Scope: change.txt\nScope: image.bin')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 binary', result.stdout)
        self.assertIn('128', result.stdout)


class ApprovalTests(unittest.TestCase):
    def test_only_current_human_write_approval_can_waive_size(self):
        spec = importlib.util.spec_from_file_location('scope', SCRIPT)
        scope = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scope)
        review = dict(id=1, state='APPROVED', commit_id='abc',
                      user=dict(login='reviewer', type='User'), body='Size-exception: abc')
        check = lambda reviews, permissions: scope.approved_review(reviews, 'abc', 'author', permissions)
        self.assertTrue(check([review], {'reviewer': 'write'}))
        self.assertFalse(check([review], {'reviewer': 'read'}))
        for replacement in [dict(commit_id='old'), dict(body='looks good'),
                            dict(user=dict(login='reviewer', type='Bot')),
                            dict(user=dict(login='author', type='User'))]:
            self.assertFalse(check([review | replacement], {'reviewer': 'write', 'author': 'admin'}))
        self.assertFalse(check([review, review | dict(id=2, state='DISMISSED')], {'reviewer': 'write'}))


if __name__ == '__main__':
    unittest.main()
