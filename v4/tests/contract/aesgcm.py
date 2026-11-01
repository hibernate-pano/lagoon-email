#!/usr/bin/env python3
"""Minimal AES-256-GCM, standard library only.

Why this exists: the contract fixtures must include a *sealed* body and a
*sealed* draft, because those are the rows the v3 server stores at rest. The
server writes them with CryptoKit's AES.GCM (12-byte nonce, ciphertext, then the
16-byte tag, base64ed behind the "lgb1:" envelope), and this project forbids
both network access and third-party Python packages. So the harness carries its
own AES-256-GCM.

Scope: encryption only (the harness never decrypts), one 96-bit nonce, no AAD.
Correctness is checked two ways:
  1. test_vectors() runs the NIST empty-plaintext vector;
  2. end-to-end: capture-contract.sh seeds a sealed body and the v3 server's
     /api/messages/:id/body answers 200 with the exact plaintext - if the
     implementation were wrong, CryptoKit's open would fail and the route would
     answer 503 instead.

This is not a general-purpose crypto library; do not reuse it for anything but
fixture generation.
"""

from __future__ import annotations

SBOX = bytes((
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
))

RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d)


def _xtime(a: int) -> int:
    a <<= 1
    return (a ^ 0x11B) & 0xFF if a & 0x100 else a


def _mul(a: int, b: int) -> int:
    out = 0
    for _ in range(8):
        if b & 1:
            out ^= a
        a = _xtime(a)
        b >>= 1
    return out


def _expand_key(key: bytes) -> list:
    """AES-256 key schedule: 8-word key, 60 words of round key."""
    if len(key) != 32:
        raise ValueError("AES-256 needs a 32-byte key")
    words = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    for i in range(8, 60):
        temp = list(words[i - 1])
        if i % 8 == 0:
            temp = temp[1:] + temp[:1]
            temp = [SBOX[b] for b in temp]
            temp[0] ^= RCON[i // 8 - 1]
        elif i % 8 == 4:
            temp = [SBOX[b] for b in temp]
        words.append([words[i - 8][j] ^ temp[j] for j in range(4)])
    return [sum(words[4 * r:4 * r + 4], []) for r in range(15)]


def _add_round_key(state, key):
    return [state[i] ^ key[i] for i in range(16)]


def _sub_bytes(state):
    return [SBOX[b] for b in state]


def _shift_rows(s):
    # State is column-major: s[c*4 + r].
    return [
        s[0], s[5], s[10], s[15],
        s[4], s[9], s[14], s[3],
        s[8], s[13], s[2], s[7],
        s[12], s[1], s[6], s[11],
    ]


def _mix_columns(s):
    out = [0] * 16
    for c in range(4):
        a0, a1, a2, a3 = s[4 * c:4 * c + 4]
        out[4 * c + 0] = _mul(a0, 2) ^ _mul(a1, 3) ^ a2 ^ a3
        out[4 * c + 1] = a0 ^ _mul(a1, 2) ^ _mul(a2, 3) ^ a3
        out[4 * c + 2] = a0 ^ a1 ^ _mul(a2, 2) ^ _mul(a3, 3)
        out[4 * c + 3] = _mul(a0, 3) ^ a1 ^ a2 ^ _mul(a3, 2)
    return out


def encrypt_block(round_keys, block: bytes) -> bytes:
    state = list(block)
    state = _add_round_key(state, round_keys[0])
    for rnd in range(1, 14):
        state = _sub_bytes(state)
        state = _shift_rows(state)
        state = _mix_columns(state)
        state = _add_round_key(state, round_keys[rnd])
    state = _sub_bytes(state)
    state = _shift_rows(state)
    state = _add_round_key(state, round_keys[14])
    return bytes(state)


def _ghash_mul(x: int, y: int) -> int:
    z = 0
    v = y
    for i in range(128):
        if (x >> (127 - i)) & 1:
            z ^= v
        if v & 1:
            v = (v >> 1) ^ 0xE1000000000000000000000000000000
        else:
            v >>= 1
    return z


def _ghash(h: int, data: bytes) -> int:
    x = 0
    for offset in range(0, len(data), 16):
        block = data[offset:offset + 16]
        block = block + b"\x00" * (16 - len(block))
        x = _ghash_mul(x ^ int.from_bytes(block, "big"), h)
    return x


def _gcm_tag(round_keys, h: int, nonce: bytes, ciphertext: bytes) -> bytes:
    if len(nonce) != 12:
        raise ValueError("only 96-bit nonces are supported")
    padded = lambda data: data + b"\x00" * ((16 - len(data) % 16) % 16)
    lengths = (0).to_bytes(8, "big") + (len(ciphertext) * 8).to_bytes(8, "big")
    s = _ghash(h, padded(ciphertext) + lengths)
    j0 = int.from_bytes(nonce + b"\x00\x00\x00\x01", "big")
    mask = int.from_bytes(encrypt_block(round_keys, j0.to_bytes(16, "big")), "big")
    return (s ^ mask).to_bytes(16, "big")


def _ctr(round_keys, nonce: bytes, data: bytes) -> bytes:
    out = bytearray()
    counter = 2
    nonce_int = int.from_bytes(nonce, "big")
    for offset in range(0, len(data), 16):
        chunk = data[offset:offset + 16]
        block = (nonce_int << 32 | counter).to_bytes(16, "big")
        stream = encrypt_block(round_keys, block)
        out.extend(b ^ s for b, s in zip(chunk, stream))
        counter += 1
    return bytes(out)


def seal_combined(key: bytes, plaintext: bytes, nonce: bytes) -> bytes:
    """Return CryptoKit's AES.GCM.SealedBox.combined = nonce + ciphertext + tag."""
    if len(nonce) != 12:
        raise ValueError("nonce must be 12 bytes")
    round_keys = _expand_key(key)
    h = int.from_bytes(encrypt_block(round_keys, b"\x00" * 16), "big")
    ciphertext = _ctr(round_keys, nonce, plaintext)
    tag = _gcm_tag(round_keys, h, nonce, ciphertext)
    return nonce + ciphertext + tag


def seal_envelope(key: bytes, plaintext: str, nonce: bytes = b"\x00" * 12) -> str:
    import base64
    combined = seal_combined(key, plaintext.encode("utf-8"), nonce)
    return "lgb1:" + base64.b64encode(combined).decode("ascii")


def test_vectors() -> None:
    # NIST / McGrew-Viega: all-zero key, all-zero 96-bit nonce, empty plaintext.
    key = b"\x00" * 32
    combined = seal_combined(key, b"", b"\x00" * 12)
    assert combined[:12] == b"\x00" * 12
    expected_tag = bytes.fromhex("530f8afbc74536b9a963b4f1c4cb738b")
    assert combined[12:] == expected_tag, combined[12:].hex()
    sealed = seal_envelope(key, "hello")
    assert sealed.startswith("lgb1:")
    import base64
    raw = base64.b64decode(sealed[5:])
    assert len(raw) == 12 + 5 + 16, len(raw)


if __name__ == "__main__":
    test_vectors()
    print("aesgcm: test vectors OK")
