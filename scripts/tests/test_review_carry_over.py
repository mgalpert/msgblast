import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from review_carry_over import carried_over  # noqa: E402
import post_review_status  # noqa: E402
import check_pr_evidence  # noqa: E402


class Repo:
    def __init__(self, root):
        self.root = root
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def commit(self, name, files):
        for path, text in files.items():
            (self.root / path).write_text(text)
        self.git('add', '.')
        self.git('commit', '-qm', name)
        return self.git('rev-parse', 'HEAD')


class CarryOverTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = Repo(Path(temp.name))
        self.repo.commit('base', {'app.txt': 'one\ntwo\nthree\n', 'other.txt': 'a\n'})
        self.repo.git('checkout', '-qb', 'feature')
        self.reviewed = self.repo.commit('feature', {'app.txt': 'one\nTWO\nthree\n'})
        self.repo.git('checkout', '-q', 'main')
        self.main_change = self.repo.commit('main moves', {'other.txt': 'b\n'})
        self.repo.git('checkout', '-q', 'feature')

    def merge_main(self):
        self.repo.git('merge', '-q', '--no-edit', 'main')
        return self.repo.git('rev-parse', 'HEAD')

    def covered(self, head, reviewed=None):
        return carried_over(self.repo.root, reviewed or self.reviewed, head, 'main')

    def test_exact_head(self):
        self.assertTrue(self.covered(self.reviewed)[0])

    def test_clean_merge_of_main_carries_over(self):
        head = self.merge_main()
        covered, reason = self.covered(head)
        self.assertTrue(covered, reason)

    def test_two_clean_merges_carry_over(self):
        self.merge_main()
        self.repo.git('checkout', '-q', 'main')
        self.repo.commit('main again', {'third.txt': 'c\n'})
        self.repo.git('checkout', '-q', 'feature')
        self.assertTrue(self.covered(self.merge_main())[0])

    def test_new_commit_after_review_does_not(self):
        head = self.repo.commit('more work', {'app.txt': 'one\nTWO\n3\n'})
        self.assertFalse(self.covered(head)[0])

    def test_edit_hidden_in_merge_does_not(self):
        self.repo.git('merge', '-q', '--no-commit', 'main')
        (self.repo.root / 'app.txt').write_text('sneaky\n')
        self.repo.git('add', '.')
        self.repo.git('commit', '-qm', 'Merge main')
        self.assertFalse(self.covered(self.repo.git('rev-parse', 'HEAD'))[0])

    def test_merge_of_another_branch_does_not(self):
        self.repo.git('checkout', '-qb', 'side', 'main~1')
        self.repo.commit('side work', {'side.txt': 'x\n'})
        self.repo.git('checkout', '-q', 'feature')
        self.repo.git('merge', '-q', '--no-edit', 'side')
        self.assertFalse(self.covered(self.repo.git('rev-parse', 'HEAD'))[0])

    def test_octopus_merge_does_not(self):
        self.repo.git('checkout', '-qb', 'side', 'main')
        self.repo.commit('side', {'side.txt': 'x\n'})
        self.repo.git('checkout', '-q', 'feature')
        self.repo.git('merge', '-q', '--no-edit', 'main', 'side')
        self.assertFalse(self.covered(self.repo.git('rev-parse', 'HEAD'))[0])

    def test_branch_built_on_main_but_not_merged_does_not(self):
        self.repo.git('checkout', '-qb', 'ahead', 'main')
        self.repo.commit('not on main yet', {'ahead.txt': 'x\n'})
        self.repo.git('checkout', '-q', 'feature')
        self.repo.git('merge', '-q', '--no-edit', 'ahead')
        self.assertFalse(self.covered(self.repo.git('rev-parse', 'HEAD'))[0])

    def test_reviewed_only_as_second_parent_does_not(self):
        self.repo.git('checkout', '-qb', 'flipped', 'main')
        self.repo.git('merge', '-q', '--no-edit', 'feature')
        self.assertFalse(self.covered(self.repo.git('rev-parse', 'HEAD'))[0])

    def test_rewritten_history_does_not(self):
        self.repo.git('checkout', '-qb', 'rebased', 'main')
        head = self.repo.commit('feature again', {'app.txt': 'one\nTWO\nthree\n'})
        self.assertFalse(self.covered(head)[0])

    def test_evidence_check_accepts_carried_over_sha(self):
        head = self.merge_main()
        body = ('## Screenshots\n![s](https://example.com/s.png)\n\n'
                '## Video\nhttps://example.com/v.mp4\n\n'
                f'Evidence-SHA: {self.reviewed}\n')
        self.assertEqual(check_pr_evidence.problems(body, head, repo_dir=self.repo.root, base_ref='main'), [])
        extra = self.repo.commit('more', {'app.txt': 'changed\n'})
        self.assertEqual(len(check_pr_evidence.problems(body, extra, repo_dir=self.repo.root, base_ref='main')), 1)
        self.assertEqual(len(check_pr_evidence.problems(body, head)), 1)


