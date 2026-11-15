#!/usr/bin/env python3
"""Reject pull request descriptions that lack current, embedded visual evidence.

A human still has to confirm that the images and video show the change. This
script only checks structure: real remote embeds, no local paths or placeholder
copy, and an Evidence-SHA line for the commit under review.

A written explanation never satisfies the screenshot or video requirement.
When a change truly cannot be shown, a person reviews that explanation
separately. This check still fails until the description has a remote image
and a remote playable video. An empty or local <video> tag is not a video.
Syntax inside a code fence, an indented code block, an HTML comment, a pre or
code element, inline code, or an escape does not count, because GitHub does
not render it.
"""
import argparse
from pathlib import Path
import json
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from review_carry_over import carried_over  # noqa: E402


HEADING = re.compile(r"^## +(.+?)\s*$", re.MULTILINE)
IMAGE = re.compile(r"!\[[^\]]*\]\((https://[^)\s]+)\)|<img\b[^>]*\bsrc=[\"'](https://[^\"']+)[\"']", re.IGNORECASE)
REMOTE_URL = re.compile(r"https://[^\s\"'<>)\]]+", re.IGNORECASE)
PLAYABLE_VIDEO = re.compile(r"\.(?:mp4|webm|mov)(?:[?#]|$)", re.IGNORECASE)
USER_ATTACHMENT = "https://github.com/user-attachments/"
LOCAL = re.compile(r"/opt/cursor|file://|\.\./|src=[\"'][^\"']*(?:/workspace|/tmp/)", re.IGNORECASE)
PLACEHOLDER = re.compile(r"\b(?:placeholder|todo|lorem ipsum|screenshot of whatever)\b", re.IGNORECASE)
SHA = re.compile(r"Evidence-SHA:\s*([0-9a-f]{40})\b")
RUN_URL = re.compile(r"https://github\.com/[^\s)]+/actions/runs/\d+")
DEV_CHECKSUM = re.compile(r"(?m)^msgblast Dev SHA-256:\s*([0-9a-f]{64})\b")
DEMO_CHECKSUM = re.compile(r"(?m)^msgblast Demo SHA-256:\s*([0-9a-f]{64})\b")
HTML_COMMENT = re.compile(r"(?is)<!--.*?-->|<!--.*\Z")
CLOSED_FENCE = re.compile(r"(?ms)^[ ]{0,3}(?P<tick>`{3,}|~{3,})[^\n]*\n.*?^[ ]{0,3}(?P=tick)[ \t]*$")
OPEN_FENCE = re.compile(r"(?ms)^[ ]{0,3}(`{3,}|~{3,})[^\n]*\n.*\Z")
INLINE_CODE = re.compile(r"``+[^`\n]*``+|`[^`\n]*`")
ESCAPED_EMBED = re.compile(r"\\!\[[^\]]*\]\([^)\n]*\)|\\</?(?:img|video|source)\b[^>\n]*>", re.IGNORECASE)
HTML_PRE_CODE = re.compile(r"(?is)<pre\b[^>]*>.*?</pre>|<code\b[^>]*>.*?</code>")
INDENTED_CODE = re.compile(r"(?m)^(?: {4}|\t)+.*(?:\n|$)")


def section(body, title):
    matches = list(HEADING.finditer(body))
    for index, match in enumerate(matches):
        if match.group(1).strip().lower() != title.lower():
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        return body[match.end():end]
    return ""


def rendered_text(text):
    """Keep only description text GitHub can render as an embed."""
    if not text:
        return ""
    text = HTML_COMMENT.sub(" ", text)
    text = HTML_PRE_CODE.sub(" ", text)
    text = CLOSED_FENCE.sub("\n", text)
    text = OPEN_FENCE.sub("\n", text)
    text = INDENTED_CODE.sub("\n", text)
    text = INLINE_CODE.sub(" ", text)
    text = ESCAPED_EMBED.sub(" ", text)
    return text


