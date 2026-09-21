#!/bin/bash
# measure.sh <aot-file> <runs-per-proc> <procs>  -> prints "median min n"
AOT="$1"; RPP="$2"; PROCS="$3"; DEMO=/home/gem/project/perry_wasm_demo
TMP=$(mktemp)
for ((p=0;p<PROCS;p++)); do
  "$DEMO/build/aot_time" "$AOT" "$RPP" 2>/dev/null | grep -E '^RUN ' | awk '{print $3}' >> "$TMP"
done
n=$(wc -l < "$TMP")
if [ "$n" -eq 0 ]; then echo "NA NA 0"; rm -f "$TMP"; exit 0; fi
S=$(sort -n "$TMP")
med=$(echo "$S" | awk -v n="$n" 'NR==int((n+1)/2){print; exit}')
mn=$(echo "$S" | awk 'NR==1{print; exit}')
printf "%s %s %s\n" "$med" "$mn" "$n"
rm -f "$TMP"
