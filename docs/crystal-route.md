# Crystal 路线：SDDC 侧载的完整方案

> 本文说明 **Crystal HybridSwap 路线**的原理、源码结构、编译方式、支持范围与移植要点。
> 这是本工作区中**唯一不依赖厂商私有源码**的 SDDC 侧载路径。
>
> 最后更新：2026-11-25

---

## 1. 为什么选 Crystal 路线

### 两条路线的本质区别

| | OPPO 路线（jkHXQ） | **Crystal 路线（本文）** |
|---|---|---|
| 做法 | 在厂商 `oplus_bsp_hybridswap_zram.ko` 上打补丁重编 | **自己实现一个 zram，整个替换 `zram.ko`** |
| 依赖厂商私有源码 | ✅ 需要 `hybridswap.c` 等 | ❌ 不需要 |
| 依赖厂商私有符号 | ✅ 需要 `zs_*_oplus` 系列 | ❌ 用标准 `zs_*` |
| 依赖厂商私有结构 | ✅ 需要 `struct zs_pool` 布局 | ❌ 用标准接口 |
| 代码可控性 | 受厂商骨架约束 | **全部源码在手** |
| 移植新设备 | CRC 对齐原厂 KO | 有内核树就能编 |

**结论**：要自己改 SDDC，Crystal 路线是唯一可行的起点。

---

## 2. 原理：它怎么做到「自建 zram」

### 2.1 自己注册块设备

`source-xiaomi/zram_drv.c` 中的关键调用：

```c
zram_major = register_blkdev(0, "zram");            // 占用 "zram" 这个名字
zram->disk = blk_alloc_disk(NUMA_NO_NODE);          // 自己造 gendisk
device_add_disk(NULL, zram->disk, zram_disk_groups);// 挂到 /sys/block/zramX
```

因为占了 `zram` 这个名字，**必须先卸载系统原厂的 `zram.ko`**（`rmmod zram`）才能加载它。

### 2.2 保留标准用户态 ABI

用户态看到的东西完全不变：

```
/dev/zram0                 ← 块设备
/sys/block/zram0/          ← disksize / comp_algorithm / mm_stat ...
/sys/class/zram-control/   ← hot_add / hot_remove
/proc/swaps                ← 挂 swap
```

所以 Android 的 `init`、`vold`、`swapon` 全都正常工作，不需要改任何系统配置。

### 2.3 架构分层

```
┌────────────────────────────────────────────────────────┐
│ 用户态（Android init / vold / swapon）                  │
│ 标准 zram ABI，完全无感                                 │
└────────────────────────────────────────────────────────┘
                          ↕
┌────────────────────────────────────────────────────────┐
│ zram_drv.c  (178 KB)                                   │
│ 块设备注册 · slot 表 · 六条接点：                        │
│   store / read / free / reset / disksize / recompress  │
└────────────────────────────────────────────────────────┘
        ↓              ↓                ↓
┌──────────────┐ ┌─────────────────┐ ┌────────────────┐
│ zcomp.c      │ │ sddc/           │ │ zms.c          │
│ 压缩前端      │ │ crystal_sddc.c  │ │ ZMS 回写引擎    │
│              │ │ 163 KB          │ │ 80 KB          │
│ lz4kd/lz4kds │ │ alias/delta     │ │ 压缩流打包落盘  │
│ 后端选择      │ │ 状态机+生命周期  │ │ 4KiB block     │
└──────────────┘ └─────────────────┘ └────────────────┘
        ↓              ↓                ↓
┌────────────────────────────────────────────────────────┐
│ core.c     120 KB   策略 · 自动写回 · 配额              │
│ memcg.c     92 KB   per-memcg 记账与策略                │
│ zram_bridge.c 44 KB 与上层策略桥接                      │
│ pressure.c   7 KB   eventfd 压力通知                    │
│ stats.c     43 KB   统计与诊断节点                      │
│ param.c    3.5 KB   模块参数                            │
└────────────────────────────────────────────────────────┘
                          ↕
┌────────────────────────────────────────────────────────┐
│ 内核标准接口：zsmalloc · block layer · memcg · cgroup    │
└────────────────────────────────────────────────────────┘
```

### 2.4 SDDC 在其中的位置

**关键事实：SDDC 不是独立模块，它被静态链接进 `zram.ko`。**

