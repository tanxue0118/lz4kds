#!/usr/bin/env python3
"""
crc_align.py —— 把新编 KO 的 __versions 段 CRC 逐符号对齐到设备原厂 KO
用法:
    python3 crc_align.py <新编.ko> <设备原厂参照.ko> [输出.ko]
原理:
    ELF64 __versions 段每 64 字节一条记录: 8 字节 CRC + 符号名。
    从参照 KO 抽出全量 (symbol -> crc) 字典, 再把新 KO 里同名符号的 CRC
    替换成参照值。这样即使编译内核版本略有差异, modversion 校验也能通过。
"""
import sys, struct


def parse_versions(data: bytearray):
    """返回 [(offset, crc, name), ...]；非 ELF 或过小文件返回 None"""
    if len(data) < 64 or data[:4] != b'\x7fELF':
        return None
    e_shoff, = struct.unpack_from('<Q', data, 40)
    e_shentsize, = struct.unpack_from('<H', data, 58)
    e_shnum, = struct.unpack_from('<H', data, 60)
    e_shstrndx, = struct.unpack_from('<H', data, 62)

    shstr_off = e_shoff + e_shstrndx * e_shentsize
    sh_off, = struct.unpack_from('<Q', data, shstr_off + 24)
    sh_size, = struct.unpack_from('<Q', data, shstr_off + 32)
    shstrtab = data[sh_off:sh_off + sh_size]

    versions = []
    for i in range(e_shnum):
        sec = e_shoff + i * e_shentsize
        sh_name, = struct.unpack_from('<I', data, sec)
        name = shstrtab[sh_name:].split(b'\x00')[0].decode('latin1')
        if name == '__versions':
            off, = struct.unpack_from('<Q', data, sec + 24)
            size, = struct.unpack_from('<Q', data, sec + 32)
            for p in range(off, off + size, 64):
                crc, = struct.unpack_from('<Q', data, p)
                sym = bytes(data[p + 8:p + 64]).split(b'\x00')[0].decode('latin1', 'ignore')
                if sym:
                    versions.append((p, crc, sym))
            break
    return versions


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    ko_path = sys.argv[1]
    ref_path = sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else ko_path

    with open(ref_path, 'rb') as f:
        ref = parse_versions(bytearray(f.read()))
    if ref is None:
        print(f"[error] 参照文件不是有效 ELF: {ref_path}")
        sys.exit(2)
    stock = {sym: crc for _, crc, sym in ref}
    if not stock:
        print(f"[error] 参照 KO 无 __versions 段（未开 CONFIG_MODVERSIONS 或是空文件）: {ref_path}")
        sys.exit(2)
    print(f"[ref] {ref_path}: {len(stock)} symbols with CRC")

    with open(ko_path, 'rb') as f:
        data = bytearray(f.read())
    mine = parse_versions(data)
    if mine is None:
        print(f"[error] 目标文件不是有效 ELF（可能编译失败产出空文件）: {ko_path}")
        sys.exit(2)
    if not mine:
        print(f"[error] 目标 KO 无 __versions 段: {ko_path}")
        sys.exit(2)
    print(f"[ko ] {ko_path}: {len(mine)} versioned imports")

    patched = missing = 0
    for p, old_crc, sym in mine:
        if sym in stock:
            new_crc = stock[sym]
            if old_crc != new_crc:
                struct.pack_into('<Q', data, p, new_crc)
                print(f"  PATCH {sym}: {old_crc:#x} -> {new_crc:#x}")
                patched += 1
        else:
            # 参照里没有的符号: 参照 KO 本身不导入它, CRC 无法对齐
            # 如果设备内核有 MODVERSIONS 且内核导出该符号, insmod 会报 crc error
            print(f"  WARN  {sym}: not in reference KO (check /proc/kallsyms + device config)")
            missing += 1

    with open(out_path, 'wb') as f:
        f.write(data)
    print(f"[done] patched={patched} unmatched={missing} -> {out_path}")
    if missing:
        print("[note] unmatched 符号需人工确认: 要么内核没导出(闸门1会拦), 要么参照KO没用到")
    sys.exit(0)


if __name__ == '__main__':
    main()
