#!/usr/bin/env python3 -I
"""Builds Open Arc's phishing list file (plan B234) from a newline-separated host list.

Usage: build_list.py SOURCE ALLOWLIST OUT_FILE

SOURCE: one host per line (Phishing.Database's phishing-domains-ACTIVE.txt); blank lines and
lines starting with '#' are skipped. ALLOWLIST: hosts never flagged (big platforms whose own host
must not end up on the list by mistake), same format. OUT_FILE gets the format PhishingList.swift
reads: "OAPH", UInt32 format 1, UInt64 count, count x UInt64 keys (first 8 bytes of SHA-256 of
the lowercase host), sorted, all big-endian. Prints the version (<yyyymmdd>-<12 hex of the file's
SHA-256>) on stdout and counts on stderr.
"""
import hashlib
import struct
import sys
import time


def hosts(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            host = line.strip().lower().rstrip(".")
            if host and not host.startswith("#") and " " not in host and "/" not in host:
                yield host


def main():
    source, allowlist, out = sys.argv[1:4]
    allowed = set(hosts(allowlist))
    keys, dropped, total = set(), 0, 0
    for host in hosts(source):
        total += 1
        bare = host[4:] if host.startswith("www.") else host
        if host in allowed or bare in allowed:
            dropped += 1
            continue
        keys.add(struct.unpack(">Q", hashlib.sha256(host.encode()).digest()[:8])[0])
    data = b"OAPH" + struct.pack(">IQ", 1, len(keys)) + b"".join(struct.pack(">Q", k) for k in sorted(keys))
    with open(out, "wb") as f:
        f.write(data)
    print(f"{total} hosts read, {dropped} on the allowlist, {len(keys)} keys", file=sys.stderr)
    print(time.strftime("%Y%m%d", time.gmtime()) + "-" + hashlib.sha256(data).hexdigest()[:12])


if __name__ == "__main__":
    main()
