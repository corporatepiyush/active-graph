#!/usr/bin/env bash
# ATTACH router: cross-segment lineage, LRU reuse, deep-lineage limit (PLAN 7.3)
. "$(dirname "$0")/harness.bash"
export AG_SEG_MAX_BYTES=262144
# A payload this size cannot be an ARGV STRING: Linux caps a single argument
# at 128 KiB (MAX_ARG_STRLEN), so passing it as --payload fails with E2BIG there
# while it works on macOS. Use the file form, which is portable.
BIG=$(big_payload_file "$TDIR/big-payload.json" doc 300000)
max_seq() { "$AG" events --run "$1" | jq -s 'map(.seq)|max'; }

# Fork chain: each generation pinned to its own sealed segment, forking at the
# parent's MAX seq so every generation's object accumulates in the lineage.
# Sets CHAIN_TIP (deepest run) and CHAIN_ERR (error that broke the chain, if any).
build_chain() {  # $1 = target depth
    "$AG" init >/dev/null
    local root prev nf gen ms
    root=$(new_run root)
    "$AG" emit --run "$root" --type object.created --payload '{"kind":"g","data":{"n":0}}' >/dev/null
    prev=$root; CHAIN_ERR=''
    for gen in $(seq 1 "$1"); do
        "$AG" emit --run "$prev" --type x.bloat "--payload@$BIG" >/dev/null 2>&1
        "$AG" run-end --run "$prev" >/dev/null 2>&1
        "$AG" run-start --goal "roll$gen" >/dev/null 2>&1   # rollover
        "$AG" seal --all >/dev/null 2>&1                     # seal drained
        ms=$(max_seq "$prev")
        nf=$("$AG" fork "$prev" "$ms" 2>"$TDIR/forkerr" | jq -r '.run // empty')
        [[ -n $nf ]] || { CHAIN_TIP=''; CHAIN_ERR=$(cat "$TDIR/forkerr"); return 1; }
        "$AG" emit --run "$nf" --type object.created --payload "{\"kind\":\"g\",\"data\":{\"n\":$gen}}" >/dev/null 2>&1
        prev=$nf
    done
    CHAIN_TIP=$prev
}

# depth 5 -> lineage spans 6 segments, within the attach budget
build_chain 5
t_ok "$([ -n "$CHAIN_TIP" ]; echo $?)" "5-deep cross-segment fork chain builds"
span=$("$SQ" "$AG_DIR/ag-catalog.db" "WITH RECURSIVE lin(rid) AS (SELECT rid FROM runs WHERE run_id='$CHAIN_TIP' UNION ALL SELECT r.parent_rid FROM runs r JOIN lin ON r.rid=lin.rid WHERE r.parent_rid IS NOT NULL) SELECT count(DISTINCT seg_id) FROM runs WHERE rid IN (SELECT rid FROM lin);")
t_is "$span" 6 "tip lineage spans 6 segments"
t_is "$("$AG" verify --run "$CHAIN_TIP" | jq -r .ok)" true "verify recomputes hashes across 6 sealed segments"
# every generation's object accumulates (forked at parent max seq)
t_is "$("$AG" graph --run "$CHAIN_TIP" --kind g | jq -s length)" 6 "all 6 generations' objects visible across segments"
t_is "$("$AG" graph --run "$CHAIN_TIP" --kind g | jq -r .id | paste -sd, -)" "g#1,g#2,g#3,g#4,g#5,g#6" "deterministic ids span every segment"

# repeated reads of a multi-segment lineage stay correct (view/attach reuse)
a=$("$AG" verify --run "$CHAIN_TIP" | jq -r .ok)
b=$("$AG" verify --run "$CHAIN_TIP" | jq -r .ok)
t_is "$a,$b" "true,true" "repeated cross-segment reads are stable"

# a shallow run in the same multi-segment store still reads via its own 1-segment lineage
SHALLOW=$(new_run shallow); "$AG" emit --run "$SHALLOW" --type x.a --payload '{}' >/dev/null
t_is "$("$AG" events --run "$SHALLOW" | jq -s length)" 2 "unrelated shallow run reads independently"

# cross-lineage correctness under eviction pressure: two independent chains with
# 5 segments each (10 total > budget of 8). Reading chain B forces the router
# to evict some of A's segments via LRU; re-reading A re-attaches them.
# Both reads must return correct data.
rm -rf "$AG_DIR"; "$AG" init >/dev/null
# chain A: 5 sealed segments
prev=$(new_run chainA); "$AG" emit --run "$prev" --type object.created --payload '{"kind":"g","data":{"a":"init"}}' >/dev/null
for gen in $(seq 1 4); do
    "$AG" emit --run "$prev" --type x.bloat "--payload@$BIG" >/dev/null 2>&1
    "$AG" run-end --run "$prev" >/dev/null 2>&1
    "$AG" run-start --goal "a$gen" >/dev/null 2>&1
    "$AG" seal --all >/dev/null 2>&1
    ms=$("$AG" events --run "$prev" | jq -s 'map(.seq)|max')
    prev=$("$AG" fork "$prev" "$ms" | jq -r '.run')
    "$AG" emit --run "$prev" --type object.created --payload "{\"kind\":\"g\",\"data\":{\"a\":\"gen$gen\"}}" >/dev/null 2>&1