def playable_video(text):
    for match in REMOTE_URL.finditer(rendered_text(text)):
        url = match.group(0)
        if url.lower().startswith(USER_ATTACHMENT) or PLAYABLE_VIDEO.search(url):
            return True
    return False


def problems(body, head_sha, require_preview=False, repo_dir=None, base_ref=None):
    errors = []
    if not isinstance(body, str) or not body.strip():
        return ["Pull request description is empty."]
    screenshots = section(body, "Screenshots")
    video = section(body, "Video")
    visible_screenshots = rendered_text(screenshots)
    visible_video = rendered_text(video)
    if not screenshots.strip():
        errors.append("Missing a Screenshots section.")
    elif not IMAGE.search(visible_screenshots):
        errors.append("Screenshots section needs an embedded https image, not only text.")
    if not video.strip():
        errors.append("Missing a Video section.")
    elif not playable_video(video):
        errors.append("Video section needs a remote playable https video (.mp4, .webm, .mov, or github.com/user-attachments), not an empty or local video tag.")
    for name, text in (("Screenshots", visible_screenshots), ("Video", visible_video)):
        if LOCAL.search(text):
            errors.append(f"{name} section contains a local-only path.")
        if PLACEHOLDER.search(text):
            errors.append(f"{name} section still contains placeholder wording.")
    found = SHA.search(body)
    if not found:
        errors.append("Description must contain 'Evidence-SHA: <40-character commit>'.")
    elif head_sha and found.group(1) != head_sha:
        covered, reason = (False, "no base branch to compare with")
        if repo_dir and base_ref:
            covered, reason = carried_over(repo_dir, found.group(1), head_sha, base_ref)
        if covered:
            print(f"Evidence of {found.group(1)[:7]} carries over to {head_sha[:7]}: {reason}.")
        else:
            errors.append(f"Evidence-SHA {found.group(1)} does not match the reviewed commit {head_sha} ({reason}).")
    if require_preview:
        if "msgblast Dev" not in body or "msgblast Demo" not in body:
            errors.append("Cursor branch previews must name both msgblast Dev and msgblast Demo.")
        if "fixture" not in body.lower():
            errors.append("The demo download must be labeled as a fixture.")
        if not RUN_URL.search(body):
            errors.append("Description needs the Actions run URL for the preview artifacts.")
        dev_checksum = DEV_CHECKSUM.search(body)
        demo_checksum = DEMO_CHECKSUM.search(body)
        if not dev_checksum:
            errors.append("Description needs a line 'msgblast Dev SHA-256: <64 hex>'.")
        if not demo_checksum:
            errors.append("Description needs a line 'msgblast Demo SHA-256: <64 hex>'.")
        if dev_checksum and demo_checksum and dev_checksum.group(1) == demo_checksum.group(1):
            errors.append("msgblast Dev SHA-256 and msgblast Demo SHA-256 must be different.")
        if re.search(r"updates\.msgblast\.app/(?:latest\.zip|downloads/)", body):
            errors.append("Preview downloads must stay on Actions artifacts, not the production update host.")
    return errors


def body_from_event(path):
    event = json.loads(Path(path).read_text())
    pull_request = event.get("pull_request") or {}
    return pull_request.get("body") or ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body-file")
    parser.add_argument("--event-file")
    parser.add_argument("--head", required=True)
    parser.add_argument("--require-preview", action="store_true")
    parser.add_argument("--repo-dir", default=".")
    parser.add_argument("--base-ref", help="Accept evidence of an earlier commit when the head only adds clean merges of this ref")
    args = parser.parse_args()
    if args.event_file:
        body = body_from_event(args.event_file)
    elif args.body_file:
        body = Path(args.body_file).read_text()
    else:
        parser.error("Provide --body-file or --event-file")
    errors = problems(body, args.head, require_preview=args.require_preview,
                      repo_dir=args.repo_dir, base_ref=args.base_ref)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Pull request evidence structure matches", args.head)
    print("A human still has to confirm the images and video show this change.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
