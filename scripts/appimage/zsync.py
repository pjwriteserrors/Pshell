"""zsync: a new version of a file from the blocks an old one already has.

A `.zsync` file (made by zsyncmake, shipped beside many AppImages) lists the
new file block by block: a rolling checksum and the start of an MD4 of each.
Every place in the old file is checked against them (numpy does it for all
places at once); what is found is copied, only the rest is asked of the
server with range requests, and the whole is checked against the SHA-1 the
.zsync names. Anything amiss raises, and the caller downloads it whole.

    update(zsync_url, file_url, old_path, out_path, progress) -> figures
"""
from __future__ import annotations

import ctypes
import ctypes.util
import hashlib
import mmap
import os
import struct
import threading
import urllib.parse
import urllib.request

# the old file is looked through in windows this big (memory stays small)
WINDOW = 2 << 20
# runs of missing blocks closer than this are fetched together
MERGE = 8
CONNECTIONS = 4
USER_AGENT = "Pshell-AppImages/1.0"


# ── MD4 (OpenSSL 3 leaves it out of hashlib) ─────────────────────────────────
def _rotl(value, shift):
    value &= 0xFFFFFFFF
    return ((value << shift) | (value >> (32 - shift))) & 0xFFFFFFFF


def _openssl_md4():
    """MD4 from OpenSSL's legacy provider through ctypes, ~200× the pure one."""
    try:
        lib = ctypes.CDLL(ctypes.util.find_library("crypto") or "libcrypto.so.3")
        lib.OSSL_PROVIDER_load.restype = ctypes.c_void_p
        lib.OSSL_PROVIDER_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        if not lib.OSSL_PROVIDER_load(None, b"legacy"):
            return None
        lib.EVP_MD_fetch.restype = ctypes.c_void_p
        lib.EVP_MD_fetch.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        digest = lib.EVP_MD_fetch(None, b"MD4", None)
        if not digest:
            return None
        lib.EVP_Digest.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint), ctypes.c_void_p, ctypes.c_void_p]
        def fast(data: bytes) -> bytes:
            # a buffer of its own each time: the windows are looked through in threads
            out = ctypes.create_string_buffer(16)
            lib.EVP_Digest(data, len(data), out, None, digest, None)
            return out.raw

        return fast if fast(b"abc").hex() == "a448017aaf21d8525fc10ae87aa6729d" else None
    except (OSError, AttributeError):
        return None


def md4(data: bytes) -> bytes:
    return _FAST(data) if _FAST else md4_pure(data)


def md4_pure(data: bytes) -> bytes:
    a, b, c, d = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476
    length = len(data) * 8
    data = data + b"\x80" + b"\0" * ((55 - len(data)) % 64) + struct.pack("<Q", length)
    for at in range(0, len(data), 64):
        x = struct.unpack("<16I", data[at:at + 64])
        aa, bb, cc, dd = a, b, c, d
        f = lambda x_, y, z: (x_ & y) | (~x_ & z)
        for i in range(16):
            s = (3, 7, 11, 19)[i % 4]
            if i % 4 == 0:
                a = _rotl(a + f(b, c, d) + x[i], s)
            elif i % 4 == 1:
                d = _rotl(d + f(a, b, c) + x[i], s)
            elif i % 4 == 2:
                c = _rotl(c + f(d, a, b) + x[i], s)
            else:
                b = _rotl(b + f(c, d, a) + x[i], s)
        g = lambda x_, y, z: (x_ & y) | (x_ & z) | (y & z)
        for i, k in enumerate((0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15)):
            s = (3, 5, 9, 13)[i % 4]
            if i % 4 == 0:
                a = _rotl(a + g(b, c, d) + x[k] + 0x5A827999, s)
            elif i % 4 == 1:
                d = _rotl(d + g(a, b, c) + x[k] + 0x5A827999, s)
            elif i % 4 == 2:
                c = _rotl(c + g(d, a, b) + x[k] + 0x5A827999, s)
            else:
                b = _rotl(b + g(c, d, a) + x[k] + 0x5A827999, s)
        h = lambda x_, y, z: x_ ^ y ^ z
        for i, k in enumerate((0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15)):
            s = (3, 9, 11, 15)[i % 4]
            if i % 4 == 0:
                a = _rotl(a + h(b, c, d) + x[k] + 0x6ED9EBA1, s)
            elif i % 4 == 1:
                d = _rotl(d + h(a, b, c) + x[k] + 0x6ED9EBA1, s)
            elif i % 4 == 2:
                c = _rotl(c + h(d, a, b) + x[k] + 0x6ED9EBA1, s)
            else:
                b = _rotl(b + h(c, d, a) + x[k] + 0x6ED9EBA1, s)
        a, b, c, d = (a + aa) & 0xFFFFFFFF, (b + bb) & 0xFFFFFFFF, (c + cc) & 0xFFFFFFFF, (d + dd) & 0xFFFFFFFF
    return struct.pack("<4I", a, b, c, d)