done
chain_a_tip=$prev
a_count=$("$AG" events --run "$chain_a_tip" | jq -s 'map(.seq)|max')
t_diag "chain A tip=$chain_a_tip max_seq=$a_count"
# chain B: 5 sealed segments (independent, no fork relationship to A)
prev=$(new_run chainB); "$AG" emit --run "$prev" --type object.created --payload '{"kind":"g","data":{"b":"init"}}' >/dev/null
for gen in $(seq 1 4); do
    "$AG" emit --run "$prev" --type x.bloat "--payload@$BIG" >/dev/null 2>&1
    "$AG" run-end --run "$prev" >/dev/null 2>&1
    "$AG" run-start --goal "b$gen" >/dev/null 2>&1
    "$AG" seal --all >/dev/null 2>&1
    ms=$("$AG" events --run "$prev" | jq -s 'map(.seq)|max')
    prev=$("$AG" fork "$prev" "$ms" | jq -r '.run')
    "$AG" emit --run "$prev" --type object.created --payload "{\"kind\":\"g\",\"data\":{\"b\":\"gen$gen\"}}" >/dev/null 2>&1
done
chain_b_tip=$prev
b_count=$("$AG" events --run "$chain_b_tip" | jq -s 'map(.seq)|max')
t_diag "chain B tip=$chain_b_tip max_seq=$b_count"

# read chain A (attaches 5 segments, within budget)
a_verify=$("$AG" verify --run "$chain_a_tip" | jq -r .ok)
a_graph=$("$AG" graph --run "$chain_a_tip" --kind g | jq -s length)
# read chain B (needs 5 more; total 10 > budget 8 -> LRU eviction of A's segs)
b_verify=$("$AG" verify --run "$chain_b_tip" | jq -r .ok)
b_graph=$("$AG" graph --run "$chain_b_tip" --kind g | jq -s length)
# re-read chain A (re-attaches evicted segments)
a2_verify=$("$AG" verify --run "$chain_a_tip" | jq -r .ok)
a2_graph=$("$AG" graph --run "$chain_a_tip" --kind g | jq -s length)

t_is "$a_verify" true "chain A verify after initial read"
t_is "$b_verify" true "chain B verify (LRU evicts A's segments)"
t_is "$a2_verify" true "chain A verify after re-read (re-attach)"
t_is "$a_graph" 5 "chain A: 5 generations visible"
t_is "$b_graph" 5 "chain B: 5 generations visible"
t_is "$a2_graph" 5 "chain A: 5 generations visible after re-read"

# deep-lineage limit: past MAX_ATTACHED=10 the store keeps a run whose lineage
# spans >10 segments; reading it must FAIL GRACEFULLY with a clear message
# (not a cryptic sqlite error, not silently wrong data).
rm -rf "$AG_DIR"; "$AG" init >/dev/null
root=$(new_run root); "$AG" emit --run "$root" --type object.created --payload '{"kind":"g","data":{"n":0}}' >/dev/null
prev=$root; deep_err=''
for gen in $(seq 1 14); do
    "$AG" emit --run "$prev" --type x.bloat "--payload@$BIG" >/dev/null 2>&1
    "$AG" run-end --run "$prev" >/dev/null 2>&1
    "$AG" run-start --goal "d$gen" >/dev/null 2>&1
    "$AG" seal --all >/dev/null 2>&1
    ms=$("$AG" events --run "$prev" 2>"$TDIR/rerr" | jq -s 'map(.seq)|max // empty')
    if [[ -z $ms ]]; then deep_err=$(cat "$TDIR/rerr"); break; fi   # read hit the ceiling
    nf=$("$AG" fork "$prev" "$ms" 2>"$TDIR/ferr" | jq -r '.run // empty')
    [[ -n $nf ]] || { deep_err=$(cat "$TDIR/ferr"); break; }
    "$AG" emit --run "$nf" --type object.created --payload '{"kind":"g","data":{}}' >/dev/null 2>&1
    prev=$nf
done
t_ok "$([ -n "$deep_err" ]; echo $?)" "a >10-segment lineage is eventually rejected"
t_like "$deep_err" "*too many segments*" "deep-lineage failure has a clear, documented message"
t_done
