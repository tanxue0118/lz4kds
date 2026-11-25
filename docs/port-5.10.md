# 5.10 内核移植任务表（lz4kds / Crystal SDDC）

> **结论先说：5.10 不能保证编译通过。**
> 本文是基于真实 5.10.66 内核树的静态审计结果，可作为移植任务清单使用。
> **未经实际编译验证**，本文列出的只是「已确认缺失的 API」，编译期还会暴露本文未覆盖的问题。

- 审计日期：2026-11-25
- 目标设备样本：某 MTK 平台设备（5.10.66 / Android 12 / 4 KiB 页）
- 审计用内核树：某厂商 5.10.66 内核树（8734 个 .c/.h 文件）
- 被审计源码：`source-xiaomi/`（Crystal HybridSwap，从 `2108282/zram-lz4kds-sddc-houji-6.1` 取）
- 审计方法：提取源码中全部 `标识符(` 形式的调用（1256 个），逐个在 5.10.66 树的
  `include/` `arch/arm64/include/` `mm/` `drivers/block/` `fs/` `block/` 中检索声明

---

## 1. 源码自带的版本兼容基线

Crystal HybridSwap 源码里已有两处版本 guard，说明**作按 6.1 基线写的**：

| 位置 | guard | 作用 |
|---|---|---|
| `crystal_hybridswap_internal.h:27` | `< KERNEL_VERSION(6, 4, 0)` | 自带 `zs_lookup_class_index()` 兜底实现（`DIV_ROUND_UP(size, 32)`）|
| `zram_drv.c:55 / :5813` | `< KERNEL_VERSION(6, 5, 0)` | `blkdev_get_by_dev()` 用旧签名 `FMODE_READ\|FMODE_WRITE\|FMODE_EXCL` |
| `zram_drv.c:62 / :1046 / :1188 / :1259 / :5714` | `>= KERNEL_VERSION(6, 4/6, 5, 0)` | 新签名分支 |
| `zms.c:26` | `< KERNEL_VERSION(6, 5, 0)` | 块层兼容 |

**这解释了口口相传的「只有 6.1 以上才行」——源码确实以 6.1 为最低支持基线。**

---

## 2. 已确认缺失的 API（14 项，共 31 处调用）

| # | 缺失 API | 引入版本 | 出现次数 | 5.10 替代方案 |
|---|---|---|---|---|
| 1 | `abs_diff` | 5.12 | 5 | 自定义 `#define abs_diff(a,b) ({ __typeof__(a) _a=(a),_b=(b); _a>_b?_a-_b:_b-_a; })` |
| 2 | `bdev_start_io_acct` | 5.16 | 1 | `part_stat_*` / `update_io_ticks` |
| 3 | `bdev_end_io_acct` | 5.16 | 1 | 同上 |
| 4 | `bio_advance_iter_single` | 5.18 | 2 | `bio_advance_iter` |
| 5 | `blk_alloc_disk` | 5.16 | 1 | `alloc_disk(1)` |
| 6 | `disk_openers` | 5.17 | 2 | `atomic_read(&disk->part0->bd_openers)` 或 `bd_mount...` |
| 7 | `kmap_local_page` | 5.11 | 4 | `kmap_atomic` |
| 8 | `kunmap_local` | 5.11 | 4 | `kunmap_atomic` |
| 9 | `memcpy_from_bvec` | 5.18 | 1 | `kmap_atomic(bvec->bv_page)` + `memcpy` |
| 10 | `memcpy_to_bvec` | 5.18 | 1 | 同上 |
| 11 | `page_memcg_check` | 5.11 | 1 | 5.10 直接读 `page->mem_cgroup`（配合 `PageSlab` 判断）|
| 12 | `percpu_counter_init_many` | 5.15 | 3 | `percpu_counter_init` 循环 |
| 13 | `percpu_counter_destroy_many` | 5.15 | 3 | `percpu_counter_destroy` 循环 |
| 14 | `set_capacity_and_notify` | 5.16 | 2 | `set_capacity` |

### 唯一不需要动的项

`zs_lookup_class_index` —— 5.10.66 树里确实没有（`include/linux/zsmalloc.h` 无此声明），
但源码 `< 6.4` 分支自带实现，**5.10 自动走兜底，无需修改**。

---

## 3. 5.10 原厂 zram 的正确写法（移植参照）

目标内核树的 `drivers/block/zram/zram_drv.c` 是最好的参照物，行号如下：

| 场景 | 5.10 写法 | 行号 |
|---|---|---|
| bvec 读写 | `kmap_atomic(bvec->bv_page)` 直接取 | 1316 / 1317 |
| 页映射 | `mem = kmap_atomic(page)` | 1263 / 1277 / 1282 / 1343 |
| 容量设置 | `set_capacity(zram->disk, zram->disksize >> SECTOR_SHIFT)` | 1761 |
| 容量清零 | `set_capacity(zram->disk, 0)` | 1715 / 1948 |
| IO 统计 | `part_stat_set_all(&zram->disk->part0, 0)`（`#include <linux/part_stat.h>`）| 36 / 1716 |
| 磁盘分配 | `zram->disk = alloc_disk(1)` | 1932 |
| 注册磁盘 | `device_add_disk(NULL, zram->disk, zram_disk_attr_groups)` | 1978 |
| percpu_counter | 5.10 原厂 zram 不使用；无 `_many` 变体 | — |

