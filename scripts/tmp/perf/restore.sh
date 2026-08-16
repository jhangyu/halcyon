#!/bin/bash
# Revert the temporary perf instrumentation.
# Restores ONLY the five tracked files this harness modified, by writing back
# their committed content from 7c33194 (no git checkout/reset/stash/clean).
cd /Users/jhangyu/project/Halcyon || exit 1
BASE=7c33194

FILES="lib/main.dart lib/providers/app_state.dart lib/services/image_preload_controller.dart lib/views/main_detail_view.dart macos/Runner/AppDelegate.swift"

# Archive the temporary harness sources (untracked, created by this task).
rm -rf tmp/verify/perf/lib_perf_backup
mkdir -p tmp/verify/perf/harness
cp lib/perf/*.dart tmp/verify/perf/harness/ 2>/dev/null

for f in $FILES; do
  git show "$BASE:$f" > "$f" || echo "FAILED restoring $f"
  echo "restored $f"
done

rm -rf lib/perf
echo "removed lib/perf/"

# Datasets copied into the app sandbox container (~230MB) are scratch too.
rm -rf "$HOME/Library/Containers/com.jhangyu.halcyon/Data/perf"
echo "removed sandbox container datasets"

echo "=== git status (tracked) ==="
git status --porcelain --untracked-files=no
