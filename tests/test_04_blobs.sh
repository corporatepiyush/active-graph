#!/usr/bin/env bash
# blob offload + content-addressed dedup (PLAN test_04, D1/D6/D7)
. "$(dirname "$0")/harness.bash"

R=$(new_run "blobs")
SEG="$AG_DIR/seg-000001.db"

# small payload stays inline
"$AG" emit --run "$R" --type x.small --payload '{"s":1}' >/dev/null
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM blobs;')" 0 "small payload not offloaded"
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM run_events WHERE payload IS NOT NULL AND seq=2;')" 1 "small payload inline"

# large payload offloaded
big=$(jq -cn '{data: ("y" * 2000)}')
"$AG" emit --run "$R" --type x.big --payload "$big" >/dev/null
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM blobs;')" 1 "large payload offloaded to blobs"
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM run_events WHERE seq=3 AND payload IS NULL AND body_ref IS NOT NULL;')" 1 "event row holds body_ref, not payload"

# dedup: identical payload again -> still one blob
"$AG" emit --run "$R" --type x.big --payload "$big" >/dev/null
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM blobs;')" 1 "identical payload deduplicated"

# different large payload -> second blob
big2=$(jq -cn '{data: ("z" * 2000)}')
"$AG" emit --run "$R" --type x.big --payload "$big2" >/dev/null
t_is "$("$SQ" "$SEG" 'SELECT count(*) FROM blobs;')" 2 "distinct payload gets its own blob"

# reconstitution is byte-exact through the events view
got=$("$AG" events --run "$R" --since 2 --limit 1 | jq -cS .payload)
want=$(printf '%s' "$big" | jq -cS .)
t_is "$got" "$want" "offloaded payload reconstitutes byte-exact"

# discriminator invariant: exactly one of payload/body_ref per row
n=$("$SQ" "$SEG" 'SELECT count(*) FROM run_events WHERE (payload IS NULL) = (body_ref IS NULL);')
t_is "$n" 0 "payload XOR body_ref holds for every row"
t_done
