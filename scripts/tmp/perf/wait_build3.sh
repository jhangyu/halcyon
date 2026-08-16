#!/bin/bash
PID="$1"
while ps -p "$PID" > /dev/null 2>&1; do sleep 5; done
echo "BUILD_PROCESS_DONE pid=$PID"
tail -20 /Users/jhangyu/project/Halcyon/tmp/verify/r2/build_profile3.log
