#!/bin/bash
# Behavioural tests for bounded-run. Usage: bounded-run.test.sh /path/to/bounded-run
set -u
BR=${1:?path to bounded-run}
PY=(/usr/bin/python3 -I -S -B "$BR")
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }
gone() { ! pgrep -f -- "$1" >/dev/null; }
run() { env -i PATH=/usr/bin LC_ALL=C "${PY[@]}" "$@"; }

out=$(run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/echo hi); rc=$?
[ "$out" = hi ] && [ $rc -eq 0 ] && ok "basic output" || bad "basic output" "rc=$rc out=$out"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c 'exit 3'; rc=$?
[ $rc -eq 3 ] && ok "exit status" || bad "exit status" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c 'kill -KILL $$'; rc=$?
[ $rc -eq 137 ] && ok "signal status" || bad "signal status" "rc=$rc"

start=$SECONDS
n=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/yes 2>/dev/null | wc -c); rc=${PIPESTATUS[0]}
[ "$n" -eq 100 ] && [ $((SECONDS - start)) -le 3 ] && ok "stdout cap (n=$n)" || bad "stdout cap" "n=$n t=$((SECONDS - start))"
n=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/yes; echo "rc=$?")
[ "${n##*rc=}" = 201 ] && ok "stdout cap exit 201" || bad "stdout cap exit" "${n##*rc=}"

