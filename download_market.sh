#!/bin/bash
folder=$1

declare -A MAP=(
  [AUS200]=ausidxaud
  [DXY]=dollaridxusd
  [GER40]=deuidxeur
  [HK50]=hkgidxhkd
  [JP225]=jpnidxjpy
  [UK100]=gbridxgbp
  [US100]=usatechidxusd
  [US500]=usa500idxusd
  [USOIL]=lightcmdusd
  [XAUUSD]=xauusd
  [XCUUSD]=coppercmdusd
)
id=${MAP[$folder]}

START_YEAR=2018
END_YEAR=$(date +%Y)
TODAY=$(date +%Y-%m-%d)
if [ "$(date +%m)" = "01" ]; then REFRESH_FROM=$((END_YEAR-1)); else REFRESH_FROM=$END_YEAR; fi

mkdir -p out
existing=$(gh release view data --json assets -q '.assets[].name')

for year in $(seq $START_YEAR $END_YEAR); do
  from="$year-01-01"
  if [ "$year" -eq "$END_YEAR" ]; then to="$TODAY"; else to="$((year+1))-01-01"; fi

  for side in bid ask; do
    fname="${folder}_${year}_${side}"
    if [ "$year" -lt "$REFRESH_FROM" ] && echo "$existing" | grep -qx "$fname.csv"; then
      echo "SKIP: $fname.csv"
      continue
    fi

    ok=0
    for attempt in 1 2 3; do
      echo "Downloading $fname (attempt $attempt)"
      dukascopy-node -i "$id" -from "$from" -to "$to" -t m1 -p "$side" \
        -f csv -dir out -fn "$fname" -bs 10 -bp 1000 -r 5 > log.txt 2>&1
      if [ -f "out/$fname.csv" ]; then ok=1; break; fi
      tail -n 5 log.txt
      sleep 120
    done

    if [ $ok -eq 1 ]; then
      gh release upload data "out/$fname.csv" --clobber
      rm -f "out/$fname.csv"
      echo "DONE: $fname.csv"
    else
      echo "FAILED: $fname.csv"
    fi
  done
done
