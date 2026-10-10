#!/usr/bin/env python3
"""apk_perms.py <apk>

Cetak nama permission yang diminta APK (elemen <uses-permission>, <uses-permission-sdk-23>,
<uses-permission-sdk-m>) dari AndroidManifest.xml biner, satu per baris, tanpa duplikat.

Dipakai port_apps.sh untuk membuat allowlist privapp-permissions bagi app priv-app yang
diganti dari URL (tanpa allowlist, izin privileged yang tidak tercatat bisa membuat
system_server crash saat boot kalau ro.control_privapp_permissions=enforce).
"""
import struct
import sys
import zipfile

RES_STRING_POOL = 0x0001
RES_XML_START_ELEMENT = 0x0102
UTF8_FLAG = 0x100
NONE = 0xFFFFFFFF
TYPE_STRING = 0x03
ELEMENTS = ("uses-permission", "uses-permission-sdk-23", "uses-permission-sdk-m")


def _strings(buf, off):
    (_t, hsize, _size, count, _style, flags, str_start, _sty_start) = struct.unpack_from("<HHIIIIII", buf, off)
    offsets = struct.unpack_from("<%dI" % count, buf, off + hsize)
    base = off + str_start
    utf8 = bool(flags & UTF8_FLAG)
    out = []
    for o in offsets:
        p = base + o
        if utf8:
            n = buf[p]; p += 1
            if n & 0x80:
                p += 1
            ln = buf[p]; p += 1
            if ln & 0x80:
                ln = ((ln & 0x7F) << 8) | buf[p]; p += 1
            out.append(buf[p:p + ln].decode("utf-8", "replace"))
        else:
            ln = struct.unpack_from("<H", buf, p)[0]; p += 2
            if ln & 0x8000:
                ln = ((ln & 0x7FFF) << 16) | struct.unpack_from("<H", buf, p)[0]; p += 2
            out.append(buf[p:p + ln * 2].decode("utf-16-le", "replace"))
    return out


def permissions(data):
    if len(data) < 8:
        return []
    _t, hsize, _size = struct.unpack_from("<HHI", data, 0)
    pos = hsize
    strings = []
    seen = []
    while pos + 8 <= len(data):
        ctype, _chsize, csize = struct.unpack_from("<HHI", data, pos)
        if csize < 8:
            break
        if ctype == RES_STRING_POOL:
            strings = _strings(data, pos)
        elif ctype == RES_XML_START_ELEMENT:
            name_idx = struct.unpack_from("<I", data, pos + 20)[0]
            if name_idx < len(strings) and strings[name_idx] in ELEMENTS:
                a_start, a_size, a_count = struct.unpack_from("<HHH", data, pos + 24)
                ap = pos + 16 + a_start
                for i in range(a_count):
                    base = ap + i * a_size
                    _ns, an, raw = struct.unpack_from("<III", data, base)
                    _sz, _r0, dtype, dval = struct.unpack_from("<HBBI", data, base + 12)
                    if an < len(strings) and strings[an] == "name":
                        if raw != NONE and raw < len(strings):
                            val = strings[raw]
                        elif dtype == TYPE_STRING and dval < len(strings):
                            val = strings[dval]
                        else:
                            continue
                        if val not in seen:
                            seen.append(val)
        pos += csize
    return seen


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    try:
        with zipfile.ZipFile(sys.argv[1]) as z:
            data = z.read("AndroidManifest.xml")
    except Exception:
        return
    for p in permissions(data):
        print(p)


if __name__ == "__main__":
    main()
