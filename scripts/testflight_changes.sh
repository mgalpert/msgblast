#!/bin/bash
set -euo pipefail

repository=${GITHUB_REPOSITORY:?Repository required}
baseline=${TESTFLIGHT_BASE_SHA:-}
head=${GITHUB_SHA:?Release revision required}
deployments=$(gh api --paginate "repos/$repository/deployments?environment=testflight&per_page=100" \
    --jq '.[] | [.id, .sha] | @tsv')
while IFS=$'\t' read -r id revision; do
    [[ -n $id ]] || continue
    success=$(gh api --paginate "repos/$repository/deployments/$id/statuses?per_page=100" \
        --jq '.[] | select(.state == "success") | .state')
    if [[ -n $success ]]; then
        baseline=$revision
        break
    fi
done <<< "$deployments"

if [[ ! $baseline =~ ^[a-f0-9]{40}$ ]] || ! git merge-base --is-ancestor "$baseline" "$head"; then
    echo "The last TestFlight source must be an ancestor of this release. For the first automated upload, set MSGBLAST_TESTFLIGHT_BASE_SHA." >&2
    exit 1
fi

# The generator owns shared build settings. The generated project also changes
# when a Mac-only source file is added, so it is not a separate input here.
paths=$(git diff --name-only "$baseline" "$head" -- \
    msgblastMobile/ msgblast/RemoteProtocol/ msgblast/AppIcon.icon/ \
    scripts/generate_project.py scripts/archive_testflight.sh scripts/ExportOptions-testflight.plist \
    msgblast.xcodeproj/xcshareddata/xcschemes/msgblastMobile.xcscheme)
echo "Comparing TestFlight source $baseline to $head"
if [[ -n $paths ]]; then
    printf 'iPhone release inputs changed:\n%s\n' "$paths"
    echo 'changed=true' >> "$GITHUB_OUTPUT"
else
    echo 'No iPhone release inputs changed.'
    echo 'changed=false' >> "$GITHUB_OUTPUT"
fi