n=$( { run --stdout-cap 100 --stderr-cap 50 --deadline 10 --grace 1 -- /usr/bin/bash -c 'yes >&2'; echo "rc=$?" >&3; } 3>&1 2>&1 >/dev/null )
rc=${n##*rc=}; body=${n%rc=*}
[ "$rc" = 202 ] && [ ${#body} -eq 50 ] && ok "stderr cap exit 202 (n=${#body})" || bad "stderr cap" "rc=$rc n=${#body}"

start=$SECONDS
run --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/sleep 1001.1; rc=$?
[ $rc -eq 124 ] && [ $((SECONDS - start)) -le 3 ] && gone "sleep 1001.1" && ok "deadline" || bad "deadline" "rc=$rc t=$((SECONDS - start))"

start=$SECONDS
run --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/bash -c 'trap "" TERM; /usr/bin/bash -c "trap \"\" TERM; exec /usr/bin/sleep 1001.2" & wait'; rc=$?
sleep 0.2
[ $rc -eq 124 ] && gone "sleep 1001.2" && [ $((SECONDS - start)) -le 5 ] && ok "TERM-ignoring grandchild killed" || bad "TERM-ignoring grandchild" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c '/usr/bin/setsid /usr/bin/sleep 1001.3 </dev/null >/dev/null 2>&1 & exit 0'; rc=$?
sleep 0.2
[ $rc -eq 0 ] && gone "sleep 1001.3" && ok "setsid-escaped leftover reaped" || bad "setsid-escaped leftover" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/bash -c '( ( /usr/bin/setsid /usr/bin/sleep 1001.4 & ) & ) ; exit 0' >/dev/null 2>&1; rc=$?
sleep 0.2
[ $rc -eq 0 ] && gone "sleep 1001.4" && ok "double-forked daemon reaped" || bad "double-fork" "rc=$rc"

start=$SECONDS
out=$(run --stdout-cap 100 --stderr-cap 100 --deadline 10 --grace 1 -- /usr/bin/bash -c '/usr/bin/sleep 1001.5 & echo done'); rc=$?
[ "$out" = done ] && [ $rc -eq 0 ] && [ $((SECONDS - start)) -le 3 ] && gone "sleep 1001.5" && ok "pipe-holding background does not hang" || bad "pipe holder" "rc=$rc out=$out t=$((SECONDS - start))"

out=$(printf 'secret-over-stdin' | run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/cat)
[ "$out" = secret-over-stdin ] && ok "stdin passthrough" || bad "stdin passthrough" "$out"

out=$(env -i PATH=/usr/bin FOO=bar BASH_ENV=/nonexistent/evil ENV=/x 'BASH_FUNC_ls%%=() { :; }' LD_PRELOAD=/x.so "${PY[@]}" --stdout-cap 1000 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/env)
[ "$out" = "$(printf 'PATH=/usr/bin\nFOO=bar')" ] && ok "environment exact, injection hooks stripped" || bad "env" "$out"

out=$(exec 7</dev/null; run --stdout-cap 1000 --stderr-cap 100 --deadline 5 --grace 1 -- /usr/bin/ls /proc/self/fd | tr '\n' ' ')
[ "$out" = "0 1 2 3 " ] && ok "no inherited fds leak (got: $out)" || bad "fd leak" "$out"

run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- /nonexistent/bin/x 2>/dev/null; rc=$?
[ $rc -eq 127 ] && ok "not found 127" || bad "not found" "rc=$rc"
run --stdout-cap 100 --stderr-cap 100 --deadline 5 --grace 1 -- sleep 1 2>/dev/null; rc=$?
[ $rc -eq 125 ] && ok "relative command refused (no PATH search)" || bad "relative" "rc=$rc"
run --stdout-cap 100 -- /usr/bin/true 2>/dev/null; rc=$?
[ $rc -eq 125 ] && ok "missing options refused" || bad "missing options" "rc=$rc"

run --stdout-cap 100 --stderr-cap 100 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.6 & sup=$!
sleep 0.5; kill -TERM $sup; wait $sup; rc=$?
sleep 0.2
[ $rc -eq 143 ] && gone "sleep 1001.6" && ok "external TERM -> 143, job gone" || bad "external TERM" "rc=$rc"

/usr/bin/setsid /usr/bin/bash -c "env -i PATH=/usr/bin /usr/bin/python3 -I -S -B '$BR' --stdout-cap 10 --stderr-cap 10 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.7 >/dev/null 2>&1 & /usr/bin/sleep 0.5"
sleep 2
gone "sleep 1001.7" && gone "bounded-run.*1001.7" && ok "parent death tears down job" || bad "parent death" "still running"

env -i PATH=/usr/bin LC_ALL=C /usr/bin/python3 -I -S -B "$BR" --stdout-cap 100 --stderr-cap 100 --deadline 0 --grace 1 -- /usr/bin/sleep 1001.9 & sup=$!
sleep 0.5; kill -KILL $sup; wait $sup 2>/dev/null
sleep 0.3
gone "sleep 1001.9" && ok "supervisor SIGKILLed -> command dies by parent-death signal" || bad "supervisor SIGKILL" "command survived"

race=$(dirname "$0")/bounded-run-race.py
if [ -f "$race" ]; then
  if /usr/bin/python3 -I -B "$race" "$BR"; then ok "race harness: no signal to a non-owned or reaped target"; else bad "race harness" "see output above"; fi
fi

# Checks a strace log: every kill() the supervisor makes comes before it reaps
# the leader. Exit 0 ok, 1 violation, 2 nothing usable was traced.
strace_ordering() {
  /usr/bin/python3 -I -S -B - "$1" <<'PY'
import re, sys
calls, pending = [], {}
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"^(\d+)\s+(.*?)\s*$", line)
    if not m:
        continue
    pid, rest = int(m.group(1)), m.group(2)
    resumed = re.match(r"^<\.\.\. (\w+) resumed>(.*)$", rest)
    if resumed:
        index = pending.pop((pid, resumed.group(1)), None)
        if index is not None:
            calls[index][2] += resumed.group(2)
        continue
    call = re.match(r"^(\w+)\(", rest)
    if not call:
        continue  # signal deliveries (---) and exits (+++)
    entry = [pid, call.group(1), rest]
    if rest.endswith("<unfinished ...>"):
        entry[2] = rest[: -len("<unfinished ...>")]
        pending[(pid, call.group(1))] = len(calls)
    calls.append(entry)
if not calls:
    print("strace recorded no calls")
    sys.exit(2)
supervisor = calls[0][0]
spawn = next((c for c in calls if c[0] == supervisor and c[1] in ("clone", "clone3", "fork", "vfork")), None)
returned = re.search(r"= (\d+)$", spawn[2]) if spawn else None
if not returned:
    print("no child creation by the supervisor was traced")
    sys.exit(2)
leader = int(returned.group(1))
reap = next((i for i, c in enumerate(calls)
             if c[0] == supervisor and c[1] == "waitid"
             and re.match(r"waitid\(P_PID, %d," % leader, c[2])
             and "WNOHANG" not in c[2] and "WNOWAIT" not in c[2]
             and re.search(r"= 0$", c[2])), None)
kills = [i for i, c in enumerate(calls) if c[0] == supervisor and c[1] == "kill"]
if reap is None or not kills:
    print("leader %d: reap=%s kills=%d" % (leader, reap, len(kills)))
    sys.exit(1)
late = [calls[i][2] for i in kills if i > reap]
if late:
    print("signal after reaping leader %d: %s" % (leader, late[0]))
    sys.exit(1)
print("%d kill(s), all before reaping leader %d" % (len(kills), leader))
PY
}

strace_bin=$(command -v strace)
if [ -n "$strace_bin" ]; then
  log=$(mktemp)
  env -i PATH=/usr/bin "$strace_bin" -f -qq -o "$log" -e trace=kill,waitid,clone,clone3,fork,vfork "${PY[@]}" --stdout-cap 100 --stderr-cap 100 --deadline 1 --grace 1 -- /usr/bin/bash -c 'trap "" TERM; /usr/bin/sleep 1001.8 & wait' >/dev/null 2>&1
  verdict=$(strace_ordering "$log"); rc=$?
  case $rc in
    0) ok "strace: $verdict"; rm -f "$log" ;;
    2) printf 'skip strace ordering (%s; log=%s)\n' "$verdict" "$log" ;;
    *) bad "strace ordering" "$verdict log=$log" ;;
  esac
else
  printf 'skip strace ordering (strace not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" -eq 0 ]