def receipt(**overrides):
    value = {'pr': 7, 'reviewed_head': 'a' * 40, 'verdict': 'approve',
             'reviewer_model': 'Claude Sonnet 5.5', 'author_models': ['Claude Opus 5.5'],
             'findings': [{'severity': 'MINOR', 'text': 'naming'}]}
    value.update(overrides)
    return value


class ReceiptTests(unittest.TestCase):
    def test_valid_receipt(self):
        self.assertEqual(post_review_status.receipt_problems(receipt(), 7), [])

    def test_rejections(self):
        cases = {
            'wrong pr': receipt(pr=8),
            'short sha': receipt(reviewed_head='abc1234'),
            'not approved': receipt(verdict='changes requested'),
            'same model': receipt(reviewer_model='claude opus 5.5 '),
            'no authors': receipt(author_models=[]),
            'no reviewer': receipt(reviewer_model=''),
            'blocking finding': receipt(findings=[{'severity': 'major'}]),
            'not an object': [],
        }
        for name, value in cases.items():
            with self.subTest(name):
                self.assertTrue(post_review_status.receipt_problems(value, 7))

    def test_receipt_line(self):
        ref = post_review_status.receipt_reference
        self.assertEqual(ref('x\nReview-receipt: receipts:guardrail-receipts/pr-7-abc.json\n'),
                         ('receipts', 'guardrail-receipts/pr-7-abc.json'))
        self.assertIsNone(ref('Review-receipt: receipts:../secret.json'))
        self.assertIsNone(ref('Review-receipt: -upload:x.json'))
        self.assertIsNone(ref('`Review-receipt: receipts:x.json`'))
        self.assertIsNone(ref(''))


