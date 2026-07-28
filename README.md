<p align="center">
  <em>The Log is the Agent.</em><br>
  <sub>An append-only event log, a deterministic graph, cheap forks, and full lineage — in one Bash file.</sub>
</p>

<p align="center">
  <a href="#why">Why?</a> ·
  <a href="#quickstart">Quickstart</a> ·
  <a href="#concepts">Concepts</a> ·
  <a href="#command-reference">Commands</a> ·
  <a href="#behaviours-the-reactive-core">Behaviours</a> ·
  <a href="#json-rpc-server">Server</a> ·
  <a href="#operations">Operations</a> ·
  <a href="#configuration">Config</a> ·
  <a href="#tests">Tests</a> ·
  <a href="#paper-map">Paper Map</a>
</p>

---

## Why?

Most agent frameworks are spaghetti. State lives in RAM. Forking a conversation
means cloning a dict. There's no provenance, no replay, no lineage.

**ActiveGraph flips the model.** The log *is* the agent. Every mutation is an
append-only event. The graph is a deterministic *projection* of that log —
rebuildable from scratch at any time. Forking is O(1) because you just share a
pointer to a prefix. Replay is deterministic because hashes are compared
per-sequence. Behaviours react to graph *shapes*, and everything they do lands
back in the log with its provenance.

