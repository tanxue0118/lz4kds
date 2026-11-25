#!/usr/bin/env python3
"""
extract_crcs.py —— 从用户回传的取证包生成 Module.symvers + 原厂 CRC 字典
用法:
    python3 extract_crcs.py <取证目录>/modules_vendor_lib_modules/ 输出前缀
产出:
    <前缀>.Module.symvers    可直接放进内核树做外置模块编译
    <前缀>.stock_crcs.py     可被 crc_align.py 消费的 Python 字典
    (modprobe --dump-modversions 需要主机装有 kmod: apt install kmod)
"""
import subprocess, sys, glob, os, collections, struct, shutil


def dump_modversions(ko_path):
    """返回 [(crc_hex, symbol), ...]; modprobe 失败时退回 python 自带 modversion 解析"""
    try:
        out = subprocess.run(['modprobe', '--dump-modversions', ko_path],
                             capture_output=True, text=True, timeout=30)
        pairs = []
        for line in out.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                pairs.append((parts[0], parts[1]))
        if pairs:
            return pairs
    except FileNotFoundError:
        pass  # 主机无 kmod -> 用下面的内置解析
    except Exception as e:
        print(f"  [warn] {os.path.basename(ko_path)}: modprobe failed ({e}), fallback to builtin")

    return parse_modversions_builtin(ko_path)


def parse_modversions_builtin(ko_path):
    """内置 ELF64 解析: 读 __versions 段 (crc, name), 等价 modprobe --dump-modversions"""
    try:
        with open(ko_path, 'rb') as f:
            data = f.read()
    except Exception as e:
        print(f"  [warn] {os.path.basename(ko_path)}: {e}")
        return []
    if data[:4] != b'\x7fELF':
        return []
    e_shoff, = struct.unpack_from('<Q', data, 40)
    e_shentsize, = struct.unpack_from('<H', data, 58)
    e_shnum, = struct.unpack_from('<H', data, 60)
    e_shstrndx, = struct.unpack_from('<H', data, 62)
    shstr_off = e_shoff + e_shstrndx * e_shentsize
    sh_off, = struct.unpack_from('<Q', data, shstr_off + 24)
    sh_size, = struct.unpack_from('<Q', data, shstr_off + 32)
    shstrtab = data[sh_off:sh_off + sh_size]
    pairs = []
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
                if sym and crc:
                    pairs.append((f'{crc:x}', sym))
            break
    return pairs


def main():
    ko_dir, prefix = sys.argv[1], sys.argv[2]
    kos = sorted(glob.glob(os.path.join(ko_dir, '**', '*.ko'), recursive=True))
    print(f"scanning {len(kos)} .ko files under {ko_dir}")

    crc_by_sym = {}          # symbol -> 最新出现的 crc (冲突时记录)
    conflicts = collections.Counter()
    all_pairs = set()

    for ko in kos:
        pairs = dump_modversions(ko)
        name = os.path.basename(ko)
        if pairs:
            print(f"  {name}: {len(pairs)} crc entries")
        for crc, sym in pairs:
            all_pairs.add((crc, sym))
            if sym in crc_by_sym and crc_by_sym[sym][0] != crc:
                conflicts[sym] += 1
            crc_by_sym[sym] = (crc, name)

    # 1. Module.symvers (kbuild 格式)
    symv = f'{prefix}.Module.symvers'
    with open(symv, 'w') as f:
        for crc, sym in sorted(all_pairs, key=lambda x: x[1]):
            f.write(f'0x{crc}\t{sym}\tvmlinux\tEXPORT_SYMBOL\t\n')
    print(f"[ok] {symv}: {len(all_pairs)} symbols")

    # 2. stock_crcs.py (crc_align 用的字典)
    dictp = f'{prefix}.stock_crcs.py'
    with open(dictp, 'w') as f:
        f.write('# auto-generated from device modules\n')
        f.write('STOCK_CRCS = {\n')
        for sym in sorted(crc_by_sym):
            crc, src = crc_by_sym[sym]
            f.write(f'    {sym!r}: {int(crc, 16):#x},  # from {src}\n')
        f.write('}\n')
    print(f"[ok] {dictp}: {len(crc_by_sym)} symbols")

    if conflicts:
        print(f"[warn] {len(conflicts)} symbols have conflicting CRCs across modules:")
        for sym in list(conflicts)[:20]:
            print(f"       {sym} (occurrences: {conflicts[sym]})")
        print("       同名符号不同 CRC 说明多个模块版本混杂, 取 insmod 主链路那份为准")
    print("[note] 原厂 oplus_bsp_hybridswap_zram.ko 单独提取的字典优先级最高")


if __name__ == '__main__':
    main()
