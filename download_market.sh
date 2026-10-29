#!/bin/bash
# usage: download_market.sh SHARD NSHARDS
shard=${1:-0}; nshards=${2:-1}
BUDGET=${BUDGET:-7200}
MAX_NEW=${MAX_NEW:-8}
DO_TAIL=${DO_TAIL:-false}
REPO=${GITHUB_REPOSITORY:?run inside GitHub Actions}
END_YEAR=$(date -u +%Y)
TOMORROW=$(date -u -d tomorrow +%Y-%m-%d)
if [ "$(date -u +%m)" = "01" ]; then REFRESH_FROM=$((END_YEAR-1)); else REFRESH_FROM=$END_YEAR; fi
mkdir -p out prev stage
FRESH_AFTER=$(date -u -d '6 days ago' +%Y-%m-%d)

LEVELS=("40 250" "20 500" "10 1000" "5 2000")
LEVEL=${START_LEVEL:-2}; FASTEST=${FASTEST:-$LEVEL}; OKSTREAK=0; streak=0; STAGED=0

# public index (API limit lage na)
ok=0
for t in 1 2 3; do
  if curl -fsSL "https://github.com/$REPO/releases/download/meta/index.json" -o index.json 2>/dev/null && jq -e . index.json >/dev/null 2>&1; then ok=1; break; fi
  sleep 10
done
if [ $ok -eq 0 ]; then
  if gh release view meta >/dev/null 2>&1; then echo "index.json load hoyni, stopping (porer round-e abar hobe)"; exit 1; fi
  echo '{"m":{},"done":[]}' > index.json
fi
mapfile -t DONE_LIST < <(jq -r '.done[]?' index.json)
is_done() { printf '%s\n' "${DONE_LIST[@]}" | grep -qx "$1"; }

load_existing() {
  existing=$(jq -r --arg m "$market" '(.m[$m] // empty) as $d | range(0; ($d.y|length)) as $i | (if $d.b[$i] > 0 then "\($m)_\($d.y[$i])_bid.csv.gz" else empty end), (if $d.a[$i] > 0 then "\($m)_\($d.y[$i])_ask.csv.gz" else empty end)' index.json)
}

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
      if [ $OKSTREAK -ge 4 ] && [ $LEVEL -gt $FASTEST ]; then LEVEL=$((LEVEL-1)); OKSTREAK=0; fi
      if [ "$(wc -l < "out/$name.csv")" -gt 1 ]; then return 0; fi
      rm -f "out/$name.csv"; return 2
    fi
    grep -q "Search config invalid" log.txt && return 4
    grep -q "went wrong" log.txt || return 2
    tail -n 2 log.txt
    if grep -qE "status 429|Too Many Requests|WAF" log.txt; then
      OKSTREAK=0; [ $LEVEL -lt 3 ] && LEVEL=$((LEVEL+1))
      sleep $((20*attempt))
    else
      sleep 15
    fi
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

mark_done() {
  [ "$isdone" = 1 ] && return 0
  flush || return 0
  printf ok > prev/_complete.txt
  ensure_release
  gh release upload "$TAG" prev/_complete.txt --clobber >/dev/null 2>&1 && echo "MARKED COMPLETE: $market"
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
  isdone=0; is_done "$market" && isdone=1
  tail_this=$DO_TAIL
  if [ "$DO_TAIL" = "true" ]; then
    curu=$(jq -r --arg m "$market" --argjson y "$END_YEAR" '(.m[$m] // empty) | . as $d | ($d.y | index($y)) as $i | if $i == null then "" else $d.u[$i] end' index.json)
    if [ -n "$curu" ] && [[ "$curu" > "$FRESH_AFTER" ]]; then tail_this=false; fi
  fi
  if [ $isdone -eq 1 ] && [ "$tail_this" != "true" ]; then return 0; fi
  load_existing
  [ -n "$existing" ] && REL_OK=1
  local lowest=$start
  if [ $isdone -eq 1 ] && [ "$REFRESH_FROM" -gt "$start" ]; then lowest=$REFRESH_FROM; fi
  echo "=== $market ($id) from $lowest | L$LEVEL ==="

  local seen=0 empties=0 new=0 mfails=0 failed=0 year side name has rc to T0
  for year in $(seq "$END_YEAR" -1 "$lowest"); do
    for side in bid ask; do
      if [ "$SECONDS" -gt "$BUDGET" ]; then echo "Time budget reached."; return 9; fi
      name="${market}_${year}_${side}"
      has=0; if echo "$existing" | grep -qx "$name.csv.gz"; then has=1; seen=1; fi
      if [ $has -eq 1 ] && { [ "$year" -lt "$REFRESH_FROM" ] || [ "$tail_this" != "true" ]; }; then continue; fi

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
        2) echo "NO DATA: $name"; tail -n 3 log.txt
           if [ $seen -eq 1 ] && [ "$year" -lt "$END_YEAR" ]; then echo "Reached start of history."; [ $failed -eq 0 ] && mark_done; return 0; fi
           empties=$((empties+1))
           if [ $empties -ge 8 ]; then echo "No data found, skipping market."; [ $failed -eq 0 ] && mark_done; return 0; fi ;;
        4) echo "INVALID instrument id: $id"; mark_done; return 0 ;;
        *) echo "FAILED: $name"; failed=1; mfails=$((mfails+1)); streak=$((streak+1))
           [ $streak -ge 4 ] && { echo "Repeated failures (block?). Stopping job."; return 9; }
           [ $mfails -ge 2 ] && return 0 ;;
      esac
    done
  done
  [ $failed -eq 0 ] && mark_done
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
