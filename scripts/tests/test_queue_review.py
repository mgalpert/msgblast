import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check_queue_review.py'
spec = importlib.util.spec_from_file_location('queue_review', SCRIPT)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
SHA = 'a' * 40


class QueueReviewTests(unittest.TestCase):
    def test_reads_the_pull_request_from_the_queue_branch(self):
        self.assertEqual(review.pull_number(f'refs/heads/gh-readonly-queue/main/pr-152-{SHA}'), 152)
        self.assertEqual(review.pull_number(f'gh-readonly-queue/main/pr-7-{SHA}'), 7)
        for ref in ['refs/heads/main', f'refs/heads/gh-readonly-queue/other/pr-7-{SHA}',
                    'refs/heads/gh-readonly-queue/main/pr-7-abc', f'refs/heads/feature/pr-7-{SHA}']:
            with self.assertRaises(ValueError):
                review.pull_number(ref)

    def test_the_newest_review_status_decides(self):
        ok = dict(context=review.CONTEXT, state='success', created_at='2026-11-15T10:00:00Z', id=1)
        self.assertTrue(review.reviewed([ok], 'h')[0])
        self.assertFalse(review.reviewed([], 'h')[0])
        self.assertFalse(review.reviewed([ok | dict(context='native')], 'h')[0])
        later_fail = ok | dict(state='failure', created_at='2026-11-15T11:00:00Z', id=2)
        self.assertFalse(review.reviewed([ok, later_fail], 'h')[0])
        self.assertTrue(review.reviewed([later_fail | dict(created_at='2026-11-15T09:00:00Z'), ok], 'h')[0])
        self.assertFalse(review.reviewed([ok | dict(state='pending')], 'h')[0])


    def test_every_pull_request_in_a_group_is_read(self):
        def merge(sha, parent, number):
            return dict(sha=sha, commit=dict(message=f'Merge pull request #{number} from x/y\n'),
                        parents=[dict(sha=parent), dict(sha='p' + sha)])
        commits = {c['sha']: c for c in [
            dict(sha='pa', commit=dict(message='Merge pull request #5 from x/y'), parents=[dict(sha='base')]),
            merge('a', 'base', 7), merge('b', 'a', 9),
            dict(sha='c', commit=dict(message='Merge pull request #11 from x/y'), parents=[dict(sha='b')]),
            dict(sha='d', commit=dict(message='Fix things'), parents=[dict(sha='b')])]}

        def group(base, head, limit=100):
            return review.group_pulls(commits.__getitem__, base, head, limit)
        self.assertEqual(group('base', 'b'), [7, 9])
        self.assertEqual(group('base', 'a'), [7])
        self.assertEqual(group('b', 'b'), [])
        for base, head in [('base', 'c'), ('base', 'd'), ('base', 'pa')]:
            with self.assertRaises(ValueError):
                group(base, head)
        with self.assertRaises(ValueError):
            group('base', 'b', limit=1)
        with self.assertRaises(KeyError):
            group('other', 'b')


if __name__ == '__main__':
    unittest.main()
