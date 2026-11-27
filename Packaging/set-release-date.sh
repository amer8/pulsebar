#!/bin/sh
set -eu

version=$1
plist=$2
if [ "${RELEASE_DATE+x}" = x ]; then
    release_date=$RELEASE_DATE
else
    release_date=$(awk -v version="$version" '
        $1 == "##" && $2 == version && $3 == "-" {
            if (NF != 4) exit 1
            print $4
            exit
        }
    ' CHANGELOG.md) || { echo "Invalid changelog release heading" >&2; exit 1; }
fi

case "$release_date" in
    '') /usr/libexec/PlistBuddy -c "Delete :PulseBarReleaseDate" "$plist" >/dev/null 2>&1 || true ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        /usr/bin/plutil -replace PulseBarReleaseDate -string "$release_date" "$plist" ;;
    *) echo "Release date must use YYYY-MM-DD" >&2; exit 1 ;;
esac
