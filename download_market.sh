#!/bin/bash
# usage: download_market.sh SHARD NSHARDS
shard=${1:-0}; nshards=${2:-1}
BUDGET=${BUDGET:-19800}      # ~5.5 ghonta
MAX_NEW=${MAX_NEW:-6}        # prottek market theke ek run-e maximum notun file
END_YEAR=$(date -u +%Y)
TOMORROW=$(date -u -d tomorrow +%Y-%m-%d)
if [ "$(date -u +%m)" = "01" ]; then REFRESH_FROM=$((END_YEAR-1)); else REFRESH_FROM=$END_YEAR; fi
mkdir -p out prev
streak=0

# return: 0 ok, 1 error, 2 no data, 4 invalid instrument
fetch() {
  local name=$1 from=$2 to=$3 side=$4 attempt
  rm -f "out/$name.csv"
  for attempt in 1 2 3; do
    echo "  fetch $name $from -> $to (attempt $attempt)"
    dukascopy-node -i "$id" -from "$from" -to "$to" -t m1 -p "$side" -v true \
      -f csv -dir out -fn "$name" -bs 10 -bp 1000 -r 5 > log.txt 2>&1
    if [ -f "out/$name.csv" ]; then
      if [ "$(wc -l < "out/$name.csv")" -gt 1 ]; then return 0; fi
      rm -f "out/$name.csv"; return 2
    fi
    grep -q "Search config invalid" log.txt && return 4
    grep -q "went wrong" log.txt || return 2
    tail -n 3 log.txt; sleep 120
  done
  return 1
}

ensure_release() {
  [ "$REL_OK" = 1 ] && return
  gh release view "$TAG" >/dev/null 2>&1 || \
    gh release create "$TAG" --title "$market M1 data" --notes "Dukascopy M1 bid/ask + volume, UTC, gzip" >/dev/null
  REL_OK=1
}

publish() {
  ensure_release
  gzip -f "out/$1.csv" && gh release upload "$TAG" "out/$1.csv.gz" --clobber >/dev/null && rm -f "out/$1.csv.gz"
}

# shudhu notun data append. return: 0 updated, 3 up to date, 1 failed
update_tail() {
  local name=$1 side=$2 last fromday rc
  rm -f "prev/$name.csv" "prev/$name.csv.gz"
  gh release download "$TAG" -p "$name.csv.gz" -D prev --clobber >/dev/null 2>&1 || return 1
  gunzip -f "prev/$name.csv.gz" || return 1
  head -n 1 "prev/$name.csv" | grep -qi volume || return 1
  last=$(tail -n 1 "prev/$name.csv" | cut -d, -f1)
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  fromday=$(date -u -d "@$((last/1000))" +%Y-%m-%d)
  fetch "tail_$name" "$fromday" "$TOMORROW" "$side"; rc=$?
  [ $rc -eq 2 ] && { rm -f "prev/$name.csv"; return 3; }
  [ $rc -ne 0 ] && return 1
  awk -F, -v l="$last" 'NR>1 && ($1+0)>(l+0)' "out/tail_$name.csv" > "out/new_$name.csv"
  rm -f "out/tail_$name.csv"
  if [ ! -s "out/new_$name.csv" ]; then rm -f "out/new_$name.csv" "prev/$name.csv"; return 3; fi
  cat "prev/$name.csv" "out/new_$name.csv" > "out/$name.csv"
  rm -f "out/new_$name.csv" "prev/$name.csv"
  return 0
}

# return 9 = job thamao, otherwise next market
process_market() {
  market=$1
  id=$(jq -r --arg m "$market" '.[$m].id' markets.json)
  local start; start=$(jq -r --arg m "$market" '.[$m].start // 2003' markets.json)
  TAG="m1-$market"; REL_OK=0
  existing=$(gh release view "$TAG" --json assets -q '.assets[].name' 2>/dev/null)
  [ -n "$existing" ] && REL_OK=1
  echo "=== $market ($id) from $start ==="

  local a
  for a in $(echo "$existing" | grep '\.csv$'); do          # purano .csv -> .csv.gz
    rm -f "prev/$a" "prev/$a.gz"
    if gh release download "$TAG" -p "$a" -D prev --clobber >/dev/null 2>&1 \
       && gzip -f "prev/$a" && gh release upload "$TAG" "prev/$a.gz" --clobber >/dev/null 2>&1; then
      gh release delete-asset "$TAG" "$a" -y >/dev/null 2>&1; echo "MIGRATED: $a"
    fi
    rm -f "prev/$a" "prev/$a.gz"
  done
  existing=$(gh release view "$TAG" --json assets -q '.assets[].name' 2>/dev/null)

  local seen=0 empties=0 new=0 mfails=0 year side name has rc to
  for year in $(seq "$END_YEAR" -1 "$start"); do
    for side in bid ask; do
      if [ "$SECONDS" -gt "$BUDGET" ]; then echo "Time budget reached."; return 9; fi
      name="${market}_${year}_${side}"
      has=0; if echo "$existing" | grep -qx "$name.csv.gz"; then has=1; seen=1; fi
      if [ $has -eq 1 ] && [ "$year" -lt "$REFRESH_FROM" ]; then continue; fi

      if [ $has -eq 1 ]; then
        update_tail "$name" "$side"; rc=$?
        if [ $rc -eq 3 ]; then echo "UP TO DATE: $name"; continue; fi
        if [ $rc -eq 0 ] && publish "$name"; then echo "APPENDED: $name"; continue; fi
        echo "tail update failed, full refresh"
      fi

      if [ $new -ge "$MAX_NEW" ]; then echo "Per-market cap reached, next run continues."; return 0; fi
      if [ "$year" -eq "$END_YEAR" ]; then to=$TOMORROW; else to="$((year+1))-01-01"; fi
      fetch "$name" "$year-01-01" "$to" "$side"; rc=$?
      case $rc in
        0) publish "$name" && { echo "DONE: $name"; new=$((new+1)); seen=1; streak=0; }; sleep 3 ;;
        2) echo "NO DATA: $name"
           if [ $seen -eq 1 ] && [ "$year" -lt "$END_YEAR" ]; then echo "Reached start of history."; return 0; fi
           empties=$((empties+1))
           if [ $empties -ge 8 ]; then echo "No data found, skipping market."; return 0; fi ;;
        4) echo "INVALID instrument id: $id"; return 0 ;;
        *) echo "FAILED: $name"; mfails=$((mfails+1)); streak=$((streak+1))
           [ $streak -ge 4 ] && { echo "Repeated failures (rate limit?). Stopping job."; return 9; }
           [ $mfails -ge 2 ] && return 0 ;;
      esac
    done
  done
  return 0
}

mapfile -t LIST < <(jq -r 'to_entries[] | select(.value.on != false) | .key' markets.json)
i=0
for m in "${LIST[@]}"; do
  if [ $((i % nshards)) -eq "$shard" ]; then
    process_market "$m"; [ $? -eq 9 ] && break
  fi
  i=$((i+1))
done
echo "Shard $shard finished."