This is a Bash + SQLite implementation of that idea, based on
[Yohei Nakajima's paper](https://arxiv.org/abs/2605.21997)
(*"The Log is the Agent"*, May 2026) and the
[reference implementation](https://github.com/yoheinakajima/activegraph).

One file. Bash 5.3, SQLite 3.53, and socat if you want the server.

---

## Quickstart

```bash
bash active-graph.sh setup     # installs sqlite / bash / socat via brew or pkg
bash active-graph.sh doctor    # verify the machine before trusting it
bash active-graph.sh init      # → {"ok":true,"dir":"/path/.activegraph"}
```

The store lives in `$PWD/.activegraph` unless you set `AG_DIR` or pass `--dir`.

```bash
AG=./active-graph.sh     # the script re-execs itself into bash >= 5.3

R=$($AG run-start --goal "answer a question" --tags '["demo"]' | jq -r .run)
# → r1785149834-263a   (epoch seconds + random hex, never a guessable counter)

$AG emit --run "$R" --type object.created \
  --payload '{"kind":"question","data":{"text":"why bash?"}}'
# → {"run":"r1785149834-263a","seq":2,"hash":null,"req_hash":null}

$AG emit --run "$R" --type llm.requested \
  --payload '{"model":"claude","prompt":"why bash?"}'
# → seq 3, and this one IS hashed — requests and responses are the cacheable pair

$AG emit --run "$R" --type llm.responded --caused-by 3 \
  --payload '{"model":"claude","text":"because the log is the agent"}' \
  --ctx '{"estimated_cost_usd":0.004,"usage":{"total_tokens":180},"dur_ms":920}'
# → {"seq":4,...,"req_hash":"9427a7c7..."}   the hash of the REQUEST it answers

$AG emit --run "$R" --type object.created \
  --payload '{"kind":"claim","data":{"text":"the log is the agent","confidence":0.9}}'
$AG emit --run "$R" --type relation.created \
  --payload '{"src":"claim#1","kind":"addresses","dst":"question#1"}'
```

Now look at what you built:

```bash
$AG graph --run "$R"
# {"id":"question#1","kind":"question","data":{"text":"why bash?"},"created_by":"runtime","caused_seq":2}
# {"id":"claim#1","kind":"claim","data":{"text":"the log is the agent","confidence":0.9},...}

$AG graph --run "$R" --edges
# {"src":"claim#1","kind":"addresses","dst":"question#1","caused_seq":6}

$AG explain --run "$R" --obj claim#1
# {"object":{...},"chain":[{"seq":5,"type":"object.created","actor":"runtime","caused_by":null}]}

$AG insights --run "$R" | jq '{cost_usd,tokens,cache}'
# {"cost_usd":0.004,"tokens":180,"cache":{"requests":1,"answered":1}}

B=$($AG fork "$R" 4 | jq -r .run)          # O(1) — nothing is copied
$AG emit --run "$B" --type object.created \
  --payload '{"kind":"claim","data":{"text":"a different claim","confidence":0.4}}'
$AG diff "$R" "$B"
# {"objects":{"changed":[{"id":"claim#1","from":{...,"confidence":0.9},"to":{...,"confidence":0.4}}]},
#  "relations":{"removed":[{"src":"claim#1","kind":"addresses","dst":"question#1"}]},...}

$AG run-end --run "$R"
```

Everything answers `--help`:

```bash
bash active-graph.sh help              # the map: one line per command
bash active-graph.sh help emit         # emit's manual page
bash active-graph.sh emit --help       # the same thing, the way you'd type it
bash active-graph.sh help patterns     # the --match language
bash active-graph.sh help event-types  # built-in event types and their payloads
bash active-graph.sh help rpc          # methods, framing, auth
bash active-graph.sh help exit-codes   # what a non-zero exit means
bash active-graph.sh help env          # every environment knob
bash active-graph.sh help files        # what is in the store directory
```

**Or use it as a library** — sourcing skips the CLI dispatcher:

```bash
source active-graph.sh
export AG_DIR=/srv/agents/store
ag_open || exit 1
R=$(ag_run_start --goal "my task" | jq -r .run)
ag_emit --run "$R" --type object.created --payload '{"kind":"note","data":{"hi":"there"}}'
ag_events --run "$R"
ag_close
```

---

## Concepts

```
                        ┌──────────────────────────────┐
                        │     append-only event log     │
                        │         (run_events)          │
                        │  seq │ type │ payload │ hash  │
                        └──────────────┬───────────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    ▼                  ▼                  ▼
              ┌──────────┐     ┌──────────────┐   ┌───────────┐
              │  graph   │     │  cache       │   │   forks   │
              │ (proj DB)│     │  (req_hash)  │   │ (pointer) │
              └──────────┘     └──────────────┘   └───────────┘
                    │                                    │
              deterministic                         O(1) share
              rebuildable                           prefix rowids
```

| Property | How |
|---|---|
| **Append-only** | `INSERT` is the only write. No `UPDATE`/`DELETE` except erasure (`purge`, `segment-rewrite`). |
| **Deterministic ids** | The n-th object of kind `k` in a lineage is always `k#n`, minted by the runtime inside the insert transaction so concurrency cannot reorder it. The ordinal is persisted (`obj_n`), so allocation is one index probe regardless of run size. Caller-supplied ids are refused unless `AG_ALLOW_EXPLICIT_ID=1`. |
| **Content-addressed cache** | Responses carry `req_hash` — the hash of the *request* they answer, taken from `--caused-by` or `ctx.request_hash` — so a re-fired request finds its recorded response. That is what makes replay able to serve from the log. |
| **O(1) fork** | `runs(parent_rid, fork_seq)`. The prefix is never copied; a recursive CTE reads the lineage at query time. |
| **Deterministic replay** | Strict: per-seq hash comparison, and the first divergence is named. Permissive: a per-request hit/miss plan over the lineage. |
| **Frames** | Parallel branches *inside* one run (`f1`, `f2`, …), deterministic and replay-stable. Use a fork for alternative histories, a frame for concurrent work in the same one. |
| **Behaviours** | A subscription (event type + graph pattern + optional predicate) and a body. `react` fires them until the graph quiesces. |
| **Segmented store** | The log rolls over into segment files; drained segments are sealed to immutable, hashed, and pre-rolled-up. Reads union only the segments a lineage needs. |
| **Blob offload** | Payloads over 512 B are content-addressed into a blob table and deduplicated; reads reconstitute them transparently. |

---

## Command reference

Every command below also answers `--help` with its full options and an example.

### Runs and events

```bash
init                                   # create or verify the store
run-start [--goal G] [--tags JSON] [--parent RUN --at-seq N] [--close-parent]
emit --run R --type T (--payload JSON | --payload - | --payload@FILE)
     [--actor A] [--caused-by SEQ] [--ctx JSON] [--idem KEY]
emit-batch --run R                     # NDJSON on stdin, ONE transaction
events --run R [--type T] [--since SEQ] [--limit N]
fork <run> <seq> [--close-parent]      # parent stays live by default
run-end --run R [--status done|failed]
wait --run R [--types a,b] [--since SEQ] [--timeout MS]
```

```bash
# a large payload must not go through argv: Linux caps one argv string at 128 KiB
$AG emit --run "$R" --type x.document --payload@./big.json

# at-most-once: a retry after a lost reply returns the ORIGINAL seq, not a new row
$AG emit --run "$R" --type x.act --idem deploy-42 --payload '{"kind":"n","data":{}}'

# thousands of events, one transaction (~7,900 ev/s vs ~36 one at a time)
jq -c '.[]' events.json | $AG emit-batch --run "$R"

# long-poll: block until something new lands, or time out with an empty answer
$AG wait --run "$R" --types llm.responded --timeout 10000
```

### Graph and provenance

```bash
project --run R                        # rebuild the projection from the log
graph --run R [--nodes|--edges] [--kind K] [--from OBJ] [--to OBJ]
explain --run R --obj ID               # what created this, and what caused that
diff <runA> <runB>                     # structural: anti-join on (obj_id, hash)
```

### Determinism

```bash
verify --run R [--chain]               # structure, and optionally the hash chain
replay --run R                         # permissive: per-request hit/miss plan
replay --run R --strict                # candidate NDJSON on stdin; exits 7 on divergence
cache-lookup <sha3-hex> [--by request|response|any]
frame-open --run R [--parent fN]
frame-close --run R --frame fN [--result JSON]
```

```bash
$AG replay --run "$R"
# {"seq":3,"type":"llm.requested","request_hash":"9427a7c7...","cache":"hit",
#  "response_seq":4,"response":{"text":"because the log is the agent"}}
# 'hit' = a re-run serves that step from the log. 'miss' = it has to call out.

AG_CHAIN=1 $AG verify --run "$R" --chain    # names the first tampered sequence
```

### Storage lifecycle

```bash
seal [--seg N | --all]                 # drained segment → immutable, hashed, rolled up
maintain                               # seal + drop purged + rollover check + optimize
verify-files [--quarantine]            # re-hash sealed segments (bitrot, tampering)
backup <dest>                          # incremental: only the sealed files dest lacks
purge --run R                          # erase a run's events AND its blobs
segment-rewrite <run>                  # GDPR hard-delete out of a SEALED segment
migrate [--dry-run]                    # bring an older store to this schema
```

### Introspection

```bash
stats                                  # {"events":7,"runs":2,"blobs":0,"models":[...]}
insights [--run R] [--limit N]         # cost / tokens / latency, by model and tool
scan [--parallel N] [--sealed-only] <SQL>
doctor                                 # read-only health report; serve runs it at startup
version | help [command|topic]
```

```bash
# raw SQL over every segment, each in its own read-only process (:seg is bound)
$AG scan --parallel 4 "SELECT :seg, count(*) FROM run_events WHERE tid = 10;"
```

---

## Behaviours (the reactive core)

A behaviour is the paper's §3 construct: a **subscription** — an event type, a
graph-shape pattern in a Cypher subset, and optional guards — plus a **body**.
The body is an argv array (never a shell string, never `eval`); it receives the
match as JSON on stdin and returns NDJSON events on stdout.

```bash
cat > answer.sh <<'SH'
#!/usr/bin/env bash
q=$(jq -r '.bind.q.id')          # the match arrives on stdin
printf '{"type":"object.created","payload":{"kind":"answer","data":{"to":"%s","text":"..."}}}\n' "$q"
printf '{"type":"relation.created","payload":{"src":"%s","kind":"answered_by","dst":"answer#1"}}\n' "$q"
SH
chmod +x answer.sh

$AG behavior-add --name answer_open_questions \
  --on object.created \
  --match '(q:question)' \
  --absent 'q-[:answered_by]->' \
  -- ./answer.sh
# --absent is the negative guard: this is how you say "unanswered"

$AG react --run "$R"
# → {"run":"r1785149834-263a","rounds":1,"fired":1,"quiesced":true}
```

Everything it did is in the log, bracketed with provenance:

```bash
$AG events --run "$R" --since 6 | jq -c '{seq,type}'
# {"seq":7,"type":"behavior.started"}
# {"seq":8,"type":"object.created"}
# {"seq":9,"type":"relation.created"}
# {"seq":10,"type":"behavior.completed"}

$AG graph --run "$R" | tail -1
# {"id":"answer#1","kind":"answer",...,"created_by":"answer_open_questions","caused_seq":8}
```

The pattern language (`help patterns`) is deliberately small — up to 3 nodes and
2 hops:

```
(c)                          any node, bound to variable c
(c:claim)                    a node of kind 'claim'
(c:claim)-[:addresses]->(q)  an outgoing edge
(a)<-[:answered_by]-(q)      an incoming edge
--absent 'q-[:answered_by]->'      only where q has no such edge
--where  "c.data ->> '$.confidence' < 0.5"    a predicate over matched nodes
```

Cascades are bounded (`--max-rounds`, default 100), bodies are killed past
`AG_BEHAVIOR_TIMEOUT_S`, and fire-once is enforced by a key stored **in the
log** — so a restarted reactor does not re-fire what already ran.

```bash
$AG behaviors                          # list the registry
$AG behavior-remove --name answer_open_questions
$AG react --run "$R" --once            # a single round
```

`--where` is operator-supplied SQL, so `behavior-add` is CLI-only.

---

## JSON-RPC server

```bash
bash active-graph.sh serve                          # IPC (default): $AG_DIR/ag.sock
bash active-graph.sh serve --transport tcp --port 4900
bash active-graph.sh serve --readers 4              # 4 read-only engines
AG_TOKEN=$(openssl rand -hex 16) bash active-graph.sh serve
bash active-graph.sh serve --token-file ./tok       # file must be mode 0600
```

One request per line. **socat is required**: it forks one process per
connection, so clients are genuinely concurrent and SQLite's own locking
arbitrates between them. There is no fallback listener — `nc` exposes a single
stdio stream for the whole listener, so it cannot tell two clients apart.

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}\n' \
  | socat - UNIX-CONNECT:.activegraph/ag.sock
# {"jsonrpc":"2.0","id":1,"result":{"ok":true,"version":"0.2.0"}}

printf '{"jsonrpc":"2.0","id":2,"method":"ag.emit","params":{"run":"'"$R"'",
        "type":"x.tick","payload":{"kind":"n","data":{"i":1}}}}\n' \
  | socat - UNIX-CONNECT:.activegraph/ag.sock
