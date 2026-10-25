#!/bin/bash
# usage: download_market.sh MARKET
market=$1
id=$(jq -r --arg m "$market" '.[$m].id // empty' markets.json)
[ -z "$id" ] && { echo "Unknown market $market"; exit 1; }

TAG="m1-$market"
MIN_YEAR=${MIN_YEAR:-2003}
BUDGET=${BUDGET:-19800}            # ~5.5 ghonta por nijei thamibe
END_YEAR=$(date -u +%Y)
TOMORROW=$(date -u -d tomorrow +%Y-%m-%d)
if [ "$(date -u +%m)" = "01" ]; then REFRESH_FROM=$((END_YEAR-1)); else REFRESH_FROM=$END_YEAR; fi

mkdir -p out prev
gh release view "$TAG" >/dev/null 2>&1 || \
  gh release create "$TAG" --title "$market M1 data" --notes "Dukascopy M1 bid/ask with volume, UTC"
existing=$(gh release view "$TAG" --json assets -q '.assets[].name')

# return: 0 ok, 1 error, 2 no data
fetch() {
  local name=$1 from=$2 to=$3 side=$4
  rm -f "out/$name.csv"
  for attempt in 1 2 3; do
    echo "  fetch $name $from -> $to (attempt $attempt)"
    dukascopy-node -i "$id" -from "$from" -to "$to" -t m1 -p "$side" -v true \
      -f csv -dir out -fn "$name" -bs 10 -bp 1000 -r 5 > log.txt 2>&1
    if [ -f "out/$name.csv" ]; then
      [ "$(wc -l < "out/$name.csv")" -gt 1 ] && return 0
      rm -f "out/$name.csv"; return 2
    fi
    grep -q "went wrong" log.txt || return 2
    tail -n 3 log.txt
    sleep 120
  done
  return 1
}

# shudhu notun data append kore. return: 0 updated, 3 already up to date, 1 failed
update_tail() {
  local name=$1 side=$2 last fromday rc
  rm -f "prev/$name.csv"
  gh release download "$TAG" -p "$name.csv" -D prev --clobber >/dev/null 2>&1 || return 1
  head -n 1 "prev/$name.csv" | grep -qi volume || return 1
  last=$(tail -n 1 "prev/$name.csv" | cut -d, -f1)
  [[ "$last" =~ ^[0-9]+$ ]] || return 1
  fromday=$(date -u -d "@$((last/1000))" +%Y-%m-%d)
  fetch "tail_$name" "$fromday" "$TOMORROW" "$side"; rc=$?
  [ $rc -eq 2 ] && return 3
  [ $rc -ne 0 ] && return 1
  awk -F, -v l="$last" 'NR>1 && ($1+0)>(l+0)' "out/tail_$name.csv" > "out/new_$name.csv"
  rm -f "out/tail_$name.csv"
  if [ ! -s "out/new_$name.csv" ]; then rm -f "out/new_$name.csv"; return 3; fi
  cat "prev/$name.csv" "out/new_$name.csv" > "out/$name.csv"
  rm -f "out/new_$name.csv" "prev/$name.csv"
  return 0
}

fails=0
for year in $(seq "$END_YEAR" -1 "$MIN_YEAR"); do
  for side in bid ask; do
    if [ "$SECONDS" -gt "$BUDGET" ]; then
      echo "Time budget reached. Next run will continue from here."; exit 0
    fi
    name="${market}_${year}_${side}"
    has=0; echo "$existing" | grep -qx "$name.csv" && has=1

    if [ $has -eq 1 ] && [ "$year" -lt "$REFRESH_FROM" ]; then
      echo "SKIP: $name.csv"; continue
    fi

    if [ $has -eq 1 ]; then
      update_tail "$name" "$side"; rc=$?
      if [ $rc -eq 3 ]; then echo "UP TO DATE: $name.csv"; continue; fi
      if [ $rc -eq 0 ]; then
        gh release upload "$TAG" "out/$name.csv" --clobber && rm -f "out/$name.csv" && echo "APPENDED: $name.csv" && continue
      fi
      echo "tail update failed, full year refresh"
    fi

    if [ "$year" -eq "$END_YEAR" ]; then to=$TOMORROW; else to="$((year+1))-01-01"; fi
    fetch "$name" "$year-01-01" "$to" "$side"; rc=$?
    if [ $rc -eq 0 ]; then
      gh release upload "$TAG" "out/$name.csv" --clobber && rm -f "out/$name.csv" && echo "DONE: $name.csv"
      fails=0
    elif [ $rc -eq 2 ]; then
      echo "NO DATA: $name"
      [ "$year" -lt "$END_YEAR" ] && { echo "Reached start of $market history."; exit 0; }
    else
      echo "FAILED: $name"
      fails=$((fails+1))
      [ $fails -ge 2 ] && { echo "Repeated failures (rate limit?). Stopping, next run resumes."; exit 0; }
    fi
  done
done