---

## 4. 本文未覆盖的风险（必须实际编译才能确认）

| 风险类别 | 具体内容 | 为什么没能在静态审计中确认 |
|---|---|---|
| 结构体成员改名 | `struct request_queue` / `struct gendisk` / `disk->fops` 成员 | 静态比对只看标识符存在性，不看成员归属 |
| 宏参数变化 | `bio_for_each_segment` 等迭代宏语义 | 同上 |
| cgroup/memcg API | `cgroup_add_dfl_cftypes`、`css_online/attach/offline` hook | 需确认 5.10 MTK 树是否提供 |
| **Android vendor hook** | `register_trace_android_vh_cgroup_attach` / `_mem_cgroup_css_offline` / `_tune_scan_type` | 这些是 ACK GKI 专属 hook，**5.10 MTK 厂商树很可能没有** |
| 编译期宏分支 | 各种 `#if` 组合下的不可见分支 | 只在实际编译时展开 |
| CFI 兼容 | `CONFIG_CFI_CLANG=y` + `CFI_CLANG_SHADOW=y` | 需编译+加载验证 |
| 符号裁剪 | `CONFIG_TRIM_UNUSED_KSYMS=y` | 加载时才暴露 |
| zsmalloc 结构 | 虽然 `zs_lookup_class_index` 有兜底，但 `struct zs_pool` 其他内部用量 | 需编译验证 |

> **重点提醒**：`unregister_trace_android_vh_*` 系列在审计中列为「5.10 树中找不到」。
> 这不是版本问题，而是 **ACK GKI 专有 vendor hook 在 MTK 厂商树上不存在**。
> 移植到 MTK 平台必须处理这块（改成 MTK 的 hook，或去掉该功能）。

---

## 5. 建议的移植顺序

```
第 0 步：先确认能"编译到报错"
  在 WSL2 里跑 pipeline，拿到第一批编译错误
  → 验证本文 14 项清单是否准确、是否有遗漏

第 1 步：机械替换（低风险，共 20 处）
  kmap_local_page → kmap_atomic（4 处）
  kunmap_local    → kunmap_atomic（4 处）
  abs_diff        → 自定义宏（5 处）
  set_capacity_and_notify → set_capacity（2 处）
  blk_alloc_disk  → alloc_disk(1)（1 处）
  percpu_counter_*_many → 循环调用（6 处）

第 2 步：块层适配（中风险）
  memcpy_from_bvec / memcpy_to_bvec → 手写 kmap_atomic 拷贝（2 处）
  bio_advance_iter_single → bio_advance_iter（2 处）
  bdev_start/end_io_acct → part_stat_*（2 处）
  disk_openers → bd_openers（2 处）

第 3 步：memcg（中高风险）
  page_memcg_check → 直接读 page->mem_cgroup（1 处）
  vendor hook 处理（MTK 树无 ACK hook）

第 4 步：编译 + 符号闸门 + CRC 对齐 + 真机验证
```

全部加版本 guard，保持对 6.1/6.6 的兼容：

```c
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 11, 0)
    dst = kmap_atomic(page);
#else
    dst = kmap_local_page(page);
#endif
```

---

## 6. 验证方法

```bash
# 1. 编译看第一批错误
cd ~/lz4kds && source work/clang.env
bash pipeline.sh devices/<设备名>
tail -50 work/<设备名>/build.log

# 2. 符号闸门（编过之后）
bash tools/symgate.sh <新编.ko> devices/<设备名>/kallsyms.txt

# 3. CRC 对齐
python3 tools/crc_align.py <新编.ko> \
  devices/<设备名>/modules_*/zram.ko
```

---

## 7. 替代方案（无需移植）

如果目标只是「让设备的 zram 用更好的压缩」，不必碰 SDDC：

| 方案 | 说明 | 状态 |
|---|---|---|
| `misaka5202/zram-lkm` 预编译包 | `zram-lkm-v0.1.6-android12-5.10-arm64.zip`，纯 crypto 算法模块（lz4kd/lz4k/lz4k_oplus/lz4hc）| ✅ 已验证 5.10 设备所需符号均存在于 kallsyms |
| 代价 | 只有单页压缩，**无 SDDC 跨页去重** | 压缩比约 2~3x（非 5x）|
| 优点 | 零编译、零移植、CFI 已用 `__nocfi` 处理、符号用 KallRecon 解析绕过 TRIM | — |

---

## 8. 修订记录

| 日期 | 内容 |
|---|---|
| 2026-11-25 | 初版：14 项 API / 31 处调用的完整审计清单 |
