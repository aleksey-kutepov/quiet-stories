#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
/bin/sh "$task_root/scripts/check-main.sh"
open -a Xcode "$task_root/Stories.xcodeproj"
