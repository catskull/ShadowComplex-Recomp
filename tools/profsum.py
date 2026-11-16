#!/usr/bin/env python3
"""Summarize a macOS `sample` call tree: per-thread busy samples and hottest leaf functions
(guest F_<addr> names are mapped back to the game's symbols).

usage: profsum.py BINARY SAMPLE.txt
"""
import collections, os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from macho import Image

WAIT = re.compile(r"__psynch_cvwait|__semwait_signal|semaphore_wait|mach_msg|__workq_kernreturn|start_wqthread|"
                  r"__select|kevent|__ulock_wait|nanosleep|usleep|iokit_user_client_trap|__psynch_mutexwait")
LINE = re.compile(r"^([ +!:|]*)(\d+) (.+?)  \(in ([^)]+)\)")

def main():
    img = Image(sys.argv[1])
    lines = open(sys.argv[2]).read().split("Total number in stack")[0].splitlines()
    threads, cur = [], None
    for ln in lines:
        m = re.match(r"^\s+(\d+) (Thread_\d+.*)$", ln)
        if m:
            cur = {"name": m.group(2).strip(), "total": int(m.group(1)), "nodes": []}
            threads.append(cur); continue
        m = LINE.match(ln)
        if m and cur is not None:
            cur["nodes"].append((len(m.group(1)), int(m.group(2)), m.group(3), m.group(4)))
    def name(sym):
        m = re.match(r"F_([0-9a-f]+)", sym)
        if not m: return sym
        n = img.func_names.get(int(m.group(1), 16), sym)
        return n[:110]
    for t in threads:
        nodes = t["nodes"]
        # self time per node = count - sum(children counts)
        leaf = collections.Counter(); waiting = 0
        for k, (d, cnt, sym, lib) in enumerate(nodes):
            child = 0
            for d2, c2, _, _ in nodes[k + 1:]:
                if d2 <= d: break
                if d2 == d + 2 or (child == 0 and d2 > d): pass
            # children are the following nodes with the next indentation level until depth returns
            j, nd = k + 1, None
            while j < len(nodes) and nodes[j][0] > d:
                if nd is None: nd = nodes[j][0]
                if nodes[j][0] == nd: child += nodes[j][1]
                j += 1
            self_ = cnt - child
            if self_ > 0:
                if WAIT.search(sym): waiting += self_
                else: leaf[name(sym)] += self_
        busy = sum(leaf.values())
        if busy < 200: continue
        print("\n%s  busy %d of %d samples (%.0f%%)" % (t["name"][:60], busy, t["total"], 100.0 * busy / t["total"]))
        for s, c in leaf.most_common(14):
            print("   %5d  %5.1f%%  %s" % (c, 100.0 * c / busy, s))

main()
