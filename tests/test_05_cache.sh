#!/usr/bin/env bash
# content-addressed replay cache (PLAN test_05, paper section 4)
. "$(dirname "$0")/harness.bash"

R=$(new_run "cache")

# hash set on llm/tool request+response types only
h_req=$("$AG" emit --run "$R" --type llm.requested --payload '{"model":"m","p":"q"}' | jq -r .hash)
h_res=$("$AG" emit --run "$R" --type llm.responded --payload '{"model":"m","text":"a"}' | jq -r .hash)
h_note=$("$AG" emit --run "$R" --type x.note --payload '{"n":1}' | jq -r .hash)
t_like "$h_req" "????????????????????????????????????????????????????????????????" "llm.requested carries 64-hex hash"
t_like "$h_res" "????????????????????????????????????????????????????????????????" "llm.responded carries hash"
t_is "$h_note" null "non-cache event types carry no hash"

# lookup by responded-hash hits (byte-identity probe over tids 7,9)
hit=$("$AG" cache-lookup "$h_res")
t_is "$(printf '%s' "$hit" | jq -r .hit)" true "responded hash -> cache hit"
t_is "$(printf '%s' "$hit" | jq -r .payload.text)" a "hit returns the recorded payload"
t_is "$(printf '%s' "$hit" | jq -r .keyed)" response "response-keyed hit is labelled"

# PAPER SEMANTICS (section 4): "a model response is keyed on a hash of the
# entire request ... when a behavior re-fires with a request whose hash matches
# a recorded one, the cached response is served". A response that declares which
# request it answers (caused_by, or ctx.request_hash) is therefore findable BY
# THE REQUEST HASH — which is the only hash a replaying caller actually has.
CR=$(new_run "cache-req")
q=$("$AG" emit --run "$CR" --type llm.requested --payload '{"model":"m","prompt":"why"}')
qseq=$(printf '%s' "$q" | jq -r .seq); qh=$(printf '%s' "$q" | jq -r .hash)
"$AG" emit --run "$CR" --type llm.responded --caused-by "$qseq" \
      --payload '{"model":"m","text":"because"}' >/dev/null
hit=$("$AG" cache-lookup "$qh")
t_is "$(printf '%s' "$hit" | jq -r .hit)" true "REQUEST hash -> cache hit (paper section 4)"
t_is "$(printf '%s' "$hit" | jq -r .keyed)" request "hit is labelled request-keyed"
t_is "$(printf '%s' "$hit" | jq -r .payload.text)" because "request-keyed hit returns the recorded RESPONSE"
t_is "$("$AG" cache-lookup "$qh" --by response | jq -r .hit)" false "--by response does not match a request hash"

# ctx.request_hash is the explicit alternative to caused_by
CR2=$(new_run "cache-ctx")
"$AG" emit --run "$CR2" --type llm.responded --ctx "{\"request_hash\":\"$qh\"}" \
      --payload '{"model":"m","text":"explicit"}' >/dev/null
t_is "$(AG_DIR="$AG_DIR" "$AG" cache-lookup "$qh" --by request | jq -r .hit)" true "ctx.request_hash also keys the cache"

# a request with no recorded response still misses
t_is "$("$AG" cache-lookup "$h_req" | jq -r .hit)" false "unanswered request hash -> miss"

# unknown hash -> miss
t_is "$("$AG" cache-lookup "$(printf '0%.0s' $(seq 64))" | jq -r .hit)" false "unknown hash -> miss"

# hash stability: identical payload emitted again yields the identical hash
h2=$("$AG" emit --run "$R" --type llm.responded --payload '{"model":"m","text":"a"}' | jq -r .hash)
t_is "$h2" "$h_res" "hash is deterministic for identical payloads"

# malformed hash rejected
"$AG" cache-lookup deadbeef >/dev/null 2>&1
t_is $? 2 "short hash rejected with usage error"

# --- cross-segment cache lookup (PLAN 8d) -------------------------------------
# a response cached in an OLD segment must still be found after the store has
# rolled over and sealed that segment (lookup is store-wide, not active-only).
X="$TDIR/xstore"
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
AG_DIR="$X" AG_SEG_MAX_BYTES=262144 "$AG" init >/dev/null
XR=$(AG_DIR="$X" "$AG" run-start --goal x | jq -r .run)
hx=$(AG_DIR="$X" "$AG" emit --run "$XR" --type llm.responded --payload '{"model":"m","text":"cached-in-seg1"}' | jq -r .hash)
AG_DIR="$X" "$AG" emit --run "$XR" --type object.created "--payload@$BIG" >/dev/null   # push seg-1 over
AG_DIR="$X" "$AG" run-end --run "$XR" >/dev/null
XR2=$(AG_DIR="$X" AG_SEG_MAX_BYTES=262144 "$AG" run-start --goal x2 | jq -r .run)       # rolls to seg-2
t_like "$("$SQ" "$X/ag-catalog.db" 'SELECT group_concat(state) FROM segments;')" "*draining*active*" "store rolled over"
t_is "$(AG_DIR="$X" "$AG" cache-lookup "$hx" | jq -r .payload.text)" "cached-in-seg1" "hit in a DRAINING non-active segment"
AG_DIR="$X" "$AG" maintain >/dev/null 2>&1
t_is "$("$SQ" "$X/ag-catalog.db" 'SELECT state FROM segments WHERE seg_id=1;')" sealed "seg-1 sealed"
t_is "$(AG_DIR="$X" "$AG" cache-lookup "$hx" | jq -r .payload.text)" "cached-in-seg1" "hit in a SEALED immutable segment"
# newest-first: an identical payload re-cached in the active segment still hits
AG_DIR="$X" "$AG" emit --run "$XR2" --type llm.responded --payload '{"model":"m","text":"cached-in-seg1"}' >/dev/null
t_is "$(AG_DIR="$X" "$AG" cache-lookup "$hx" | jq -r '.hit')" "true" "still a hit with copies in multiple segments"
t_done
