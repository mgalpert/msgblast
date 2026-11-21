#!/bin/bash
set -euo pipefail

version=${1:?Release version required}
build=${2:?Release build number required}
archive=${3:?Archive path required}
shift 3
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! $build =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected a three-part version and a positive build number" >&2
    exit 1
fi

signing=('CODE_SIGN_IDENTITY=Apple Development')
if [[ ${1:-} == --unsigned ]]; then
    signing=(CODE_SIGNING_ALLOWED=NO)
    shift
fi

xcodebuild -project msgblast.xcodeproj -scheme msgblastMobile \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$archive" DEVELOPMENT_TEAM=C4XLZBEPK8 CODE_SIGN_STYLE=Automatic \
    "${signing[@]}" MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build" "$@" archive

app="$archive/Products/Applications/msgblastMobile.app"
[[ $(plutil -extract CFBundleIdentifier raw "$app/Info.plist") == com.msgblast.ios ]]
[[ $(plutil -extract CFBundleShortVersionString raw "$app/Info.plist") == "$version" ]]
[[ $(plutil -extract CFBundleVersion raw "$app/Info.plist") == "$build" ]]
if [[ ${signing[0]} != CODE_SIGNING_ALLOWED=NO ]]; then
    codesign --verify --deep --strict "$app"
fi
if strings "$app/msgblastMobile" | grep -E 'MSGBLAST_FIXTURE|Studio Mac'; then
    echo "Release archive includes demo fixture strings" >&2
    exit 1
fi
test -f "$app/PrivacyInfo.xcprivacy"
test -f "$archive/dSYMs/msgblastMobile.app.dSYM/Contents/Resources/DWARF/msgblastMobile"
echo "Verified com.msgblast.ios $version ($build), privacy manifest, and app dSYM"