```makefile
zram-y := zcomp.o zms.o zram_drv.o core.o param.o \
          zram_bridge.o memcg.o pressure.o stats.o
zram-y += sddc/crystal_sddc.o            # ← SDDC 在这里
zram-y += sddc/crystal_sddc_codec.o
zram-y += sddc/lz4kd/lz4kd_encode.o ...
```

原因：

1. SDDC 要挂 zram 的 store/read/free/reset 路径 → 必须能访问 `struct zram`
2. alias/delta 的引用生命周期和 zram slot 绑死 → 同一模块内才好加锁
3. 要调 zsmalloc 内部（`zs_map_object`、size class 判定）

**所以「侧载 SDDC」= 「侧载一个带 SDDC 的 zram.ko」。没有独立 KO 形态。**

---

## 3. 编译方式（已改为 out-of-tree）

### 3.1 Makefile 已改造

原版 Makefile 是给树内用的：

```makefile
obj-$(CONFIG_CRYSTAL_HYBRIDSWAP) += zram.o    # 依赖 Kconfig 求值
```

现已改为 out-of-tree 可编，用 `ccflags` 直接注入开关：

```makefile
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_WRITEBACK=1
ccflags-y += -I$(src) -I$(src)/sddc -I$(src)/sddc/lz4kd -I$(src)/include
obj-m += zram.o
```

好处：**不覆盖内核树的 `drivers/block/zram/` 目录**，原始树保持干净。

### 3.2 编译命令

```bash
# 树外编译（pipeline 的 xiaomi 路线走这个）
make -C <kernel-tree> M=<workspace>/source-xiaomi \
     ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CC=<clang> LD=<ld.lld> ... \
     KBUILD_MODPOST_WARN=1 modules
```

产物：`source-xiaomi/zram.ko`

### 3.3 用 pipeline 编译

```bash
# build.conf 里 type = xiaomi（或 auto 自动判定）
bash pipeline.sh devices/<设备名>
```

pipeline 阶段 5 对 xiaomi 路线自动走树外模式：

```
[阶段5] 树外编译模式：M=/path/to/source-xiaomi（不覆盖内核树 drivers/block/zram）
[阶段5] CONFIG 由 Makefile ccflags 注入（SDDC + LZ4KD 默认启用），不改 .config
```

---

## 4. 支持的内核范围（源码 guard 实测）

### 4.1 源码里的版本分支

```
crystal_hybridswap_internal.h:27   < 6.4.0    → zs_lookup_class_index 自带兜底
zms.c:26                           < 6.5.0    → 块层旧 API
zram_drv.c:55                      < 6.5.0    → blkdev_get_by_dev 旧签名
zram_drv.c:62                      >= 6.4.0
zram_drv.c:1046 / 1188 / 1259 / 5714  >= 6.5.0
zram_drv.c:5740 / 5813             < 6.5.0
```

### 4.2 实际支持矩阵

| 内核 | 状态 | 依据 |
|---|---|---|
| **6.1.x** | ✅ **原生基线** | 2108282 的 houji 实测跑通 |
| **6.4 / 6.5** | ✅ 有兼容分支 | 上游写的 guard |
| **6.6.x** | ✅ **实测通过** | dali、一加 13T、whitewhale0612 |
| **6.12.x** | ⚠️ guard 全满足，**无实测样本** | 理论可编，需验证 |
| 5.10 / 5.15 | ❌ 需移植 | 14 项 API 缺失，见 [port-5.10.md](port-5.10.md) |

### 4.3 硬性前置条件

| 条件 | 说明 |
|---|---|
| **4 KiB 页** | `CONFIG_ARM64_4K_PAGES=y`，LZ4KD 的 8KiB 窗口依赖 |
| **CONFIG_ZRAM=m** | 必须是模块（要 rmmod 原厂） |
| **CONFIG_ZSMALLOC** | 可 y 可 m（Crystal `select ZSMALLOC`） |
| **MEMCG + CGROUPS** | memcg 记账依赖 |
| arm64 | 只有 arm64 实现 |

---

## 5. 需要准备什么

### 5.1 源码（已有）

