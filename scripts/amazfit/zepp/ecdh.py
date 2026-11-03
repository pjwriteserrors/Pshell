"""ECDH on NIST B-163 (sect163r2), the curve Zepp OS authenticates with.

Keys travel the way tiny-ECDH lays them out: a private key of 24 bytes and a
public key of 48 (x then y), each coordinate six little-endian 32-bit words.
Field elements are Python ints: bit i is the coefficient of x^i.
"""

DEGREE = 163
# x^163 + x^7 + x^6 + x^3 + 1
POLY = (1 << 163) | (1 << 7) | (1 << 6) | (1 << 3) | 1
B = 0x20A601907B8C953CA1481EB10512F78744A3205FD
GX = 0x3F0EBA16286A2D57EA0991168D4994637E8343E36
GY = 0x0D51FBC6C71A0094FA2CDD545B11C5C0C797324F1
ORDER = 0x40000000000000000000292FE77E70C12A4234C33
KEY_BYTES = 24


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        b >>= 1
        a <<= 1
        if a >> DEGREE:
            a ^= POLY
    return r


def _inv(a):
    # extended Euclid over GF(2)[x]
    u, v, g1, g2 = a, POLY, 1, 0
    while u != 1:
        j = u.bit_length() - v.bit_length()
        if j < 0:
            u, v, g1, g2 = v, u, g2, g1
            j = -j
        u ^= v << j
        g1 ^= g2 << j
    return g1


def _double(p):
    if p is None or p[0] == 0:
        return None
    x, y = p
    lam = x ^ _mul(y, _inv(x))
    x3 = _mul(lam, lam) ^ lam ^ 1          # a = 1
    y3 = _mul(x, x) ^ _mul(lam, x3) ^ x3
    return (x3, y3)


def _add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0]:
        return _double(p) if p[1] == q[1] else None
    lam = _mul(p[1] ^ q[1], _inv(p[0] ^ q[0]))
    x3 = _mul(lam, lam) ^ lam ^ p[0] ^ q[0] ^ 1
    y3 = _mul(lam, p[0] ^ x3) ^ x3 ^ p[1]
    return (x3, y3)


def _scalar(k, p):
    r = None
    for i in range(k.bit_length() - 1, -1, -1):
        r = _double(r)
        if (k >> i) & 1:
            r = _add(r, p)
    return r


def on_curve(x, y):
    # y^2 + xy = x^3 + x^2 + b
    return _mul(y, y) ^ _mul(x, y) == _mul(_mul(x, x), x) ^ _mul(x, x) ^ B


def _scalar_of(private):
    k = int.from_bytes(private, "little")
    # tiny-ECDH clears every bit from degree(order) - 1 up
    return k & ((1 << (ORDER.bit_length() - 1)) - 1)


def _point_bytes(p):
    return p[0].to_bytes(KEY_BYTES, "little") + p[1].to_bytes(KEY_BYTES, "little")


def public_key(private):
    """48 bytes, or None when the random private key is too small (as tiny-ECDH)."""
    if int.from_bytes(private, "little").bit_length() < DEGREE // 2:
        return None
    return _point_bytes(_scalar(_scalar_of(private), (GX, GY)))


def shared_secret(private, remote):
    """48 bytes (x, y), or None when the remote key is not on the curve."""
    x = int.from_bytes(remote[:KEY_BYTES], "little")
    y = int.from_bytes(remote[KEY_BYTES:2 * KEY_BYTES], "little")
    if (x == 0 and y == 0) or not on_curve(x, y):
        return None
    return _point_bytes(_scalar(_scalar_of(private), (x, y)))
