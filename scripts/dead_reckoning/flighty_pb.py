"""Raw protobuf walk of a Flighty map-state file (no schema): messages as
nested lists of (field, value)."""

import struct
import sys


def varint(b, i):
    x = s = 0
    while True:
        c = b[i]
        i += 1
        x |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return x, i


def parse(b):
    out, i = [], 0
    while i < len(b):
        key, i = varint(b, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = varint(b, i)
        elif w == 1:
            v = struct.unpack("<d", b[i:i + 8])[0]
            i += 8
        elif w == 5:
            v = struct.unpack("<f", b[i:i + 4])[0]
            i += 4
        elif w == 2:
            n, i = varint(b, i)
            raw = b[i:i + n]
            i += n
            try:
                v = parse(raw)
                if not v:
                    v = raw
            except Exception:
                v = raw
            if isinstance(v, bytes):
                try:
                    v = v.decode()
                except UnicodeDecodeError:
                    pass
        else:
            raise ValueError(w)
        out.append((f, v))
    return out


def shape(msg, path="", acc=None):
    acc = {} if acc is None else acc
    for f, v in msg:
        p = f"{path}.{f}"
        if isinstance(v, list):
            shape(v, p, acc)
        else:
            acc.setdefault(p, []).append(v)
    return acc


if __name__ == "__main__":
    msg = parse(open(sys.argv[1], "rb").read())
    for p, vs in shape(msg).items():
        nums = [v for v in vs if isinstance(v, (int, float))]
        rng = f"{min(nums)} … {max(nums)}" if nums else repr(vs[0])[:80]
        print(f"{p:30s} n={len(vs):5d}  {rng}   first={repr(vs[0])[:60]} last={repr(vs[-1])[:60]}")