```
source-xiaomi/          31 文件，自包含
├── Makefile            已改 out-of-tree
├── Kconfig
├── zram_drv.c  178 KB  zram 驱动主体
├── zram_drv.h  10.5 KB
├── core.c      120 KB  策略
├── memcg.c      92 KB  memcg
├── zms.c        80 KB  ZMS 回写
├── zram_bridge.c 44 KB
├── stats.c      43 KB
├── zcomp.c      13.6 KB
├── pressure.c    6.7 KB
├── param.c       3.5 KB
├── include/linux/crystal_hybridswap.h   （本次补齐）
└── sddc/         14 文件
    ├── DESIGN.md        30 KB  ★ 设计文档，必读
    ├── crystal_sddc.c  163 KB
    ├── crystal_sddc.h  10 KB
    ├── crystal_sddc_codec.c
    ├── crystal_sddc_codec_test.c  KUnit
    └── lz4kd/           7 文件 LZ4KD 编解码 + NEON
```

### 5.2 目标内核源码树（必需）

| 目标 | 来源 |
|---|---|
| 纯 GKI / Pixel | `https://android.googlesource.com/kernel/common -b android15-6.6` |
| 小米设备 | `https://github.com/MiCode/Xiaomi_Kernel_OpenSource -b bsp-<代号>-<版本>-oss` |
| 一加/OPPO | `https://github.com/OnePlusOSS/android_kernel_*`（标准 zram 部分可用） |

**已实测确认小米树含完整源码**：

```
bsp-dali-v-oss 分支：
  drivers/block/zram/  → Kconfig Makefile TEST_MAPPING
                          zcomp.c zcomp.h zram_drv.c zram_drv.h
  mm/zsmalloc.c        → 57,659 B
```

### 5.3 设备取证数据

| 文件 | 用途 | 能否省 |
|---|---|---|
| `/proc/config.gz` | 复刻内核配置 | ❌ |
| `uname -r` | vermagic | ❌ |
| `getconf PAGE_SIZE` | 必须 4096 | ❌ |
| `/proc/kallsyms` | 符号闸门 | ⚠️ 只在"仅验证可编译"时可省 |
| `/vendor/lib/modules/zram.ko` | CRC 参照 + 回滚救生索 | ⚠️ 可省但强烈建议 |

### 5.4 工具链

```bash
bash tools/get-clang.sh --mirror tuna    # Android clang
# 或 export ANDROID_CLANG=/path/to/clang-rXXXXXX/bin
```

Linux 宿主（WSL2 可），需要 `git make python3 gcc bc bison flex libssl-dev kmod zip binutils`。

---

## 6. 关于源码开源性的说明

### 6.1 安卓内核确实是 Linux，且大多开源

```
Linux 主线 (kernel.org，GPL-2.0)
    ↓ fork
ACK — Android Common Kernel (android.googlesource.com，开源)
    ↓ fork
厂商内核树 (小米/一加，GPL 要求开源)
    ↓ 追加
厂商私有驱动 vendor/... (部分不开源)
```

### 6.2 实测的各家开源情况

| 仓库 | 有什么 | 缺什么 |
|---|---|---|
| **小米** `MiCode/Xiaomi_Kernel_OpenSource` | 100+ 分支，含 `drivers/block/zram/` + `mm/zsmalloc.c` | — ✅ 完整 |
| **一加** `OnePlusOSS/android_kernel_oneplus_sm8750` | 标准 ACK 树 + 59 个 oplus 驱动 | ❌ **无 `vendor/oplus/kernel/mm/hybridswap_zram`** |
| **Google GKI** | 纯标准树 | — ✅ 完整 |

**这就是为什么 Crystal 路线能通而 OPPO 路线难走**：Crystal 只用标准 `drivers/block/zram`，开源树里都有；OPPO 路线要那份缺失的 `vendor/oplus/...` 源码。

---

## 7. 已知问题（改 SDDC 前必读）

### 7.1 LZ4KDS 有读回稳定性 bug

whitewhale0612 的 README 原文：

> ⚠️ **`LZ4KDS` 仍存在已知的读回稳定性问题：读回时可能读到错误页或零页，进而导致应用崩溃或 `system_server` 崩溃。因此不建议在日常使用中启用；表中的 `LZ4KDS` 数据仅供测试参考。**

**这是你自己改 SDDC 时的首要修复目标。**

可疑点（供参考）：

- `crystal_sddc.c` 的 `read_page_locked()` 里 `-EAGAIN` 重试上限是 4 次（`zram_drv.c:1487`）
- delta 的基准页被释放后，引用代际（generation cookie）校验是否严密
- `zs_map_object` 的映射/解映射在同一页被并发访问时的竞态

