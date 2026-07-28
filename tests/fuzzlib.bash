# fuzzlib.bash — seeded, reproducible generators for parametric testing.
#
# Two properties matter more than volume:
#   1. REPRODUCIBILITY. Every generator is driven by FUZZ_SEED, printed as a TAP
#      diagnostic, so a failure can be replayed exactly: FUZZ_SEED=<n> bash <test>.
#      Unseeded fuzz that fails once and never again is not a test.
#   2. HOSTILE DISTRIBUTION. Uniform random bytes almost never produce the inputs
#      that actually break this runtime. The alphabets below are weighted toward
#      what does: SQL metacharacters, the engine's own wire-protocol tokens,
#      shell expansions, JSON escapes, and boundary-length strings.
#
# Generation happens inside ONE awk process per call (portable across gawk, mawk
# and busybox awk) so a large N costs one fork, not N.

: "${FUZZ_SEED:=$$}"

# ---------------------------------------------------------------------------
# fz_payloads N SEED -> N JSON objects, one per line, all valid JSON by
# construction (strings are emitted pre-escaped, so the generator can include
# quotes, backslashes and control characters without producing invalid input).
# ---------------------------------------------------------------------------
fz_payloads() {
    awk -v n="${1:-50}" -v seed="${2:-$FUZZ_SEED}" '
    function ri(hi) { return int(rand() * hi) }
    # A JSON string BODY (no surrounding quotes). Every fragment below is already
    # a legal JSON-string element: literal metacharacters that JSON forbids raw
    # ("" and \) appear only as their escape sequences, so what the parser
    # DECODES contains the hostile byte while the generated text stays valid.
    function rstr(   len, i, out) {
        len = ri(28) + 1
        out = ""
        for (i = 0; i < len; i++)
            out = out (ri(3) < 2 ? hostile[ri(nh)] : plain[ri(np)])
        return out
    }
    function rnum(   k) {
        k = ri(7)
        if (k == 0) return "0"
        if (k == 1) return "-1"
        if (k == 2) return ri(1000000)
        if (k == 3) return "1.5e300"
        if (k == 4) return "-1.5e-300"
        if (k == 5) return "9223372036854775807"
        return "-9223372036854775808"
    }
    function rscalar(   k) {
        k = ri(10)
        if (k < 5) return "\"" rstr() "\""
        if (k < 7) return rnum()
        if (k == 7) return "true"
        if (k == 8) return "false"
        return "null"
    }
    function rarr(depth,   i, m, out) {
        m = ri(4); out = ""
        for (i = 0; i < m; i++) out = out (i ? "," : "") rscalar()
        return "[" out "]"
    }
    function robj(depth,   i, m, out, v) {
        m = ri(4) + 1; out = ""
        for (i = 0; i < m; i++) {
            if (depth > 0 && ri(4) == 0)      v = robj(depth - 1)
            else if (depth > 0 && ri(5) == 0) v = rarr(depth - 1)
            else                              v = rscalar()
            out = out (i ? "," : "") "\"" keys[ri(nk)] "\":" v
        }
        return "{" out "}"
    }
    BEGIN {
        srand(seed)
        # 0-BASED and explicit: split() is 1-based, so indexing it with
        # ri(count) silently yields an empty element at 0 and never uses the last.
        i = 0
        hostile[i++] = "\047"          # single quote  - SQL string delimiter
        hostile[i++] = "\\\""          # escaped "     - decodes to a raw quote
        hostile[i++] = "\\\\"          # escaped \\     - decodes to a backslash
        hostile[i++] = ";"
        hostile[i++] = "-"
        hostile[i++] = "/"
        hostile[i++] = "*"
        hostile[i++] = "%"
        hostile[i++] = "_"
        hostile[i++] = "$"
        hostile[i++] = "`"
        hostile[i++] = "|"
        hostile[i++] = "&"
        hostile[i++] = "<"
        hostile[i++] = ">"
        hostile[i++] = "{"
        hostile[i++] = "}"
        hostile[i++] = "["
        hostile[i++] = "]"
        hostile[i++] = "("
        hostile[i++] = ")"
        hostile[i++] = "#"
        hostile[i++] = "@"
        hostile[i++] = "!"
        hostile[i++] = "~"
        hostile[i++] = "^"
        hostile[i++] = "="
        hostile[i++] = "+"
        hostile[i++] = ":"
        hostile[i++] = ","
        hostile[i++] = "."
        hostile[i++] = "?"
        hostile[i++] = "\\n"           # decodes to a newline  - engine framing
        hostile[i++] = "\\t"
        hostile[i++] = "\\r"
        hostile[i++] = "\\u0000"       # rejected by policy at the RPC layer
        hostile[i++] = "\\u0041"
        hostile[i++] = "\\u00e9"
        hostile[i++] = "\\ud83d\\ude00"  # astral pair
        nh = i
        i = 0
        plain[i++] = "a"; plain[i++] = "b"; plain[i++] = "Z"; plain[i++] = "0"
        plain[i++] = "9"; plain[i++] = " "; plain[i++] = "word"; plain[i++] = "value"
        plain[i++] = "AG_DONE"          # the engine terminator token
        plain[i++] = "Error:"           # the old diagnostic prefix
        np = i
        i = 0
        keys[i++] = "k";    keys[i++] = "id";      keys[i++] = "kind"
        keys[i++] = "data"; keys[i++] = "type";    keys[i++] = "payload"
        keys[i++] = "ctx";  keys[i++] = "seq";     keys[i++] = "hash"
        keys[i++] = "a.b";  keys[i++] = "$.x";     keys[i++] = "\\\"q\\\""
        keys[i++] = "\\u0041"; keys[i++] = "x y";  keys[i++] = ""
        keys[i++] = "__proto__"; keys[i++] = "0";  keys[i++] = "-1"
        keys[i++] = "very_long_key_name_that_goes_on_and_on_for_quite_a_while"
        nk = i
        for (j = 0; j < n; j++) print robj(2)
    }' </dev/null
}

