#!/bin/bash
# usage: download_market.sh SHARD NSHARDS
shard=${1:-0}; nshards=${2:-1}
BUDGET=${BUDGET:-10000}          # ~2.8 ghonta
MAX_NEW=${MAX_NEW:-8}            # prottek market theke ek round-e maximum notun file
DO_TAIL=${DO_TAIL:-true}         # current year-e shudhu notun data append
REPO=${GITHUB_REPOSITORY:?run inside GitHub Actions}
END_YEAR=$(date -u +%Y)
TOMORROW=$(date -u -d tomorrow +%Y-%m-%d)
if [ "$(date -u +%m)" = "01" ]; then REFRESH_FROM=$((END_YEAR-1)); else REFRESH_FROM=$END_YEAR; fi
mkdir -p out prev stage

LEVELS=("40 250" "20 500" "10 1000" "5 2000")
LEVEL=${START_LEVEL:-1}; OKSTREAK=0; streak=0; STAGED=0

# return: 0 ok, 1 error, 2 no data, 4 invalid instrument
fetch() {
  local name=$1 from=$2 to=$3 side=$4 attempt bs bp
  rm -f "out/$name.csv"
  for attempt in 1 2 3 4; do
    read -r bs bp <<< "${LEVELS[$LEVEL]}"
    echo "  fetch $name $from -> $to (try $attempt, bs=$bs bp=$bp)"
    dukascopy-node -i "$id" -from "$from" -to "$to" -t m1 -p "$side" -v true \
      -f csv -dir out -fn "$name" -bs "$bs" -bp "$bp" -r 5 > log.txt 2>&1
    if [ -f "out/$name.csv" ]; then
      OKSTREAK=$((OKSTREAK+1))
      if [ $OKSTREAK -ge 4 ] && [ $LEVEL -gt 0 ]; then LEVEL=$((LEVEL-1)); OKSTREAK=0; fi
      if [ "$(wc -l < "out/$name.csv")" -gt 1 ]; then return 0; fi
      rm -f "out/$name.csv"; return 2
    fi
    grep -q "Search config invalid" log.txt && return 4
    grep -q "went wrong" log.txt || return 2
    tail -n 2 log.txt
    if grep -qE "429|WAF" log.txt; then
      OKSTREAK=0; [ $LEVEL -lt 3 ] && LEVEL=$((LEVEL+1))
      sleep $((20*attempt))
    else
      sleep 15
    fi
  done
  return 1
}

load_existing() {
  local tries
  for tries in 1 2 3; do
    if existing=$(gh release view "$TAG" --json assets -q '.assets[].name' 2>err.txt); then return 0; fi
    if grep -qi "not found" err.txt; then existing=""; return 0; fi
    if grep -qi "rate limit" err.txt; then echo "GitHub API rate limit, 5 min opekkha..."; sleep 300; continue; fi
    sleep 10
  done
  return 1
}

ensure_release() {
  [ "$REL_OK" = 1 ] && return
  gh release view "$TAG" >/dev/null 2>&1 || \
    gh release create "$TAG" --title "$market M1 data" --notes "Dukascopy M1 bid/ask + volume, UTC, gzip" >/dev/null
  REL_OK=1
}

flush() {
  [ "$STAGED" -eq 0 ] && return 0
  ensure_release
  local k
  for k in 1 2 3; do
    if gh release upload "$TAG" stage/*.csv.gz --clobber >/dev/null 2>up.txt; then
      rm -f stage/*.csv.gz; STAGED=0; return 0
    fi
    tail -n 2 up.txt; sleep $((15*k))
  done
  echo "UPLOAD FAILED ($STAGED files), porer round-e abar hobe"
  rm -f stage/*.csv.gz; STAGED=0; return 1
}

publish() {
  gzip -f "out/$1.csv" && mv "out/$1.csv.gz" stage/ && STAGED=$((STAGED+1))
  [ $STAGED -ge 4 ] && flush
  return 0
}

# shudhu notun data append. return: 0 updated, 3 up to date, 1 failed
update_tail() {
  local name=$1 side=$2 last fromday rc
  rm -f "prev/$name.csv" "prev/$name.csv.gz"
  curl -fsSL "https://github.com/$REPO/releases/download/$TAG/$name.csv.gz" -o "prev/$name.csv.gz" || return 1
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
  load_existing || { echo "GitHub API problem, stopping job."; return 9; }
  [ -n "$existing" ] && REL_OK=1
  echo "=== $market ($id) from $start | L$LEVEL ==="

  local a                                                    # purano .csv -> .csv.gz
  for a in $(echo "$existing" | grep '\.csv$'); do
    rm -f "prev/$a" "prev/$a.gz"
    if curl -fsSL "https://github.com/$REPO/releases/download/$TAG/$a" -o "prev/$a" \
       && gzip -f "prev/$a" && gh release upload "$TAG" "prev/$a.gz" --clobber >/dev/null 2>&1; then
      gh release delete-asset "$TAG" "$a" -y >/dev/null 2>&1; echo "MIGRATED: $a"
      existing="$existing"$'\n'"$a.gz"
    fi
    rm -f "prev/$a" "prev/$a.gz"
  done

  local seen=0 empties=0 new=0 mfails=0 year side name has rc to T0
  for year in $(seq "$END_YEAR" -1 "$start"); do
    for side in bid ask; do
      if [ "$SECONDS" -gt "$BUDGET" ]; then echo "Time budget reached."; return 9; fi
      name="${market}_${year}_${side}"
      has=0; if echo "$existing" | grep -qx "$name.csv.gz"; then has=1; seen=1; fi
      if [ $has -eq 1 ] && { [ "$year" -lt "$REFRESH_FROM" ] || [ "$DO_TAIL" = "false" ]; }; then continue; fi

      if [ $has -eq 1 ]; then
        update_tail "$name" "$side"; rc=$?
        if [ $rc -eq 3 ]; then echo "UP TO DATE: $name"; continue; fi
        if [ $rc -eq 0 ] && publish "$name"; then echo "APPENDED: $name"; continue; fi
        echo "tail update failed, full refresh"
      fi

      if [ $new -ge "$MAX_NEW" ]; then echo "Per-market cap reached, next round continues."; return 0; fi
      if [ "$year" -eq "$END_YEAR" ]; then to=$TOMORROW; else to="$((year+1))-01-01"; fi
      T0=$SECONDS
      fetch "$name" "$year-01-01" "$to" "$side"; rc=$?
      case $rc in
        0) publish "$name"; echo "DONE: $name ($((SECONDS-T0))s, L$LEVEL)"; new=$((new+1)); seen=1; streak=0; sleep 1 ;;
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
    process_market "$m"; rc=$?
    flush
    [ $rc -eq 9 ] && break
  fi
  i=$((i+1))
done
echo "Shard $shard finished."
