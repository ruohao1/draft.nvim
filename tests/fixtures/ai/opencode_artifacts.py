"""Recorded OpenCode 1.18.28 empty compatibility artifacts (Linux, 2026-09-06).

Captured only after all 12 production probes passed, in a network namespace with
an empty HOME and the real home hidden. No credentials or sessions were present.
The database, SHM and WAL are compressed data, not executable/pickled objects.
Replay refreshes only audited volatile timestamps and the SQLite checksums they
affect; the production validator still checks the immutable bytes and schema.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import time
import zlib


_RECORDED = {
    "database": (
        4096,
        "40cf07c52bfaa52b334ef341456f970787f6dc701ffe18ad3c572cb5056dbd70",
        "eNoLDvTJLElVSMsvyk0sUTBmEGBgYmJwUFBgYGBghGJKACOD3tQTvCCWAMMoGAWjYBSMglEwCkbBKBgFo2AUjIJRMAoGCAAA"
        "E3sHbg=="
    ),
    "shm": (
        32768,
        "8781d21e6d62e66d9fca0f2777e41a7f33a010a1b72496e97b2b6261a1e90781",
        "eNrt3Mkuw3EYheF/1Ty2NZWaS9VYap6tLS3tXYF7kNi4DYn7sHEFVhZiTeIGOJVKxMax/OR9kjfdNM2X89s3/7SU1DSoVJJk"
        "jvR5oK4fXt6qx6c3V/c3F8+P57eFu9fL9MnZeP6P30/qat97/yb5IVX/zbRqVE2qWbWoVtWm2lWH6lRdqlv1qIzKqpzqVX2q"
        "Xw2oQZVXQ2pYFdSIGlVjqnbghJpUU6qoptWMKqlZVVZzal4tqEVVW2FZVdSKWlVVtabW1YbaVFtqW+2oXbWn9uubfd0GAAAA"
        "AAAAAAAAAAAAAAAAAAAAAAAAAEAcC0xgGmACUyrMpYs8lmkwOWQES0OYS5d4LFP+85928Lt0mEuXeSzTEBOYGsNcWuGxTMNM"
        "YGoKc+kKj2UqMIGpOcylqzyWaYQJTC1hLq3yWKZRJjC1hrl0jccyjTGBqS3Mpes8lmmcCUztYS7d4LFME0xg6ghz6SaPZZpk"
        "AlNnmEu3eCzTFBOYusJcus1jmYpMYOoOc+kOj2WaZgJTT5hLd3ks0wwTmDJhLt3jsUwlJjBlw1y6z2OZZpnAlAtz6QGPZSoz"
        "gamXCf6dOSYw9THBvzPPBKZ+JjB9AKgCOSY="
    ),
    "wal": (
        259592,
        "6b6a789e9f7d24f70e39762fbee270049710671e9106d1d6fda2285e25e514cd",
        "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"
    ),
}

# One-based offsets in the audited external SQLite WAL format.
_TIMESTAMP_OFFSETS = (
    245568, 245616, 245672, 245718, 245756, 245792, 245841, 245895,
    245948, 245995, 246040, 246098, 246158, 246207, 246249, 246290,
    246339, 246381, 246427, 246466, 246510, 246550, 246586, 246628,
    246668, 246715, 246756, 246796, 246828, 246876, 246919, 246965,
    247003, 247053, 247088, 247135, 247181, 247227, 255459, 255465,
)


def _recorded(name):
    size, digest, compressed = _RECORDED[name]
    data = zlib.decompress(base64.b64decode(compressed, validate=True))
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        raise AssertionError("recorded OpenCode artifact changed")
    return data


def _sqlite_checksum(data, first=0, second=0):
    for word0, word1 in struct.iter_unpack("<II", data):
        first = (first + word0 + second) & 0xFFFFFFFF
        second = (second + word1 + first) & 0xFFFFFFFF
    return first, second


def replay_opencode_artifacts(semantic):
    if os.environ.get("HOME") != "/tmp/nvim-ai-probe/home":
        raise AssertionError("artifact replay requires the private compatibility probe")
    roots = {}
    for kind in ("DATA", "CACHE", "STATE"):
        expected = f"/tmp/nvim-ai-probe/xdg-{kind.lower()}"
        if os.environ.get(f"XDG_{kind}_HOME") != expected:
            raise AssertionError("artifact replay escaped the private XDG probe")
        roots[kind] = Path(expected) / "opencode"
    for path in (*roots.values(), roots["DATA"] / "log", roots["DATA"] / "repos", roots["CACHE"] / "bin"):
        path.mkdir(mode=0o700, exist_ok=True)
    if not semantic:
        return
    # Use the audited complete quiescent lock form. The retained-artifact audit
    # restores this same public format after testing every transient lock shape.
    lock = roots["STATE"] / "locks" / "0a009c556ac8352fed53ef8323a3a97270935d30.lock"
    lock.parent.mkdir(mode=0o700)
    lock.mkdir(mode=0o700)
    metadata = json.dumps({
        "token": "00112233-4455-4677-8899-aabbccddeeff",
        "pid": 2,
        "hostname": os.uname().nodename,
        "createdAt": "2026-08-27T12:00:00.000Z",
    }, indent=2)
    for name, content in (("heartbeat", ""), ("meta.json", metadata)):
        with (lock / name).open("x") as output:
            output.write(content)
        (lock / name).chmod(0o600)
    wal, shm = bytearray(_recorded("wal")), bytearray(_recorded("shm"))
    timestamp = int(time.time() * 1000).to_bytes(6, "big")
    for offset in _TIMESTAMP_OFFSETS:
        wal[offset - 1:offset + 5] = timestamp
    checksum = _sqlite_checksum(wal[:24])
    struct.pack_into(">II", wal, 24, *checksum)
    for frame in range(63):
        start = 32 + frame * 4120
        checksum = _sqlite_checksum(wal[start:start + 8], *checksum)
        checksum = _sqlite_checksum(wal[start + 24:start + 4120], *checksum)
        struct.pack_into(">II", wal, start + 16, *checksum)
    struct.pack_into("<II", shm, 24, *checksum)
    struct.pack_into("<II", shm, 40, *_sqlite_checksum(shm[:40]))
    shm[48:96] = shm[:48]
    for name, data in (("opencode.db", _recorded("database")), ("opencode.db-wal", wal), ("opencode.db-shm", shm), ("log/opencode.log", b"")):
        path = roots["DATA"] / name
        with path.open("xb") as output:
            output.write(data)
        path.chmod(0o600)
