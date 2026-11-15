#!/usr/bin/env bash
# One run: if an Arm VM exists, stop. If not, try 3 sizes in order (OCPU:GB), and
# repeat that sequence ROUNDS times, so every size gets ROUNDS real tries.
# A "slow down" (429) reply does NOT count as a try: we wait, then retry the SAME size.
# Env: C AD SUBNET IMAGE SSH_PUB. Optional: GAP seconds between tries (60),
#      ROUNDS (3), BUDGET seconds before we stop politely (1020), MAXBO (6) slow-down waits per try.
# Writes result=created|exists|retry|fatal|error (plus id=, shape=) to $GITHUB_OUTPUT
# and a readable report to the run's Summary page ($GITHUB_STEP_SUMMARY).
#   created/exists = done   retry = no capacity, try next run
#   fatal = bad config/auth, stop   error = unknown, read the log
set -u
OUT=${GITHUB_OUTPUT:-/dev/stdout}
SUM=${GITHUB_STEP_SUMMARY:-/dev/null}
NAME=forever-free
GAP=${GAP:-60}   # Oracle answered 429 when tries were 25s apart, so stay well above that
ROUNDS=${ROUNDS:-3}
BUDGET=${BUDGET:-1020}
MAXBO=${MAXBO:-6}
OCI=${OCI:-oci} # overridable for tests
SHAPES=(2:12 1:12 1:6) # biggest first; a smaller one is more likely to find room
MSG=$(mktemp)  # last short message from Oracle (written inside subshells)
TABLE=$(mktemp) # one row per try, shown on the Summary page
tried=0; unknowns=0; ncap=0; nrate=0

log() { echo "[$(date -u +%H:%M:%S) UTC] $*" >&2; }

short() { # error file -> one readable line
  local s
  s=$(sed -n '/^{/,$p' "$1" | jq -r '"HTTP \(.status) \(.code): \(.message // "no message")"' 2>/dev/null)
  [ -n "$s" ] && echo "$s" || head -c 200 "$1" | tr '\n' ' '
}

classify() { # stdin = error text -> retry | backoff | fatal | unknown
  local t; t=$(cat)
  case "$t" in
    *"Out of host capacity"*|*OutOfHostCapacity*|*"Out of capacity"*) echo retry ;;
    *'"status": 429'*|*TooManyRequests*) echo backoff ;;
    *LimitExceeded*|*NotAuthenticated*|*NotAuthorizedOrNotFound*|*InvalidParameter*|\
    *'"status": 400'*|*'"status": 401'*|*'"status": 403'*|*'"status": 404'*|\
    *ConfigFileNotFound*|*InvalidConfig*|*"key_file"*|*"Could not find config"*) echo fatal ;;
    *'"status": 5'*|*"imed out"*|*"Connection"*|*"Max retries"*|*"Temporary failure"*) echo retry ;;
    *) echo unknown ;;
  esac
}

finish() { # $1=result code  $2=headline
  echo "result=$1" >> "$OUT"
  {
    echo "### $2"; echo
    echo "| Tries | No capacity | Rate-limited | Result code |"
    echo "|---|---|---|---|"
    echo "| $tried | $ncap | $nrate | \`$1\` |"; echo
    if [ -s "$TABLE" ]; then
      echo "| Time (UTC) | Size | Outcome |"; echo "|---|---|---|"; cat "$TABLE"
    fi
  } >> "$SUM"
  log "========================================"
  log "$2"
  log "tries: $tried | no capacity: $ncap | rate-limited: $nrate | result: $1"
  log "========================================"
  exit 0
}

launch() { # $1=ocpus $2=GB -> prints created | retry | backoff | fatal | unknown
  local err res k; err=$(mktemp); res=$(mktemp)
  if $OCI --no-retry compute instance launch -c "$C" --availability-domain "$AD" \
      --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$1,\"memoryInGBs\":$2}" \
      --subnet-id "$SUBNET" --image-id "$IMAGE" --display-name "$NAME" \
      --assign-public-ip true --boot-volume-size-in-gbs 150 \
      --ssh-authorized-keys-file <(echo "$SSH_PUB") >"$res" 2>"$err"; then
    echo "id=$(jq -r '.data.id // empty' "$res" 2>/dev/null)" >> "$OUT"
    echo "shape=$1 OCPU / $2 GB" >> "$OUT"
    echo "$1 OCPU / $2 GB" > "$MSG"
    echo created
  else
    short "$err" > "$MSG"
    k=$(classify <"$err")
    # full raw error only when it is something unexpected, folded away in the log
    if [ "$k" = fatal ] || [ "$k" = unknown ]; then
      { echo "::group::raw Oracle error"; cat "$err"; echo "::endgroup::"; } >&2
    fi
    echo "$k"
  fi
}

