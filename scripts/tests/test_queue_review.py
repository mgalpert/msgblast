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


if __name__ == '__main__':
    unittest.main()
