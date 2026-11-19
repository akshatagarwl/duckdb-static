#!/usr/bin/env python3
"""Print every Nix store path mentioned anywhere in a file, one per line.

Used by package.nix to scrub dead store paths (compiler and header locations
recorded in object files) out of the archive. Reads bytes, so it does not
depend on grep's or the locale's idea of what a binary file is.

Usage: store-refs.py FILE STORE_DIR
"""
import re
import sys

data = open(sys.argv[1], "rb").read()
store = re.escape(sys.argv[2].encode())
found = set(re.findall(store + rb"/[0-9a-z]{32}-[0-9A-Za-z+._?=-]+", data))
# Already scrubbed (remove-references-to writes e…e in place of the hash).
found = {p for p in found if not re.search(rb"/e{32}-", p)}
print("\n".join(sorted(p.decode() for p in found)))
