#!/usr/bin/python3
"""Race-freedom check for bin/bounded-run.

Loads the supervisor as a module, wraps os.kill / os.killpg / os.waitid, and
runs it against process trees that exit early, ignore SIGTERM, escape into
their own sessions, or flood output — while unrelated same-UID process groups
churn next to it. For every signal the supervisor sends it asserts:

  - killpg() names only the original leader, and only while the leader is
    still this supervisor's unreaped child (so its PID/PGID is still
    allocated to it and cannot have been reused);
  - kill() names only a process that is still this supervisor's own
    unreaped child;
  - nothing at all is signalled once the leader has been reaped;

and afterwards that the supervisor has no child left and that the unrelated
sentinel groups were never touched.

Usage: bounded-run-race.py /path/to/bounded-run [rounds]
"""

import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys

BASH = "/usr/bin/bash"
SLEEP = "/usr/bin/sleep"

SCENARIOS = [
    ("fast exit", ["/usr/bin/true"], dict(), {0}),
    ("leftover in the group", [BASH, "-c", SLEEP + " 30 & exit 0"], dict(), {0}),
    ("leftover in its own session", [BASH, "-c", "/usr/bin/setsid " + SLEEP + " 30 </dev/null >/dev/null 2>&1 & exit 0"], dict(), {0}),
    ("double-forked daemon", [BASH, "-c", "( ( " + SLEEP + " 30 & ) & ); exit 0"], dict(), {0}),
    ("leader exits, TERM-ignoring children stay", [BASH, "-c", "trap '' TERM; for i in 1 2 3 4 5 6; do " + SLEEP + " 30 & done; exit 3"], dict(), {3}),
    ("TERM-ignoring tree hits the deadline", [BASH, "-c", "trap '' TERM; " + BASH + " -c \"trap '' TERM; " + SLEEP + " 30\" & wait"], dict(deadline=1), {124}),
    ("stdout flood hits the cap", ["/usr/bin/yes"], dict(stdout_cap=100), {201}),
    ("supervisor told to stop", [BASH, "-c", "kill -TERM $PPID; " + SLEEP + " 30"], dict(), {143}),
]


def load(path):
    loader = importlib.machinery.SourceFileLoader("bounded_run", path)
    spec = importlib.util.spec_from_loader("bounded_run", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def run_scenario(br, argv, stdout_cap=1000, stderr_cap=1000, deadline=10, grace=1):
    result_r, result_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(result_r)
        null_out = os.open("/dev/null", os.O_WRONLY)
        null_in = os.open("/dev/null", os.O_RDONLY)
        os.dup2(null_in, 0)
        os.dup2(null_out, 1)
        os.dup2(null_out, 2)
        log = {"signals": 0, "violations": []}
        sup = br.Supervisor(stdout_cap, stderr_cap, deadline, grace, argv)
        reaped = set()
        real_kill, real_killpg, real_waitid = os.kill, os.killpg, os.waitid

        def unreaped_child(target):
            try:
                real_waitid(os.P_PID, target, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                return True
            except ChildProcessError:
                return False

        def killpg(pgid, signum):
            log["signals"] += 1
            if pgid != sup.leader or sup.leader in reaped or not unreaped_child(pgid):
                log["violations"].append("killpg(%d, %d): leader=%s reaped=%s" % (pgid, signum, sup.leader, sup.leader in reaped))
            return real_killpg(pgid, signum)

        def kill(target, signum):
            log["signals"] += 1
            if sup.leader in reaped or not unreaped_child(target):
                log["violations"].append("kill(%d, %d): not an unreaped child, or after the leader was reaped" % (target, signum))
            return real_kill(target, signum)

        def waitid(idtype, ident, options):
            info = real_waitid(idtype, ident, options)
            if info is not None and not options & os.WNOWAIT:
                reaped.add(info.si_pid)
            return info

        os.kill, os.killpg, os.waitid = kill, killpg, waitid
        try:
            log["status"] = sup.run()
        except BaseException as error:  # noqa: BLE001 - report anything
            log["status"] = None
            log["violations"].append("run() raised %r" % (error,))
        os.kill, os.killpg, os.waitid = real_kill, real_killpg, real_waitid
        left = sup.own_children()
        if left:
            log["violations"].append("children left behind: %s" % left)
        data = json.dumps(log).encode()
        while data:
            data = data[os.write(result_w, data):]
        os._exit(0)
    os.close(result_w)
    chunks = []
    while True:
        chunk = os.read(result_r, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(result_r)
    os.waitpid(pid, 0)
    try:
        return json.loads(b"".join(chunks))
    except ValueError:
        return {"signals": 0, "status": None, "violations": ["harness child died before reporting"]}


def main():
    br = load(sys.argv[1])
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    # Unrelated same-UID process groups: long-lived sentinels, plus a loop
    # that keeps creating and discarding short-lived groups to cycle PIDs.
    sentinels = [subprocess.Popen(["/usr/bin/setsid", SLEEP, "600"]) for _ in range(4)]
    churn = subprocess.Popen([BASH, "-c", "while :; do /usr/bin/setsid /usr/bin/true; done"],
                             start_new_session=True)
    failures = 0
    signals = 0
    try:
        for round_number in range(rounds):
            for name, argv, options, expected in SCENARIOS:
                log = run_scenario(br, argv, **options)
                signals += log["signals"]
                problems = list(log["violations"])
                if log["status"] not in expected:
                    problems.append("status %s, expected %s" % (log["status"], sorted(expected)))
                if problems:
                    failures += 1
                    print("FAIL race round %d: %s -- %s" % (round_number + 1, name, "; ".join(problems)))
    finally:
        os.killpg(churn.pid, 15)
        churn.wait()
    for sentinel in sentinels:
        if sentinel.poll() is not None:
            failures += 1
            print("FAIL race: unrelated sentinel group %d was signalled (status %s)" % (sentinel.pid, sentinel.returncode))
        sentinel.kill()
        sentinel.wait()
    if signals == 0:
        failures += 1
        print("FAIL race: no signal was sent at all, so nothing was checked")
    print("race harness: %d scenarios x %d rounds, %d signals checked, %d failures"
          % (len(SCENARIOS), rounds, signals, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
