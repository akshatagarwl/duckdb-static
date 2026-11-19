#!/usr/bin/env python3
"""Print every Nix store path whose hash appears anywhere in a file.

Matches the way Nix itself finds references: by the bare 32-character hash,
whatever surrounds it. (On macOS some paths are recorded without the
/nix/store/ prefix in front of the hash.) A hash counts if a store path with
it exists, i.e. it is one of the build's inputs. Reads bytes, so it does not
depend on grep's or the locale's idea of a binary file. Context for each match
goes to stderr, for the build log.

Usage: store-refs.py FILE STORE_DIR
"""
import glob
import os
import re
import sys

path, store = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
# Nix's base32 alphabet: digits and lowercase letters except e, o, u, t.
candidates = set(re.findall(rb"[0-9a-df-np-sv-z]{32}", data))

found = {}
for h in candidates:
    for p in glob.glob(os.path.join(store, h.decode() + "-*")):
        found[p] = h
for p, h in sorted(found.items()):
    i = data.find(h)
    context = data[max(0, i - 40) : i + 72].decode("latin-1").encode("unicode_escape").decode()
    print(f"store-refs: {os.path.basename(p)} at byte {i}: ...{context}...", file=sys.stderr)
    print(p)
