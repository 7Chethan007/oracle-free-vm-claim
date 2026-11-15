#!/usr/bin/env bash
# One run: if the VM exists, stop. If not, try 3 sizes in order (OCPU:GB),
# and repeat that sequence ROUNDS times (default 3).
# Env: C AD SUBNET IMAGE SSH_PUB. Optional: GAP seconds between tries (20), ROUNDS (3).
# Writes result=created|exists|retry|fatal|error (plus id=, shape=) to $GITHUB_OUTPUT.
#   created/exists = done   retry = no capacity, try next run
#   fatal = bad config/auth, stop   error = unknown, read the log
set -u
OUT=${GITHUB_OUTPUT:-/dev/stdout}
NAME=forever-free
GAP=${GAP:-20}
ROUNDS=${ROUNDS:-3}
OCI=${OCI:-oci} # overridable for tests
SHAPES=(2:12 1:12 1:6) # biggest first; a smaller one is more likely to find room

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

finish() { echo "result=$1" >> "$OUT"; echo "RESULT: $1"; exit 0; }

jitter() { sleep $((RANDOM % (GAP / 3 + 1))); }

launch() { # $1=ocpus $2=GB -> prints created | retry | backoff | fatal | unknown
  local err res id
  err=$(mktemp); res=$(mktemp)
  if $OCI --no-retry compute instance launch -c "$C" --availability-domain "$AD" \
      --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$1,\"memoryInGBs\":$2}" \
      --subnet-id "$SUBNET" --image-id "$IMAGE" --display-name "$NAME" \
      --assign-public-ip true --boot-volume-size-in-gbs 150 \
      --ssh-authorized-keys-file <(echo "$SSH_PUB") >"$res" 2>"$err"; then
    echo "id=$(jq -r '.data.id // empty' "$res" 2>/dev/null)" >> "$OUT"
    echo "shape=$1 OCPU / $2 GB" >> "$OUT"
    echo created
  else
    cat "$err" >&2; classify <"$err"
  fi
}

check_exists() { # prints exists | none | retry | fatal | error
  local err n; err=$(mktemp)
  if ! n=$($OCI --no-retry compute instance list -c "$C" --display-name "$NAME" --all \
      --query 'length(data[?"lifecycle-state"!=`TERMINATED`&&"lifecycle-state"!=`TERMINATING`])' \
      --raw-output 2>"$err"); then
    cat "$err" >&2
    case "$(classify <"$err")" in fatal) echo fatal ;; unknown) echo error ;; *) echo retry ;; esac
    return
  fi
  [ "${n:-0}" != 0 ] && echo exists || echo none
}

jitter # spread load, avoid the top-of-the-minute rush
tried=0; unknowns=0
for round in $(seq "$ROUNDS"); do
  # 1) Already there? Then skip.
  c=$(check_exists)
  case "$c" in
    exists|fatal) finish "$c" ;;
    error) unknowns=$((unknowns + 1)); tried=$((tried + 1)); sleep "$GAP"; continue ;;
    retry) tried=$((tried + 1)); sleep "$GAP"; continue ;;
  esac
  # 2) Not there: request each size in turn.
  for s in "${SHAPES[@]}"; do
    tried=$((tried + 1))
    r=$(launch "${s%%:*}" "${s##*:}")
    echo "round $round, ${s%%:*} OCPU / ${s##*:} GB: $r" >&2
    case "$r" in
      created) finish created ;;
      fatal) finish fatal ;;
      unknown) unknowns=$((unknowns + 1)) ;;
      backoff) sleep $((GAP * 4 + RANDOM % (GAP + 1))); continue ;; # rate limited: wait longer
    esac
    sleep $((GAP + RANDOM % (GAP / 3 + 1)))
  done
done
# every try failed in a way we do not recognise -> surface it
[ "$tried" -gt 0 ] && [ "$unknowns" -ge "$tried" ] && finish error
finish retry