_FAST = _openssl_md4()


# ── the .zsync file ──────────────────────────────────────────────────────────
def parse(data: bytes):
    """(header fields, [(rsum, checksum)] per block)."""
    head, _, body = data.partition(b"\n\n")
    fields = {}
    for line in head.decode("utf-8", "replace").splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value.strip()
    size = int(fields["Length"])
    block = int(fields["Blocksize"])
    seq, rsum_bytes, check_bytes = (int(part) for part in fields.get("Hash-Lengths", "1,4,16").split(","))
    count = (size + block - 1) // block
    step = rsum_bytes + check_bytes
    if len(body) < count * step:
        raise ValueError("The .zsync file is cut short")
    blocks = []
    for i in range(count):
        record = body[i * step:(i + 1) * step]
        blocks.append((int.from_bytes(record[:rsum_bytes], "big"), record[rsum_bytes:]))
    fields.update(size=size, block=block, seq=seq, rsum_bytes=rsum_bytes, check_bytes=check_bytes)
    return fields, blocks


def _rsum_mask(rsum_bytes):
    # zsync keeps the last rsum_bytes of a<<16|b
    return (1 << (8 * rsum_bytes)) - 1


def find(old, fields, blocks):
    """Where in `old` (bytes or an mmap) each block of the new file is: {block: offset}."""
    import numpy as np

    size, B = fields["size"], fields["block"]
    mask = _rsum_mask(fields["rsum_bytes"])
    whole = size // B  # the last, short block is never looked for
    pairs = fields["seq"] >= 2
    by_key = {}
    if pairs:
        # a block and the one after it must both fit: two sums are far fewer false hits
        for i in range(whole - 1):
            by_key.setdefault((blocks[i][0] << 32) | blocks[i + 1][0], []).append(i)
    else:
        for i in range(whole):
            by_key.setdefault(blocks[i][0], []).append(i)
    keys = np.sort(np.fromiter(by_key.keys(), dtype=np.int64))
    checks = fields["check_bytes"]
    found = {}
    lock = threading.Lock()
    reach = B * (2 if pairs else 1)

    def window(start):
        piece = old[start:start + WINDOW + reach - 1]
        # only the low 16 bits count: 32-bit sums that wrap around are as good and half the memory
        data = np.frombuffer(piece, dtype=np.uint8).astype(np.uint32)
        c1 = np.zeros(len(data) + 1, dtype=np.uint32)
        np.cumsum(data, out=c1[1:])
        c2 = np.zeros(len(data) + 1, dtype=np.uint32)
        np.cumsum(data * np.arange(len(data), dtype=np.uint32), out=c2[1:])
        n = len(data) - B + 1
        sums = c1[B:B + n] - c1[:n]
        k = np.arange(n, dtype=np.uint32)
        b = (np.uint32(B) * sums - ((c2[B:B + n] - c2[:n]) - k * sums)) & np.uint32(0xFFFF)
        weak = (((sums & np.uint32(0xFFFF)).astype(np.int64) << 16) | b.astype(np.int64)) & mask
        if pairs:
            if len(weak) <= B:
                return
            weak = (weak[:-B] << 32) | weak[B:]
        weak = weak[:WINDOW]
        place = np.searchsorted(keys, weak)
        place[place >= len(keys)] = 0
        hits = np.nonzero(keys[place] == weak)[0]
        for at in hits.tolist():
            # also blocks found elsewhere already: their neighbour may only be found here
            with lock:
                candidates = [i for i in by_key.get(int(weak[at]), []) if i not in found or (i + 1 < whole and i + 1 not in found)]
            if not candidates:
                continue
            offset = start + at
            digest = md4(old[offset:offset + B])[:checks]
            for i in candidates:
                if blocks[i][1] == digest:
                    with lock:
                        found.setdefault(i, offset)
                    # its neighbour fits by its sum: one MD4 more tells
                    j = i + 1
                    if j < whole and offset + 2 * B <= len(old) and blocks[j][1] == md4(old[offset + B:offset + 2 * B])[:checks]:
                        with lock:
                            found.setdefault(j, offset + B)

    starts = list(range(0, max(0, len(old) - reach + 1), WINDOW))
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max(1, min(8, (os.cpu_count() or 2) // 2))) as pool:
        list(pool.map(window, starts))
    return found


def missing_ranges(fields, found):
    """The byte ranges of the new file nothing was found for, close ones together."""
    size, B = fields["size"], fields["block"]
    count = (size + B - 1) // B
    runs = []
    for i in range(count):
        if i in found:
            continue
        if runs and i - runs[-1][1] <= MERGE:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    return [(first * B, min(size, (last + 1) * B) - 1) for first, last in runs]


# ── fetching ────────────────────────────────────────────────────────────────
def _get(url, headers=None):
    request = urllib.request.Request(url, headers=dict({"User-Agent": USER_AGENT}, **(headers or {})))
    return urllib.request.urlopen(request, timeout=30)


def plan(zsync_url, old_path):
    """The .zsync and where its blocks are in the old file: (fields, blocks, found)."""
    with _get(zsync_url) as answer:
        fields, blocks = parse(answer.read())
    with open(old_path, "rb") as old_file:
        old = mmap.mmap(old_file.fileno(), 0, access=mmap.ACCESS_READ)
        try:
            found = find(old, fields, blocks)
        finally:
            old.close()
    return fields, blocks, found


def still_needed(fields, found, have=0):
    """The ranges to fetch when the first `have` bytes are there already, and their bytes."""
    ranges = []
    for start, end in missing_ranges(fields, found):
        if end < have:
            continue
        ranges.append((max(start, have), end))
    return ranges, sum(end - start + 1 for start, end in ranges)


def build(planned, file_url, old_path, out_path, have_path=None, have=0, progress=None):
    """The new file at `out_path` from the old one, the first `have` bytes of
    `have_path` and range requests for the rest; checked by its SHA-1."""
    fields, blocks, found = planned
    size, B = fields["size"], fields["block"]
    ranges, need = still_needed(fields, found, have)
    # where the link leads (a release asset redirects to a signed address): asked once
    with _get(file_url, {"Range": "bytes=0-0"}) as answer:
        final = answer.geturl()
        if answer.status != 206:
            raise OSError("The server sends no parts")
    temp = out_path + ".delta"
    fd = os.open(temp, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o755)
    old_file = open(old_path, "rb")
    old = mmap.mmap(old_file.fileno(), 0, access=mmap.ACCESS_READ)
    try:
        os.ftruncate(fd, size)
        for i, at in found.items():
            os.pwrite(fd, old[at:at + B], i * B)
        if have and have_path:
            with open(have_path, "rb") as head:
                at = 0
                while at < have:
                    chunk = head.read(min(1 << 20, have - at))
                    if not chunk:
                        break
                    os.pwrite(fd, chunk, at)
                    at += len(chunk)
        lock = threading.Lock()
        state = {"done": 0, "error": None}
        queue = list(ranges)

        def worker():
            while True:
                with lock:
                    if not queue or state["error"]:
                        return
                    start, end = queue.pop(0)
                try:
                    with _get(final, {"Range": f"bytes={start}-{end}"}) as answer:
                        got = answer.headers.get("Content-Range", "")
                        if answer.status != 206 or not got.startswith(f"bytes {start}-"):
                            raise OSError(f"The server sent another part ({answer.status})")
                        at = start
                        while at <= end:
                            chunk = answer.read(min(1 << 16, end - at + 1))
                            if not chunk:
                                raise OSError("The connection closed early")
                            os.pwrite(fd, chunk, at)
                            at += len(chunk)
                            with lock:
                                state["done"] += len(chunk)
                                if progress:
                                    progress(state["done"], need)
                except Exception as error:  # noqa: BLE001 – any failure: the whole file instead
                    with lock:
                        state["error"] = error
                    return

        threads = [threading.Thread(target=worker, daemon=True) for _ in range(min(CONNECTIONS, len(ranges)))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        if state["error"]:
            raise state["error"]
        os.fsync(fd)
    finally:
        os.close(fd)
        old.close()
        old_file.close()
    digest = hashlib.sha1()
    with open(temp, "rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    if fields.get("SHA-1") and digest.hexdigest() != fields["SHA-1"].lower():
        os.unlink(temp)
        raise OSError("The pieces do not make the new file")
    os.replace(temp, out_path)
    return {"size": size, "reused": size - need - have, "had": have, "fetched": need, "requests": len(ranges)}


def update(zsync_url, file_url, old_path, out_path, progress=None):
    """The new file at `out_path` from the old one and what is missing; its figures."""
    return build(plan(zsync_url, old_path), file_url, old_path, out_path, progress=progress)