### 7.2 实际收益没有传说中高

同作者实测（一块设备，60MB 数据）：

| 算法 | Payload 压缩比 | 写 MiB/s | 4K 读 MiB/s | 延迟 P99 |
|---|---|---|---|---|
| LZ4 | 1.57 | 162.0 | 4985 | 9.28 µs |
| ZSTD | 1.96 | 28.6 | 1551 | 30.85 µs |
| **LZ4KDS** | **2.17** | 124.3 | 4412 | 12.22 µs |
| LZO-RLE | 1.56 | 168.4 | 4102 | 11.97 µs |

**2.17x，不是 5x。** 网上说的 5x 是特定负载下的单机观测。

### 7.3 NEON 冲突

`lz4kd_encode.c` 会调 `kernel_neon_begin()/end()`。Makefile 里已按原版做法禁用 `-mgeneral-regs-only`，避免 `kmap_atomic` 路径与渲染中断产生 FPSIMD 冲突死锁。

---

## 8. 后续改造方向（你自己维护时）

| 优先级 | 事项 | 说明 |
|---|---|---|
| P0 | 修 LZ4KDS 读回 bug | 见 7.1，这是可用性前提 |
| P0 | 验证 6.12 能否编过 | 无实测样本，先跑通再说 |
| P1 | 参数化 SDDC 阈值 | `DELTA_GAIN_MIN`/`SIMILARITY_MIN`/`HASH_BITS` 现在是编译期宏，改成 module_param |
| P1 | 修正 `zs_lookup_class_index` 兜底 | `<6.4` 分支用 `DIV_ROUND_UP(size,32)` 是近似，可能放过低收益 delta |
| P2 | 补 per-memcg 记账 | memcg.c 已有，但 SDDC 的 alias/delta 引用是否计入需验证 |
| P2 | 加 KUnit 覆盖 | `crystal_sddc_codec_test.c` 已有，但 SDDC 状态机测试不足 |

---

## 9. 快速验证流程

```bash
# ① 准备内核树
git clone --depth=1 -b android15-6.6 \
  https://android.googlesource.com/kernel/common ~/kernel-6.6

# ② 准备工具链
cd ~/lz4kds
bash tools/get-clang.sh --mirror tuna
source work/clang.env

# ③ 准备设备目录（用真机取证包）
cp -r devices/TEMPLATE devices/test-6.6
# 填入 config.txt / uname.txt / page_size.txt / kallsyms.txt

# ④ 填 build.conf
cat > devices/test-6.6/build.conf <<'EOF'
[device]
model = test
kernel_release = 6.6.118-android15-8-xxxx
[arch]
type = xiaomi
[kernel]
local_tree = /home/you/kernel-6.6
[build]
source_dir =
module_path =
ko_name =
extra_ko =
crc_ref_ko =
clang_dir =
extra_make_flags =
[pack]
algo = lz4kds
EOF

# ⑤ 编译
bash pipeline.sh devices/test-6.6

# 产物
ls dist/lz4kds侧载-xiaomi-*.zip
```

---

## 10. 与 OPPO 路线的对照（选型用）

| 场景 | 选 Crystal（xiaomi） | 选 OPPO（oplus） |
|---|---|---|
| 有厂商内核源码树 | ✅ 首选 | 需额外有 hybridswap 源码 |
| 设备 `CONFIG_ZRAM=m` | ✅ | ✅ |
| 要自己改 SDDC | ✅ **唯一可行** | 受厂商骨架约束 |
| 设备是 OPPO/realme/一加 | 可以（用标准 zram 路径） | 原生匹配 |
| 想做跨厂商通用包 | ✅ 按 KMI 编多份 | 每厂商单独适配 |

---

## 附：本次改动清单

| 文件 | 改动 |
|---|---|
| `source-xiaomi/Makefile` | 树内 → **out-of-tree**；ccflags 注入 CONFIG；加 include 路径；NEON 条件编译 |
| `source-xiaomi/include/linux/crystal_hybridswap.h` | **新增**（从 huaji 仓库补齐，`pressure.c` 需要） |
| `pipeline.sh` 阶段 5 | xiaomi 路线改为树外编译（`M=$ROOT/source-xiaomi`），不覆盖内核树；CONFIG 走 ccflags 不改 `.config` |