class DecideTests(unittest.TestCase):
    """End to end against a local "origin" holding main, the PR head and a receipt branch."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / 'origin').mkdir()
        self.origin = Repo(root / 'origin')
        self.origin.commit('base', {'app.txt': 'one\n'})
        self.origin.git('checkout', '-qb', 'feature')
        self.reviewed = self.origin.commit('feature', {'app.txt': 'two\n'})
        self.origin.git('checkout', '-q', 'main')
        self.origin.commit('main moves', {'other.txt': 'b\n'})
        self.origin.git('checkout', '-q', 'feature')
        self.origin.git('merge', '-q', '--no-edit', 'main')
        self.head = self.origin.git('rev-parse', 'HEAD')
        self.origin.git('checkout', '-q', '--orphan', 'receipts')
        self.origin.git('rm', '-rqf', '.')
        (self.origin.root / 'r').mkdir()
        self.write_receipt(receipt(reviewed_head=self.reviewed), switch=False)
        subprocess.check_call(['git', 'clone', '-q', str(self.origin.root), str(root / 'work')])
        self.work = root / 'work'

    def write_receipt(self, value, switch=True):
        if switch:
            self.origin.git('checkout', '-q', 'receipts')
        (self.origin.root / 'r' / 'pr-7.json').write_text(json.dumps(value))
        self.origin.git('add', '.')
        self.origin.git('commit', '-qm', 'receipt')
        self.origin.git('checkout', '-q', 'main')

    def event(self, head, body='Review-receipt: receipts:r/pr-7.json'):
        return {'pull_request': {'number': 7, 'body': body, 'head': {'sha': head}},
                'repository': {'full_name': 'owner/msgblast'}}

    def decide(self, head, **kwargs):
        subprocess.check_call(['git', 'fetch', '-q', 'origin', 'feature'], cwd=self.work)
        return post_review_status.decide(self.work, self.event(head, **kwargs), 'origin/main')

    def test_carry_over_posts_success(self):
        payload, why = self.decide(self.head)
        self.assertIsNotNone(payload, why)
        self.assertEqual(payload['state'], 'success')
        self.assertEqual(payload['context'], 'Independent model review')
        self.assertIn('carried over', payload['description'])
        self.assertTrue(payload['target_url'].startswith('https://raw.githubusercontent.com/owner/msgblast/'))
        self.assertLessEqual(len(payload['description']), 140)

    def test_exact_head_description(self):
        payload, why = self.decide(self.reviewed)
        self.assertEqual(payload['description'], 'Independent review of exact head: approve')

    def test_uncovered_head_posts_nothing(self):
        self.origin.git('checkout', '-q', 'feature')
        head = self.origin.commit('new work', {'app.txt': 'three\n'})
        self.origin.git('checkout', '-q', 'main')
        payload, why = self.decide(head)
        self.assertIsNone(payload)
        self.assertIn('does not cover', why)

    def test_invalid_receipt_posts_nothing(self):
        self.write_receipt(receipt(reviewed_head=self.reviewed, verdict='reject'))
        payload, why = self.decide(self.head)
        self.assertIsNone(payload)

    def test_missing_line_or_file_posts_nothing(self):
        self.assertIsNone(self.decide(self.head, body='no receipt')[0])
        self.assertIsNone(self.decide(self.head, body='Review-receipt: receipts:r/none.json')[0])
        self.assertIsNone(self.decide(self.head, body='Review-receipt: nobranch:r/pr-7.json')[0])


class PostingTests(unittest.TestCase):
    """main() with the GitHub API replaced: it must never replace an existing review status."""

    def run_main(self, existing):
        calls = []

        def fake_api(token, method, url, payload=None):
            calls.append((method, url, payload))
            return existing if method == 'GET' else {}

        payload = {'state': 'success', 'context': 'Independent model review', 'description': 'd', 'target_url': 'u'}
        event = {'pull_request': {'number': 7, 'head': {'sha': 'b' * 40}}, 'repository': {'full_name': 'o/r'}}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'event.json'
            path.write_text(json.dumps(event))
            with mock.patch.object(post_review_status, 'decide', return_value=(payload, 'ok')), \
                 mock.patch.object(post_review_status, 'api', side_effect=fake_api), \
                 mock.patch.dict('os.environ', {'GH_TOKEN': 't'}), \
                 mock.patch.object(sys, 'argv', ['x', '--event-file', str(path), '--base-ref', 'origin/main']):
                self.assertEqual(post_review_status.main(), 0)
        return [c for c in calls if c[0] == 'POST']

    def test_posts_when_head_has_no_review_status(self):
        posts = self.run_main([{'context': 'linux', 'state': 'success'}])
        self.assertEqual(len(posts), 1)
        self.assertTrue(posts[0][1].endswith('/statuses/' + 'b' * 40))

    def test_never_replaces_an_existing_review_status(self):
        for state in ['failure', 'error', 'pending', 'success']:
            with self.subTest(state):
                self.assertEqual(self.run_main([{'context': 'Independent model review', 'state': state}]), [])


class WorkflowTests(unittest.TestCase):
    def test_runs_trusted_base_code_and_only_posts_success(self):
        text = (SCRIPTS.parent / '.github/workflows/review-status.yml').read_text()
        self.assertIn('pull_request_target:', text)
        self.assertIn('ref: ${{ github.event.pull_request.base.sha }}', text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('statuses: write', text)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('pull_request_review', text)
        script = (SCRIPTS / 'post_review_status.py').read_text()
        self.assertNotIn('"failure"', script)
        self.assertNotIn('"pending"', script)
        self.assertNotIn('"error"', script)


if __name__ == '__main__':
    unittest.main()