```

**Methods:** `ag.ping` `ag.run_start` `ag.emit` `ag.emit_batch` `ag.events`
`ag.fork` `ag.run_end` `ag.replay` `ag.cache_lookup` `ag.stats` `ag.project`
`ag.graph` `ag.explain` `ag.diff` `ag.wait` `ag.frame_open` `ag.frame_close`
`ag.insights` `ag.behaviors` `ag.react`.

**Not exposed, on purpose:** `scan`, `migrate`, `purge`, `segment-rewrite`,
`seal`, `backup`, `setup` — operator commands that take raw SQL or destroy data
stay CLI-only.

| Concern | Behaviour |
|---|---|
| Transport | IPC by default: the access control is the filesystem (`$AG_DIR` is 0700, socket 0600). No network surface at all. |
| TCP | Binds `127.0.0.1` unless you pass **both** a token and `--allow-remote`. |
| Auth | Token via `AG_TOKEN` or a 0600 file; `--token` on argv is refused, because argv is visible in `ps`. Fixed-length hash compare, 3-strike drop, cooldown. |
| Framing | Bounded at `AG_MAX_FRAME`; a dribbled frame (slowloris) and an idle connection are both dropped at `AG_REQ_DEADLINE_S`. |
| Responses | Capped at `AG_MAX_RESP` with "paginate with limit/since_seq" rather than a multi-GB line. |
| Batches | JSON-RPC arrays, capped at `AG_MAX_BATCH`. Notifications (no `id`) are answered with silence, per spec. |
| Concurrency | `max-children` connection cap; saturation queues and surfaces as `-32000 busy`, never a hang. |
| Logging | `ag-access.log`, 0600, control characters stripped, rotated. Tokens never appear in it. |
| Single instance | Pidfile guard; stale sockets are detected and unlinked. |

`rpc-child` is an inetd-style stdio handler, so systemd socket activation,
launchd, or `ncat --exec` work unmodified:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"ag.ping"}' | bash active-graph.sh rpc-child
```

