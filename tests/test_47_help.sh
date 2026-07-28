#!/usr/bin/env bash
# help & version.
#
# Help is the one thing that has to work when nothing else does, so the
# assertions here are mostly about what help must NOT depend on and must NOT
# touch: no store, no schema check, no stderr, no non-zero exit.
. "$(dirname "$0")/harness.bash"

# ---------------------------------------------------------------------------
# asking is success, guessing wrong is a usage error
# ---------------------------------------------------------------------------
out=$("$AG" help 2>"$TDIR/e"); rc=$?
t_is "$rc" 0 "help exits 0 — asking for help is not an error"
t_is "$(wc -c <"$TDIR/e" | tr -d ' ')" 0 "help writes nothing to stderr (stdout stays pipeable)"
t_like "$out" "*usage: active-graph.sh <command>*" "help prints the command map"
t_like "$out" "*help <command>*" "help says how to go deeper"

"$AG" --help >/dev/null 2>&1; t_is $? 0 "--help is the same as help"
"$AG" -h     >/dev/null 2>&1; t_is $? 0 "-h is the same as help"

"$AG" >/dev/null 2>&1;            t_is $? 2 "no command at all is still a usage error"
"$AG" frobnicate >/dev/null 2>&1; t_is $? 2 "an unknown command is a usage error"
"$AG" help frobnicate >/dev/null 2>&1; t_is $? 2 "an unknown help topic is a usage error"

t_is "$("$AG" version)" "$("$AG" --version)" "version and --version agree"
t_like "$("$AG" version)" "[0-9]*.[0-9]*.[0-9]*" "version is a version"

# ---------------------------------------------------------------------------
# every dispatchable command answers --help, and answers with its own usage
# line rather than the generic map. This is the assertion that catches a
# command added to the dispatcher without a help topic.
# ---------------------------------------------------------------------------
CMDS="init run-start emit emit-batch events fork run-end cache-lookup verify
      purge segment-rewrite project graph explain diff wait replay frame-open
      frame-close seal maintain verify-files backup stats insights behavior-add
      behaviors behavior-remove react scan migrate doctor setup serve rpc-child"
undocumented='' generic=''
for c in $CMDS; do
    h=$("$AG" help "$c" 2>/dev/null) || { undocumented="$undocumented $c"; continue; }
    case $h in *"usage: active-graph.sh <command>"*|'') generic="$generic $c" ;; esac
done
t_is "$undocumented" "" "every command has a help topic"
t_is "$generic" "" "every command's help is its own, not a fallback to the map"

for t in event-types patterns rpc exit-codes env files; do
    "$AG" help "$t" >/dev/null 2>&1 || t_diag "topic missing: $t"
done
t_ok $( for t in event-types patterns rpc exit-codes env files; do
            "$AG" help "$t" >/dev/null 2>&1 || exit 1; done; echo $? ) \
     "the non-command topics all resolve"

# `<command> --help` is how people actually ask
t_like "$("$AG" emit --help 2>&1)"  "*usage: emit --run RUN*" "emit --help documents emit"
t_like "$("$AG" serve --help 2>&1)" "*REQUIRES socat*"        "serve --help names the socat requirement"
t_like "$("$AG" scan --help 2>&1)"  "*:seg*"                  "scan --help documents the bound segment id"
"$AG" emit --help >/dev/null 2>&1; t_is $? 0 "a --help'd command exits 0 without running"

# ---------------------------------------------------------------------------
# help must not need — or create — a store. This is the case that matters: you
# reach for help precisely when the store is missing, stale or unreadable.
# ---------------------------------------------------------------------------
EMPTY="$TDIR/nostore"
mkdir -p "$EMPTY"
( cd "$EMPTY" && AG_DIR="$EMPTY/.activegraph" "$AG" help emit >/dev/null 2>&1 )
t_is $? 0 "help works with no store present"
t_is "$(ls -A "$EMPTY" | wc -l | tr -d ' ')" 0 "...and creates nothing while doing it"

# a store the runtime would refuse to open must still hand out help
BROKEN="$TDIR/broken"
mkdir -p "$BROKEN"
printf 'this is not a database' > "$BROKEN/ag-catalog.db"
AG_DIR="$BROKEN" "$AG" events --help >/dev/null 2>&1
t_is $? 0 "help still works against a store that cannot be opened"
AG_DIR="$BROKEN" "$AG" events --run r1785148979-e9cb >/dev/null 2>&1
t_fails $? "...while the same command without --help still fails on that store"

# ---------------------------------------------------------------------------
# the --help scan stops at `--`: everything after it is a behaviour body's
# argv, and a body that takes a --help flag is not asking US for help.
# ---------------------------------------------------------------------------
"$AG" init >/dev/null
"$AG" behavior-add --name helpish --on object.created --match '(q:question)' -- /bin/echo --help >/dev/null 2>&1
t_is $? 0 "a behaviour body may contain --help in its argv"
t_is "$("$AG" behaviors | jq -r '.argv | join(" ")')" "/bin/echo --help" \
     "...and it is stored as body argv, not intercepted as a help request"

t_done