# ---------------------------------------------------------------------------
# fz_frames N SEED -> N JSON-RPC-shaped frames: a mix of well-formed requests,
# structurally valid but semantically wrong ones, and mutated text. The point is
# coverage of the DISPATCHER's decision tree, not random noise.
# ---------------------------------------------------------------------------
fz_frames() {
    awk -v n="${1:-50}" -v seed="${2:-$FUZZ_SEED}" '
    function ri(hi) { return int(rand() * hi) }
    function rid(   k) {
        k = ri(6)
        if (k == 0) return "1"
        if (k == 1) return "\"str-id\""
        if (k == 2) return "null"
        if (k == 3) return "{\"obj\":1}"     # invalid per spec
        if (k == 4) return "[1,2]"           # invalid per spec
        return ri(100000)
    }
    function mutate(s,   p, c) {
        p = ri(length(s)) + 1
        c = substr("{}[]\",:\\ \047", ri(9) + 1, 1)
        return substr(s, 1, p - 1) c substr(s, p + 1)
    }
    BEGIN {
        srand(seed)
        nm = split("ag.ping|ag.emit|ag.events|ag.run_start|ag.run_end|ag.fork|ag.stats|ag.graph|ag.explain|ag.diff|ag.wait|ag.project|ag.react|ag.behaviors|ag.insights|ag.cache_lookup|ag.replay|ag.scan|ag.nope|Ag.Ping||__proto__",
                   methods, "|")
        nv = split("2.0|1.0|2|\"2.0\"||3.0", vers, "|")
        for (j = 0; j < n; j++) {
            f = "{\"jsonrpc\":\"" vers[ri(nv) + 1] "\",\"id\":" rid() \
                ",\"method\":\"" methods[ri(nm) + 1] "\""
            k = ri(4)
            if (k == 0) f = f ",\"params\":{}"
            else if (k == 1) f = f ",\"params\":{\"run\":\"r000000000-0000\",\"limit\":" (ri(20000) - 5000) "}"
            else if (k == 2) f = f ",\"params\":[1,2,3]"
            f = f "}"
            if (ri(4) == 0) f = mutate(f)          # corrupt one byte
            print f
        }
    }' </dev/null
}

# ---------------------------------------------------------------------------
# fz_scalars KIND -> boundary values for one validated parameter, as
# "<expect> <value>" lines where <expect> is ok|bad. These are the equivalence
# classes the validator claims to enforce, so a drift in either direction fails.
# ---------------------------------------------------------------------------
fz_scalars() {
    case $1 in
        limit)
            printf 'bad 0\nok 1\nok 2\nok 9999\nok 10000\nbad 10001\nbad -1\nbad abc\nbad 1.5\nbad ""\nbad 1e3\n' ;;
        timeout_ms)
            printf 'ok 0\nok 1\nok 59999\nok 60000\nbad 60001\nbad -1\nbad abc\nbad 1.5\n' ;;
        idem)
            # An EMPTY --idem means "no idempotency key" by design (the insert
            # does nullif(:idem,'')), so it is accepted, not rejected.
            printf 'ok a\nok A-1_2.3\nok %s\nbad %s\nok ""\nbad "has space"\nbad "sql'"'"'quote"\nbad "semi;colon"\n' \
                   "$(printf 'k%.0s' $(seq 1 64))" "$(printf 'k%.0s' $(seq 1 65))" ;;
        actor)
            printf 'ok a\nok llm\nok a-b_c:d.e\nbad A\nbad 1abc\nbad "with space"\nbad ""\nbad %s\n' \
                   "$(printf 'a%.0s' $(seq 1 65))" ;;
        run)
            printf 'bad ""\nbad r1-abcd\nbad r123456789-abcdz\nok r123456789-abcd\nok r1234567890123-0f0f\nbad r12345678901234-abcd\nbad ../etc/passwd\nbad "r123456789-ABCD"\n' ;;
    esac
}