---

## Operations

**Segments.** The active segment rolls over past `AG_SEG_MAX_BYTES` (64 GiB).
A run is pinned to the segment it started in, so an in-flight run never
straddles a rollover. Once a segment has no live runs, `seal` makes it a single
immutable file — journal mode DELETE, mode 400, sha256 recorded, per-dimension
rollups precomputed so later `stats`/`insights` never rescan it. Sealed
segments attach `immutable=1` and take no locks at all, which is what makes
`scan --parallel` cheap.

```bash
$AG maintain            # cron this: seal, drop purged, rollover check, sweep, optimize
$AG verify-files --quarantine
$AG backup /srv/backups/agents
```

**Erasure.** `purge` deletes a live-segment run's events plus any blob left with
no other referrer, under `secure_delete` and a WAL checkpoint, so the bytes
leave both the database and its write-ahead log. For a run in a *sealed*
segment, `segment-rewrite` rebuilds the file without it and swaps it in
atomically — the bytes leave disk *before* the catalog is updated, so a crash
mid-rewrite still satisfies erasure — then scrubs the run row and VACUUMs the
catalog.

**Schema drift.** Every open verifies `user_version` and a schema fingerprint
and fails **closed** (exit 65) rather than half-working. `migrate` is
version-gated, idempotent and resumable, and re-hashes any sealed segment it
rewrites.