check_exists() { # prints exists | none | retry | fatal | error. Logs what it found.
  local err j n k; err=$(mktemp)
  # any Arm (A1) VM that is not being deleted, whatever its name
  if ! j=$($OCI --no-retry compute instance list -c "$C" --all \
      --query 'data[?shape==`VM.Standard.A1.Flex` && "lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].{name:"display-name",state:"lifecycle-state",id:id}' \
      2>"$err"); then
    short "$err" > "$MSG"
    k=$(classify <"$err")
    if [ "$k" = fatal ] || [ "$k" = unknown ]; then
      { echo "::group::raw Oracle error"; cat "$err"; echo "::endgroup::"; } >&2
    fi
    case "$k" in fatal) echo fatal ;; unknown) echo error ;; *) echo retry ;; esac
    return
  fi
  n=$(echo "${j:-[]}" | jq 'length' 2>/dev/null || echo 0)
  if [ "${n:-0}" != 0 ]; then
    echo "$j" | jq -r '.[] | "  - \(.name) [\(.state)] \(.id)"' >&2
    echo "$j" | jq -r '.[0] | "\(.name) [\(.state)]"' > "$MSG"
    echo "id=$(echo "$j" | jq -r '.[0].id')" >> "$OUT"
    echo exists
  else
    echo none
  fi
}

out_of_time() { [ "$SECONDS" -ge "$BUDGET" ]; }

log "START: claiming Oracle Always Free VM '$NAME'"
log "plan: sizes ${SHAPES[*]} (OCPU:GB) x $ROUNDS rounds, ${GAP}s apart, stop after ${BUDGET}s"
sleep $((RANDOM % (GAP / 3 + 1))) # spread load, avoid the top-of-the-minute rush

nshapes=${#SHAPES[@]}; stopped_early=0
for round in $(seq "$ROUNDS"); do
  out_of_time && { stopped_early=1; break; }
  # 1) Already there? Then skip.
  log "round $round/$ROUNDS: CHECK - is an Arm (A1) VM already in this account?"
  c=$(check_exists)
  case "$c" in
    exists) log "CHECK RESULT: VM exists -> skipping the claim."
            echo "| $(date -u +%H:%M:%S) | check | ✅ VM exists: $(cat "$MSG") |" >> "$TABLE"
            finish exists "✅ VM already exists ($(cat "$MSG")). Skipped the claim. Workflow will switch itself off." ;;
    fatal)  finish fatal "❌ STOPPED: Oracle rejected the request: $(cat "$MSG")" ;;
    error)  unknowns=$((unknowns + 1)); tried=$((tried + 1)); log "check failed: $(cat "$MSG")"; sleep "$GAP"; continue ;;
    retry)  tried=$((tried + 1)); log "check failed, will retry: $(cat "$MSG")"; sleep "$GAP"; continue ;;
  esac
  log "CHECK RESULT: no A1 VM found -> starting the claim."
  echo "| $(date -u +%H:%M:%S) | check | none found, claiming |" >> "$TABLE"
  # 2) Not there: one real try for each size.
  i=0
  for s in "${SHAPES[@]}"; do
    i=$((i + 1)); o=${s%%:*}; g=${s##*:}; bo=0
    while :; do # repeat the SAME size until Oracle gives a real answer
      out_of_time && { stopped_early=1; break 3; }
      log "size $i/$nshapes: $o OCPU / $g GB, try $round of $ROUNDS..."
      r=$(launch "$o" "$g"); t=$(date -u +%H:%M:%S)
      case "$r" in
        created)
          tried=$((tried + 1)); log "✅ CREATED: $(cat "$MSG")"
          echo "| $t | $o OCPU / $g GB | ✅ created |" >> "$TABLE"
          finish created "✅ SUCCESS: VM created ($(cat "$MSG")). Check your email and the Oracle console." ;;
        fatal)
          echo "| $t | $o OCPU / $g GB | ❌ rejected |" >> "$TABLE"
          finish fatal "❌ STOPPED: Oracle rejected the request: $(cat "$MSG")" ;;
        backoff)
          nrate=$((nrate + 1)); bo=$((bo + 1))
          echo "| $t | $o OCPU / $g GB | 🚦 slow down ($bo) |" >> "$TABLE"
          if [ "$bo" -ge "$MAXBO" ]; then
            log "🚦 $bo slow-down replies in a row. Giving up on this try, moving on."; break
          fi
          w=$((GAP * 2 * bo)); [ "$w" -gt 300 ] && w=300; w=$((w + RANDOM % (GAP / 2 + 1)))
          log "🚦 Oracle says slow down ($(cat "$MSG")). Waiting ${w}s, then the SAME size again ($bo/$MAXBO)."
          sleep "$w"; continue ;;
        retry)
          tried=$((tried + 1)); ncap=$((ncap + 1)); log "⏳ no capacity for $o OCPU / $g GB ($(cat "$MSG"))"
          echo "| $t | $o OCPU / $g GB | ⏳ no capacity |" >> "$TABLE" ;;
        *)
          tried=$((tried + 1)); unknowns=$((unknowns + 1)); log "❓ unknown error: $(cat "$MSG")"
          echo "| $t | $o OCPU / $g GB | ❓ unknown error |" >> "$TABLE" ;;
      esac
      break
    done
    # pause before the next try (not after the very last one)
    { [ "$round" -eq "$ROUNDS" ] && [ "$i" -eq "$nshapes" ]; } || sleep $((GAP + RANDOM % (GAP / 3 + 1)))
  done
done

if [ "$tried" -gt 0 ] && [ "$unknowns" -ge "$tried" ]; then
  finish error "⚠️ Every try failed with an error I do not recognise. Read the log."
fi
if [ "$stopped_early" = 1 ]; then
  finish retry "⏳ Stopped early: time budget used after $tried real tries. The next scheduled run continues."
fi
finish retry "⏳ All $nshapes sizes were tried $ROUNDS times each. No capacity right now. The next scheduled run tries again."