**When something is off, start with `doctor`** — it reports the resolved sqlite
and bash, sha3/readfile/JSONB support, `serve_ok`, file modes, and the
filesystem type (a store on a 9p/drvfs mount is refused, because SQLite locking
is not reliable there). It never touches the network.

---

## Configuration

`--dir DIR` on any command, or `AG_DIR`. Full list: `help env`.

| Var | Default | Purpose |
|---|---|---|
| `AG_DIR` | `$PWD/.activegraph` | Store directory (0700, enforced) |
| `AG_SQLITE` | auto-detected | Path to a sqlite3 ≥ 3.53.3 |
| `AG_READERS` | `2` | Extra read-only engines |
| `AG_CHAIN` | `0` | `1` = maintain the tamper-evident hash chain |
| `AG_BLOB_MIN` | `512` | Payloads over this many bytes are offloaded |
| `AG_TOKEN` | none | Auth token (≥ 16 chars) — never pass one on argv |
| `AG_ALLOW_EXPLICIT_ID` | `0` | `1` = accept caller-supplied object ids |
| `AG_MAX_PAYLOAD` | 1 MiB | Per-event payload cap |
| `AG_MAX_FRAME` / `AG_MAX_RESP` | 1 MiB / 8 MiB | RPC request and response caps |
| `AG_MAX_BATCH` | `1000` | Elements per batch / `emit-batch` |
| `AG_MAX_CHILDREN` | `32` | Concurrent server connections |
| `AG_REQ_DEADLINE_S` | `30` | Idle and in-flight request bound |
| `AG_ENG_HANDSHAKE_S` | `30` | Bound on an engine's *first* reply only |
| `AG_SEG_MAX_BYTES` | 64 GiB | Rollover threshold |
| `AG_BEHAVIOR_TIMEOUT_S` | `60` | Max wall time for one behaviour body |
| `AG_REACT_MAX_ROUNDS` | `100` | Cascade bound for `react` |
| `AG_DEBUG` | `0` | Verbose diagnostics on stderr |

**Exit codes** (`help exit-codes`): `0` ok · `2` bad arguments · `3` no such run
· `4` busy, retry · `5` storage (no space, or a store that cannot be opened) ·
`6` unauthorized · `7` replay divergence · `65` schema mismatch, run `migrate` ·
`70` bash too old · `1` anything else. Errors print one JSON object on
**stderr**, so stdout stays parseable.

**Store layout** (`help files`): `ag-catalog.db` (runs, segments, interned types
and actors, behaviours), `seg-NNNNNN.db` (events and blobs, one per rollover
window), `ag-proj.db` (the projection — derived, disposable, never backed up),
`ag.sock`, `ag-serve.pid`, `ag-access.log`.

---

## Tests

47 TAP test files, run in a bounded parallel pool:

```bash
bash tests/run-all.sh          # JOBS=n to override the pool size
```

Every test gets a fresh temp store, and **every case is capped at 5 s** — a test
that must observe a timeout drives the runtime's own knobs down rather than
sleeping through the production defaults. Fuzz is seeded and reproducible
(`FUZZ_SEED` is printed as a TAP diagnostic).

Coverage: emit, blobs, binding (`'`, `;--`, `$(cmd)`, newlines, 10 MB, unicode →
stored byte-exact, never executed), fork lineage, replay, cache, projection,
diff, frames, purge, concurrency (8 writers × 500 events), crash safety
(`kill -9` mid-write), rollover, seal, the attach router, backup, segment
rewrite, migrate, reader pools, behaviours, JSON-RPC framing/validation/auth/
backpressure/concurrency, injection regressions for every confirmed exploit,
generative fuzz, platform probes, and help.

CI includes amd64 Linux via `Dockerfile.test` (Alpine edge: bash 5.3.9, sqlite
3.53.3, socat) — that run is what surfaced the argv `E2BIG` payload limit and
several GNU-vs-BSD assumptions.

---

## Paper Map

| Paper § | Concept | Implementation |
|---|---|---|
| §3 | Append-only log | `run_events`, INSERT-only |
| §3 | Deterministic ids `kind#n` | Minted inside the insert txn; ordinal persisted as `obj_n` |
| §3 | Behaviours (subscription + body) | `behaviors` registry; `--match` compiles a Cypher subset to SQL over the projection; `react` dispatches, stamps provenance, enforces fire-once from the log |
| §4 | Content-addressed cache | `req_hash` partial index — keyed on the *request*, as the paper specifies |
| §4 | Replay (strict / permissive) | `replay --strict` names the first divergent seq; `replay` prints the hit/miss plan |
| §4 | Fork at seq k | `runs(parent_rid, fork_seq)`, recursive-CTE reads |
| §5 | Graph = projection | `ag_nodes`/`ag_edges` in a disposable database |
| §5 | Structural diff | Anti-joins on `(obj_id, hash)` |
| §5 | Frames (parallel branches) | `frame.opened`/`frame.closed`, deterministic ids |
| §6 | Change notification | `wait` — `data_version` long-poll with type filters |
| §8.6 | Platform probe | `doctor`, `_platform_init`, `_fs_guard`, `/dev/tcp` probe with an `nc -z` fallback |
| §10 | JSON-RPC server | socat **required** — one process per connection |
| §12 | Auth | Token via env or 0600 file, fixed-length hash compare, 3-strike drop + cooldown |
| §10.7 | Access log | `ag-access.log` (0600, control-char stripped, rotated) |

**Beyond the paper:** environment fingerprinting (including a self-hash of this
script, so editing it is detectable), `insights`, segmented storage with
seal-to-immutable, incremental `backup`, `verify-files`, `segment-rewrite`
(GDPR), reader pools, `scan`, and `migrate`.

The full design contract — and the amendment log recording everywhere the
implementation now differs from it, and why — lives alongside the source in
`PLAN.md`. Where that document and the code disagree, the code and its tests
are authoritative.

---

## Platform support

macOS (Apple Silicon and Intel), Linux, WSL2, FreeBSD. Requires:

- **Bash ≥ 5.3** — `${ cmd; }` funsubs, `EPOCHREALTIME`, `coproc`. The script
  re-execs itself into the newest bash it can find, so `#!/bin/bash` being 3.2
  on macOS is fine.
- **SQLite ≥ 3.53** — `sha3()`, `readfile()`, JSONB. `.dbconfig defensive` is
  enabled when the build has it compiled in.
- **socat** — only for `serve`. `ag doctor` reports `serve_ok`; `ag setup`
  installs it.

---

## License

[Apache 2.0](LICENSE) — Piyush Katariya, 2026.

Based on *"The Log is the Agent"* by Yohei Nakajima
([arXiv:2605.21997](https://arxiv.org/abs/2605.21997),
[reference impl](https://github.com/yoheinakajima/activegraph)).
