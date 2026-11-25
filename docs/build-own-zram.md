# 从零做一个带 SDDC 的 zram：源码获取 → 自建 → 集成

> **本文是操作手册，不是原理科普。** 按章节顺序执行，你最终会得到一个自己维护、能编进 SDDC 的 zram 驱动。
>
> 适用：想完全掌控 zram + SDDC，不依赖任何厂商私有源码。
> 最后更新：2026-11-25

---

## 目录

- [第 0 章：先想清楚你要哪条路](#第-0-章先想清楚你要哪条路)
- [第 1 章：获取源码（三个来源，各有取舍）](#第-1-章获取源码三个来源各有取舍)
- [第 2 章：获取内核树（必需，替代不了）](#第-2-章获取内核树必需替代不了)
- [第 3 章：理解 zram 驱动的骨架（自建前的必修课）](#第-3-章理解-zram-驱动的骨架自建前的必修课)
- [第 4 章：路线 A —— 在 Crystal 源码上改（推荐）](#第-4-章路线-a--在-crystal-源码上改推荐)
- [第 5 章：路线 B —— 从标准 zram 自己加 SDDC（彻底掌控）](#第-5-章路线-b--从标准-zram-自己加-sddc彻底掌控)
- [第 6 章：把 SDDC 接进你的 zram（详细步骤）](#第-6-章把-sddc-接进你的-zram详细步骤)
- [第 7 章：编译与验证](#第-7-章编译与验证)
- [第 8 章：打包成可侧载的模块](#第-8-章打包成可侧载的模块)
- [第 9 章：维护自己的分支（版本管理建议）](#第-9-章维护自己的分支版本管理建议)
- [附录 A：完整文件清单](#附录-a完整文件清单)
- [附录 B：踩坑记录](#附录-b踩坑记录)

---

## 第 0 章：先想清楚你要哪条路

你要做「自己维护的、带 SDDC 的 zram」，有两条路：

| | 路线 A：改 Crystal | 路线 B：从标准 zram 自建 |
|---|---|---|
| 起点 | Crystal 完整驱动（31 文件） | Linux 主线 `drivers/block/zram`（7 文件） |
| 工作量 | 小（已经能跑） | 大（要自己实现所有东西） |
| 掌控度 | 中（受 Crystal 架构约束） | **完全** |
| 风险 | 低 | 高（自己写 block 层容易出 bug） |
| 适合 | 想快点有可用产物，再做局部改造 | 想彻底按自己想法设计 |

**本文两条都写，但建议先走 A，跑通后再考虑是否重写成 B。**

理由：zram 是一个块设备驱动，涉及 block layer、zsmalloc、memcg、swap 子系统。从零写要走很多弯路，而 Crystal 的实现已经把这些问题解决了。

---

## 第 1 章：获取源码（三个来源，各有取舍）

### 1.1 来源① Crystal HybridSwap 上游（最正统）

```bash
git clone --depth=1 https://github.com/Wcoom/oneplus_sm8750_kernel
# 关键目录
ls oneplus_sm8750_kernel/drivers/crystalfrostwork/crystal_hybridswap/
```

**这是 SDDC 的原始作者版**。特点：

- 最贴近设计意图
- 可能不含某些机型的适配补丁
- 需要你自己加 Kconfig / 对接厂商树

### 1.2 来源② houji 移植版（最完整，推荐起点）

```bash
git clone --depth=1 https://github.com/2108282/zram-lz4kds-sddc-houji-6.1
```

特点：

| 优点 | 缺点 |
|---|---|
| **含完整 DESIGN.md（30 KB，10 章）** | 面向小米 14（6.1），有设备特定代码 |
| 含 KUnit 测试 | 6.1 特有 API 用法 |
| 6.1 适配已做好（`blkdev_get_by_dev` 等） | 需要剥离设备特定部分 |
| 目录结构干净（`drivers/crystal_hybridswap/`）| — |

**本工作区已采用这个作为 `source-xiaomi/`。**

目录结构：

```
drivers/crystal_hybridswap/
├── Makefile          636 B
├── Kconfig            10 KB
├── zram_drv.c        178 KB   ← 主驱动
├── zram_drv.h         10 KB
├── core.c            120 KB   ← 模块入口 + 策略
├── memcg.c            92 KB
├── zms.c              80 KB   ← ZMS 回写引擎
├── zram_bridge.c      44 KB
├── stats.c            43 KB
├── zcomp.c            13 KB
├── pressure.c        6.7 KB
├── param.c           3.5 KB
├── crystal_hybridswap_internal.h  31 KB
├── README.md / README_ZH.md
├── include/linux/crystal_hybridswap.h
└── sddc/
    ├── DESIGN.md          30 KB  ★ 必读
    ├── crystal_sddc.c    163 KB
    ├── crystal_sddc.h     10 KB
    ├── crystal_sddc_codec.c
    ├── crystal_sddc_codec_test.c
    └── lz4kd/              7 文件（LZ4KD 编解码 + NEON）
```

### 1.3 来源③ 从 Linux 主线拿标准 zram（路线 B 的起点）

```bash
git clone --depth=1 -b v6.6 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
ls linux/drivers/block/zram/
# Kconfig  Makefile  zcomp.c  zcomp.h  zram_drv.c  zram_drv.h
```

标准 zram 只有 6 个文件，非常干净：

```
drivers/block/zram/
├── Kconfig        约 60 行
├── Makefile       约 10 行
├── zcomp.c        约 550 行   压缩前端（crypto API 桥接）
├── zcomp.h        约 80 行
├── zram_drv.c     约 2100 行  驱动主体
└── zram_drv.h     约 130 行
```

**这是路线 B 的起点：2100 行的 zram_drv.c，你要在上面加 SDDC 接点。**

### 1.4 别忘了拿 LZ4KD

SDDC 的 delta 算法基于华为 LZ4KD。从来源②里已经有：

```
sddc/lz4kd/
├── lz4kd.h
├── lz4kd_encode.c            普通编码
├── lz4kd_encode_delta.c      ★ delta 编码（SDDC 的核心）
├── lz4kd_encode_private.h
├── lz4kd_decode.c
├── lz4kd_neon.c              NEON 加速
├── lz4kd_neon.h
└── lz4kd_private.h
```

如果从别处拿，注意要**完整的 delta 编解码**，不能只有普通压缩。

### 1.5 源码授权检查（重要）

```bash
head -3 sddc/crystal_sddc.c
# SPDX-License-Identifier: GPL-2.0-or-later

head -3 sddc/lz4kd/lz4kd_encode.c
# BSD-3-Clause OR GPL-2.0
```

**GPL-2.0**：你分发二进制必须提供源码。这是你的义务，也意味着别人不能闭源拿走你的改动。

---

## 第 2 章：获取内核树（必需，替代不了）

### 2.1 为什么必须有

编译 KO 不是「有源码 + 有编译器」就够。kbuild 需要内核树提供：

| 需要 | 来源 | 少了会怎样 |
|---|---|---|
| 头文件（`include/linux/*.h`）| 内核树 | 编译直接失败 |
| `.config` | 内核树或设备 `/proc/config.gz` | 不知道开哪些功能 |
| `Module.symvers` | 内核树或设备 KO 抽 | 符号 CRC 对不上，`insmod` 报错 |
| `make prepare` 产物 | 内核树 | `include/generated/` 不存在 |
| zsmalloc 头文件 | 内核树 `include/linux/zsmalloc.h` | 编译失败 |

### 2.2 按目标选树

| 目标设备 | 拿哪棵树 |
|---|---|
| 纯 GKI / Pixel / 通用 | `https://android.googlesource.com/kernel/common` |
| 小米设备 | `https://github.com/MiCode/Xiaomi_Kernel_OpenSource` |
| 一加 / OPPO / realme | `https://github.com/OnePlusOSS/android_kernel_*` |
| 三星 | 三星开源站 `opensource.samsung.com` |

### 2.3 小米树实测（含完整源码）

```bash
git clone --depth=1 -b bsp-dali-v-oss \
  https://github.com/MiCode/Xiaomi_Kernel_OpenSource
```

实测确认包含：

```
drivers/block/zram/  →  Kconfig Makefile TEST_MAPPING
                        zcomp.c zcomp.h zram_drv.c zram_drv.h
mm/zsmalloc.c        →  57,659 B
```

### 2.4 GKI 树（最通用）

```bash
# 按 KMI 选分支
git clone --depth=1 -b android14-6.1 https://android.googlesource.com/kernel/common
git clone --depth=1 -b android15-6.6 https://android.googlesource.com/kernel/common
git clone --depth=1 -b android16-6.12 https://android.googlesource.com/kernel/common
```

**注意**：`android12-5.10` 和 `android13-5.10` 是两个不同分支，不能混用。

### 2.5 内核树必须满足的条件

```bash
KT=~/kernel-6.6

# ① 4 KiB 页（SDDC 硬要求）
grep 'CONFIG_ARM64_4K_PAGES=y' $KT/.config    # 或 arch/arm64/configs/gki_defconfig

# ② CONFIG_ZRAM 必须是 m（我们要替换它）
grep 'CONFIG_ZRAM=m' $KT/.config

# ③ zsmalloc 可用
grep -E 'CONFIG_ZSMALLOC=[ym]' $KT/.config

# ④ memcg + cgroups
grep -E 'CONFIG_MEMCG=y|CONFIG_CGROUPS=y' $KT/.config
```

**如果 `CONFIG_ZRAM=y`（编进内核）**，那就无法侧载，只能改内核刷 boot.img。

---

## 第 3 章：理解 zram 驱动的骨架（自建前的必修课）

不管走 A 还是 B，你都得知道 zram 是什么结构。

### 3.1 模块入口在 core.c，不在 zram_drv.c

这一点很多人会找错。实测：

```
core.c:3405    module_init(crystal_hybridswap_init);
core.c:3406    module_exit(crystal_hybridswap_exit);

core.c:3372      ret = zram_driver_init();     ← 调用 zram_drv.c 的实现
core.c:3390      zram_driver_exit();

zram_drv.c:6216  int zram_driver_init(void)     ← 真正的初始化
zram_drv.c:6282  void zram_driver_exit(void)
```

**所以你的 `Makefile` 里 `obj-m += zram.o`，而 `zram.o` 必须包含 `core.o`（提供 `module_init`）。**

### 3.2 初始化流程

`zram_driver_init()` 做的事（`zram_drv.c:6216` 起）：

```c
// 1. 注册 zram-control class（用于 hot_add / hot_remove）
class_register(&zram_control_class);

// 2. 注册 CPU hotplug 状态（per-CPU 压缩流）
zcomp_cpuhp_state = cpuhp_setup_state_multi(...);

// 3. 建 workqueue（回写用）
zram_read_wq = alloc_workqueue(...);

// 4. 创建 debugfs 节点
zram_debugfs_create();

// 5. ★ 注册块设备主设备号，占用 "zram" 这个名字
zram_major = register_blkdev(0, "zram");
if (zram_major <= 0) { pr_err("Unable to get major number\n"); ... return -EBUSY; }

// 6. 预创建 num_devices 个设备
while (num_devices != 0) {
    mutex_lock(&zram_index_mutex);
    ret = zram_add();              // ← 每个设备走 zram_add()
    mutex_unlock(&zram_index_mutex);
    num_devices--;
}
```

**`register_blkdev(0, "zram")` 这一步是「自建 zram」的标志**：它抢占了 `zram` 这个名字。所以必须先 `rmmod` 原厂 `zram.ko`。

### 3.3 块设备操作结构（最关键的接口）

`zram_drv.c:5809`：

```c
static const struct block_device_operations zram_devops = {
    .open = zram_open,                          // 打开 /dev/zramX
    .submit_bio = zram_submit_bio,              // ★ 读写主入口
    .swap_slot_free_notify = zram_slot_free_notify,  // ★ swap 层通知可释放
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 5, 0)
    .rw_page = zram_rw_page,                    // 5.x 的页读写快速路径
#endif
    .owner = THIS_MODULE
};
```

**`submit_bio` 是读写的总入口**，它内部再分发到读路径和写路径。SDDC 的所有接点都在这些路径上。

### 3.4 核心数据结构

`zram_drv.h:92`：

```c
struct zram_table_entry {
    union {
        unsigned long handle;      // zsmalloc handle
        unsigned long element;     // ZRAM_SAME 时的填充值
    };
    unsigned long flags;           // 各种标志位
    u64 memcg_id;                  // 归属的 memcg
#ifdef CONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_TRACK_ENTRY_ACTIME
    ktime_t ac_time;               // 最后访问时间（用于 idle 回收）
#endif
#ifdef CONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_WRITEBACK
    unsigned long prefetch_jiffies;
#endif
};
```

**每个 4 KiB 页对应一个 table entry**，索引是 page index。

`zram_drv.h:72` 的标志位：

```c
enum zram_pageflags {
    ZRAM_LOCK = ZRAM_FLAG_SHIFT,  // slot 被锁
    ZRAM_SAME,                    // ★ 整页是同一个填充值（零页压缩）
    ZRAM_WB,                      // 页在后面存储（写回）
    ZRAM_UNDER_WB,                // 正在写回
    ZRAM_HUGE,                    // 不可压缩
    ZRAM_IDLE,                    // 空闲
    ...
};
```

`zram_drv.h:225` 的设备结构：

```c
struct zram {
    struct zram_table_entry *table;     // 页表
    struct zs_pool *mem_pool;           // zsmalloc 池
    struct crystal_sddc *sddc;          // ★ SDDC 管理器
    struct zcomp *comps[ZRAM_MAX_COMPS];// 压缩后端
    struct gendisk *disk;

    struct mutex sddc_lifecycle_lock;   // ★ SDDC 生命周期锁
    spinlock_t sddc_lock;               // ★ SDDC 指针发布锁
    struct rw_semaphore init_lock;
    spinlock_t ref_lock;
    refcount_t refcount;
    struct completion ref_completion;
    bool removing;
    unsigned long limit_pages;
    ...
};
```

### 3.5 sysfs 接口（用户态看到的东西）

必须提供这些，否则 Android 的 init 脚本会失败：

| 节点 | 作用 | 谁用 |
|---|---|---|
| `/sys/block/zram0/disksize` | 设容量（触发初始化） | init / vold |
| `/sys/block/zram0/comp_algorithm` | 选压缩算法 | init / 用户 |
| `/sys/block/zram0/reset` | 重置设备 | init |
| `/sys/block/zram0/mem_limit` | 内存上限 | 可选 |
| `/sys/block/zram0/mm_stat` | 统计 | 监控 |
| `/sys/class/zram-control/hot_add` | 动态加设备 | 系统 |
| `/sys/class/zram-control/hot_remove` | 动态移除 | 系统 |

**Crystal 额外提供**（SDDC 相关）：

| 节点 | 作用 |
|---|---|
| `/sys/block/zram0/sddc_stat` | SDDC 统计（enabled/aliases/deltas/saved_bytes/decode_failures）|
| `/sys/block/zram0/hybridswap_report` | 回写状态 |
| `/sys/block/zram0/hybridswap_loglevel` | 日志级别 |

---

## 第 4 章：路线 A —— 在 Crystal 源码上改（推荐）

### 4.1 步骤 1：整理源码目录

```bash
mkdir -p ~/myzram/{src,include,tools}
cp -r /path/to/houji/drivers/crystal_hybridswap/* ~/myzram/src/
cp -r /path/to/houji/include/linux/crystal_hybridswap.h ~/myzram/include/linux/
```

### 4.2 步骤 2：改 Makefile 支持 out-of-tree

**这是必做的一步**。原版依赖 Kconfig，树外编译会产出空壳 KO。

```makefile
# ~/myzram/src/Makefile

# 树外编译时 Kconfig 不求值，用 ccflags 直接注入
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_WRITEBACK=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_ZRAM_TRACK_ENTRY_ACTIME=1

# 头文件路径
ccflags-y += -I$(src)
ccflags-y += -I$(src)/sddc
ccflags-y += -I$(src)/sddc/lz4kd
ccflags-y += -I$(src)/include

obj-m += zram.o

zram-y := zcomp.o zms.o zram_drv.o core.o param.o \
          zram_bridge.o memcg.o pressure.o stats.o

zram-y += sddc/crystal_sddc.o

zram-y += sddc/crystal_sddc_codec.o \
          sddc/lz4kd/lz4kd_encode.o \
          sddc/lz4kd/lz4kd_encode_delta.o \
          sddc/lz4kd/lz4kd_decode.o

# NEON 必需：lz4kd_encode.c 调用 crystal_lz4kd_repeat_end_neon()
ifeq ($(ARCH),arm64)
zram-y += sddc/lz4kd/lz4kd_neon.o
CFLAGS_REMOVE_sddc/lz4kd/lz4kd_neon.o += -mgeneral-regs-only
CFLAGS_sddc/lz4kd/lz4kd_neon.o += -ffreestanding -isystem $(shell $(CC) -print-file-name=include)
endif
```

### 4.3 步骤 3：剥离设备特定代码

houji 版有小米特定内容，检查这些文件：

```bash
# 找小米相关的
grep -rn 'houji\|xiaomi\|miui\|hyperos' src/*.c src/*.h | head -20
```

常见需要处理：

| 位置 | 内容 | 处理 |
|---|---|---|
| `hybridswap_autostart.sh` | 对接 HyperOS `dm-swapfile` | 删掉或改成通用 |
| `zram_drv.c` 里的 dm 设备发现 | 针对小米 extm | 改成可配置或删掉 |
| memcg 策略默认值 | 小米调参 | 改成中性值 |

### 4.4 步骤 4：首次编译验证

```bash
KT=~/kernel-6.6
SRC=~/myzram/src
CL=$ANDROID_CLANG

make -C "$KT" M="$SRC" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CL/clang" LD="$CL/ld.lld" AR="$CL/llvm-ar" \
  NM="$CL/llvm-nm" OBJCOPY="$CL/llvm-objcopy" \
  OBJDUMP="$CL/llvm-objdump" STRIP="$CL/llvm-strip" \
  KBUILD_MODPOST_WARN=1 modules
```

**首次编译基本不会一次成功。** 常见错误见附录 B。

---

## 第 5 章：路线 B —— 从标准 zram 自己加 SDDC（彻底掌控）

> 这条路工作量大得多。除非你有明确理由（比如 Crystal 的架构不适合你的设计），否则建议走 A。

### 5.1 标准 zram 的结构

从主线拿到的 6 个文件：

```
drivers/block/zram/
├── Kconfig       配置项
├── Makefile      obj-$(CONFIG_ZRAM) += zram.o
├── zcomp.c       压缩后端（桥接 crypto API）
├── zcomp.h       后端接口定义
├── zram_drv.c    驱动主体（约 2100 行）
└── zram_drv.h    数据结构
```

### 5.2 标准 zram 缺什么（你要补的）

| 标准 zram 有 | Crystal 额外有 | 你自建时要不要 |
|---|---|---|
| 基础压缩/解压 | SDDC alias/delta | **要**（核心目标） |
| zsmalloc 存储 | ZMS 打包回写 | 看需求 |
| memcg 记账（基础）| per-memcg 策略 + 强制换出 | 看需求 |
| sysfs 标准节点 | hybridswap_report / sddc_stat | **要**（至少 sddc_stat） |
| — | LZ4KD 编解码 | **要**（SDDC 依赖） |
| — | 压力通知（eventfd）| 看需求 |

### 5.3 自建的最小可行路径

```
第 1 步：让标准 zram 能在你的树上编出来（先跑通，不加任何东西）
第 2 步：加 LZ4KD 编解码（把 lz4kd_encode/decode 编进去，注册成 comp_algorithm 的一项）
第 3 步：加 delta 接口（zcomp_backend_ops 里加 compress_delta/decompress_delta）
第 4 步：加 SDDC 状态机（crystal_sddc.c 直接拿来用）
第 5 步：接六条路径（store/read/free/reset/disksize/记账）
第 6 步：加 sddc_stat sysfs
```

**每一步都要能编过 + 能跑，不要一次全加。**

### 5.4 第 2 步详解：怎么加一个压缩算法

标准 zram 的 `zcomp.c` 用 crypto API：

```c
// 标准 zram 的做法：找内核 crypto 里的压缩算法
static const struct zcomp_ops *backends[] = {
    &zcomp_lzo_ops, &zcomp_lz4_ops, &zcomp_zstd_ops, ...
};
```

Crystal 改成了自有后端，不走 crypto API：

```c
// Crystal 的做法：自己的后端表
static const struct zcomp_backend backends[] = {
    { "lz4kd", &lz4kd_pure_backend_ops },
    { "lz4kds", &lz4kds_backend_ops },     // ← 带 delta
    ...
};
```

**你需要决定**：

- 走 crypto API（省事，但 delta 接口放不进去，因为 crypto 没有 delta 概念）
- 走自有后端（灵活，但要自己管 stream 生命周期）

**SDDC 必须走自有后端**，因为 delta 需要「参考页」参数，crypto API 没这个。

### 5.5 第 3 步详解：delta 接口怎么定义

`zcomp.h:23-36`（Crystal 的定义，可直接借用）：

```c
struct zcomp_backend_ops {
    int (*create)(struct zcomp_strm *zstrm, const char *name);
    void (*destroy)(struct zcomp_strm *zstrm);
    int (*compress)(struct zcomp_strm *zstrm, const void *src,
                    unsigned int src_len, void *dst, unsigned int *dst_len);
    int (*decompress)(struct zcomp_strm *zstrm, const void *src,
                      unsigned int src_len, void *dst, unsigned int *dst_len);

    /* ★ delta 相关 */
    int (*compress_delta)(struct zcomp_strm *zstrm,
                          const void *ref, unsigned int ref_len,   // 参考页
                          const void *src, unsigned int src_len,   // 当前页
                          void *dst, unsigned int *dst_len,
                          unsigned int out_limit);                 // 输出上限
    int (*decompress_delta)(struct zcomp_strm *zstrm,
                            const void *src, unsigned int src_len, // delta 数据
                            const void *ref, unsigned int ref_len, // 参考页
                            void *dst, unsigned int *dst_len);
    /* @restored 借用后端 stream 的缓冲，直到解锁或下次 delta 操作 */
    int (*decompress_delta_borrowed)(struct zcomp_strm *zstrm, ...);
};
```

**`out_limit` 很重要**：delta 编码要有上限，不然「差异太大」时会产出比原页更大的结果。SDDC 的准入判定靠它。

---

## 第 6 章：把 SDDC 接进你的 zram（详细步骤）

不管 A 还是 B，接入方式一样。以下接点位置来自 `source-xiaomi/` 实测。

### 6.1 第一步：加数据结构

在 `zram_drv.h` 的 `struct zram` 里加：

```c
struct zram {
    ...
    struct crystal_sddc *sddc;          // SDDC 管理器（zram_drv.h:228）

    struct mutex sddc_lifecycle_lock;   // 生命周期锁（zram_drv.h:232）
    spinlock_t sddc_lock;               // 指针发布锁（zram_drv.h:234）
    ...
};
```

### 6.2 第二步：初始化时创建（disksize 写入触发）

位置：`disksize_store()` 函数末尾，**在所有 `zcomp_create()` 之后**。

```c
// zram_drv.c:5652（参考位置）
for (prio = 0; prio < ZRAM_MAX_COMPS; prio++) {
    if (!zram->comp_algs[prio]) continue;
    comp = zcomp_create(zram->comp_algs[prio]);
    if (IS_ERR(comp)) { ... goto out_free_comps; }
    zram->comps[prio] = comp;
    zram->num_active_comps++;
}

// ★ SDDC 必须在压缩后端就绪后创建
err = crystal_sddc_create(zram, nr_pages);
if (err) goto out_free_comps;

zram->disksize = disksize;
set_capacity_and_notify(zram->disk, zram->disksize >> SECTOR_SHIFT);
```

**创建的 5 个条件**（`crystal_sddc.c:2540`）：

```c
if (PAGE_SHIFT != 12 ||                    // 4 KiB 页
    !nr_pages ||
    nr_pages > CRYSTAL_SDDC_MAX_SLOTS ||
    !zram->comps[ZRAM_PRIMARY_COMP] ||
    !zcomp_supports_delta(zram->comps[ZRAM_PRIMARY_COMP]))
    return 0;                              // ← 静默降级，不报错！
```

### 6.3 第三步：写路径接点

位置：`zram_write_bvec()` 或 `zram_submit_bio()` 的写分支。

```c
// zram_drv.c:4152
crystal_sddc_slot_stored_locked(zram, index);   // 通知：这个 slot 写好了，可以拿去当候选

// zram_drv.c:4178
struct crystal_sddc_job_key sddc_key;
crystal_sddc_job_key_locked(zram, index, &sddc_key);
// ... 后续可能 queue_observation(&sddc_key) 做异步相似度扫描
```

### 6.4 第四步：读路径接点

位置：`zram_read_page()` / `zram_bvec_read()`。

```c
// zram_drv.c:3811
if (crystal_sddc_slot_allocated_locked(zram, index)) {
    ret = crystal_sddc_read_page_locked(zram, page, index);   // ★ SDDC 负责还原
    if (ret == -EAGAIN)
        goto retry;                    // 状态在变，重试
} else {
    /* 普通 zspool 读 */
    ret = zram_read_from_zspool(zram, page, index);
    zram_slot_unlock(zram, index);
}
```

**这是 LZ4KDS 读回 bug 的高发区**，改这里要格外小心。

### 6.5 第五步：释放路径接点

位置：`zram_free_page()`。

```c
// zram_drv.c:3641
enum crystal_sddc_kind sddc_kind;
sddc_kind = crystal_sddc_slot_free_locked(zram, index, reason);

if (!handle && sddc_kind == CRYSTAL_SDDC_NONE)
    return;                    // 没有底层对象，不用 free

// 根据 kind 决定怎么释放：
//   NONE  → 正常 zs_free(handle)
//   ALIAS → 只减引用计数，不能 zs_free（其他页还在用）
//   DELTA → 释放 delta 对象，但基准页引用要单独处理
```

**顺序错了会导致悬空引用 → 读回读到错误页/零页。**（参见第 8 章 bug 分析）

### 6.6 第六步：reset 与销毁

```c
// zram_drv.c:5531  reset 时
crystal_sddc_stop(zram);        // 停掉，但对象还在（可以重新 disksize 起来）

// zram_drv.c:3597  设备移除时
crystal_sddc_destroy(zram);     // 彻底销毁
```

### 6.7 第七步：统计接点

```c
// zram_drv.c:581  记账（mm_stat 压缩大小）
account->sddc = crystal_sddc_accounted_size_locked(zram, index, ...);

// zram_drv.c:490  snapshot（快照，用于并发校验）
crystal_sddc_snapshot_locked(zram, index, &snapshot->sddc);

// zram_drv.c:3280  统计输出（sddc_stat sysfs）
crystal_sddc_get_stats(zram, &stats);
```

### 6.8 第八步：加 sddc_stat sysfs 节点

```c
// 参考 zram_drv.c:3274 的 sddc_stat_show（3279 起调 crystal_sddc_get_stats）
static ssize_t sddc_stat_show(struct device *dev,
                              struct device_attribute *attr, char *buf)
{
    struct zram *zram = dev_to_zram(dev);
    struct crystal_sddc_stats_snapshot s;
    crystal_sddc_get_stats(zram, &s);
    // 输出 enabled / aliases / deltas / saved_bytes / decode_failures ...
}

static DEVICE_ATTR_RO(sddc_stat);      // zram_drv.c:3578
```

挂到 `zram_disk_attr_groups` 里，用户才能 `cat /sys/block/zram0/sddc_stat`。

**`sddc_stat` 实际输出 46 个字段**（`zram_drv.c:3281-3340`），这是你排查问题的核心工具：

| 分组 | 字段 | 看什么 |
|---|---|---|
| **启用** | `enabled` | 1=SDDC 生效；0=静默降级了 |
| 队列 | `queued` `coalesced` `dropped` `pending` `pending_max` | 观察任务是否堆积 |
| 观察 | `observed` `stale` `indexed` | 相似页扫描进度 |
| 引用 | `refs` `ref_bytes` | 当前驻留的基准页数量与占用 |
| **alias 效果** | `aliases` `alias_attempts` `alias_hits` | 命中率 = hits/attempts |
| **delta 效果** | `deltas` `delta_attempts` `delta_hits` `delta_matches` | 命中率同上 |
| **delta 被拒原因** | `delta_small_rejects` `delta_no_gain` `delta_proof_failures` | 收益不足 / 校验失败 |
| **节省** | `saved_bytes` `saved_bytes_total` | 总节省字节 |
| 回写 | `wb_deltas` `wb_delta_bytes` `wb_aliases` `wb_alias_bytes` | ZMS 回写中的 SDDC 表示 |
| **释放分类** | `released_aliases` `released_deltas` `released_*_saved_bytes`（9 个细项）| 按释放原因分账 |
| **错误** | `conversion_failures` `decode_failures` `flatten_failures` `limit_rejects` | **`decode_failures` 必须持续为 0** |

> 排查读回 bug 时重点盯：`decode_failures`（解码失败）、`delta_proof_failures`（delta 校验失败）、
> `released_deltas` vs `deltas` 的差值（是否有引用没释放干净）。

### 6.9 第九步：锁序（最容易死锁的地方）

三个锁的层级：

```
sddc_lifecycle_lock (mutex)
  └── init_lock (rw_semaphore)
        └── sddc_lock (spinlock)
              └── per-slot lock (table[index].flags 的 ZRAM_LOCK bit)
                    └── index_lock (SDDC hash 桶)
```

源码警告（`crystal_sddc.c:1304`）：

> Insertion runs under index_lock, while publication runs under a slot lock and then takes index_lock. **Never wait for the slot here**: a blocking acquisition would invert that order and can deadlock against a concurrent publication.

**规则**：持有 `index_lock` 时不能用阻塞的 slot lock 获取。要用 `bit_spin_trylock` 这类非阻塞版本，失败就放弃本次操作（后续再重试）。

---

## 第 7 章：编译与验证

### 7.1 编译

```bash
KT=~/kernel-6.6
SRC=~/myzram/src
CL=$ANDROID_CLANG

make -C "$KT" M="$SRC" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CL/clang" LD="$CL/ld.lld" AR="$CL/llvm-ar" \
  NM="$CL/llvm-nm" OBJCOPY="$CL/llvm-objcopy" \
  OBJDUMP="$CL/llvm-objdump" STRIP="$CL/llvm-strip" \
  KBUILD_MODPOST_WARN=1 modules 2>&1 | tee build.log
```

### 7.2 验证四步（必做）

```bash
KO=$SRC/zram.ko

# ① 大小：带 SDDC 通常 1.5-3 MB，空壳只有几百 KB
ls -lh $KO

# ② SDDC 符号必须存在
nm $KO | grep crystal_sddc | head -10
# 期望：crystal_sddc_create / _read_page_locked / _slot_free_locked / _get_stats ...

# ③ 算法名必须注册
strings $KO | grep -E '^lz4kds?$'

# ④ vermagic 匹配目标内核
modinfo $KO | grep vermagic
```

**任一不满足就说明没编进去**，回到第 4.2 节检查 Makefile。

### 7.3 符号闸门（上真机前）

```bash
# 用设备回传的 kallsyms 验证所有导入符号都在
nm -u $KO | awk '{print $NF}' | while read sym; do
    grep -q " $sym$" device_kallsyms.txt || echo "MISSING: $sym"
done
```

### 7.4 CRC 对齐（CONFIG_MODVERSIONS=y 时必需）

```bash
python3 tools/crc_align.py $KO device_zram.ko
```

它把新 KO 的 `__versions` 段 CRC 逐符号改成设备原厂 KO 的值。

---

## 第 8 章：打包成可侧载的模块

### 8.1 模块结构（xiaomi 路线）

```
lz4kds-模块.zip
├── module.prop
├── customize.sh          设备/内核门禁 + sha256 指纹
├── post-fs-data.sh       热替换逻辑（含 safe_mode / 熔断 / 回滚）
├── service.sh            开机后记录状态
├── uninstall.sh          清理
├── zram.ko               ★ 你的产物
├── zram.ko.sha256        指纹
├── .target_device        设备代号（防发错包）
├── .target_kernel        内核版本
└── stock/
    ├── zram.ko           原厂（回滚救生索）
    └── zsmalloc.ko       原厂依赖
```

### 8.2 post-fs-data.sh 的 9 层安全（必须实现）

```
1. disable 标记           → 退出
2. safe_mode（bootreason 归因）→ 跳过本次
3. boot_count ≥3          → 自动禁用
4. 设备/内核指纹门禁       → 防发错包
5. sha256 校验            → 防 KO 损坏
6. 空闲四重检查            → disksize=0 + initstate=0 + 不在 swaps + 无 holders
7. 依赖补载               → zsmalloc 没载用随包 stock
8. 失败回滚               → insmod stock/zram.ko
9. stock 随包             → 永远有料可回滚
```

**第 6 条的四重检查不能省**（少了会热替换到正在用的 zram 上，直接崩）：

```sh
DS=$(cat /sys/block/zram0/disksize 2>/dev/null)
[ "$DS" = "0" ] || { log "已初始化，拒绝"; exit 0; }
[ "$(cat /sys/block/zram0/initstate)" = "0" ] || exit 0
grep -q 'zram' /proc/swaps && exit 0
[ -z "$(ls /sys/block/zram0/holders 2>/dev/null)" ] || exit 0
```

### 8.3 用本工作区一键打包

```bash
bash pipeline.sh devices/<设备名>
# → dist/lz4kds侧载-xiaomi-<日期>-<hash>.zip
```

---

## 第 9 章：维护自己的分支（版本管理建议）

### 9.1 目录布局建议

```
myzram/
├── src/                    你的源码
├── include/linux/          补充头文件
├── patches/                你对上游的改动（每个改动一个 .patch）
├── docs/                   你的笔记
├── build.sh                编译脚本
├── tools/                  验证工具
└── CHANGELOG.md            记录每次改动与原因
```

### 9.2 用 git 管理改动

```bash
cd myzram
git init
git add src include
git commit -m "初始：Crystal v1.3.7 + houji 适配"

# 每次改动
git checkout -b fix/read-page-bug
# 改代码
git commit -am "fix: 读路径 -EAGAIN 重试上限"
# 验证通过后
git checkout main && git merge fix/read-page-bug
```

### 9.3 记录上游基线（很重要）

```bash
# 记录你从哪个版本 fork 的
echo "基于 2108282/zram-lz4kds-sddc-houji-6.1 @ commit xxx" > UPSTREAM.txt
sha256sum src/sddc/crystal_sddc.c >> UPSTREAM.txt
```

这样以后上游更新了，你知道自己改了什么、要不要跟进。

---

## 附录 A：完整文件清单

### A.1 路线 A（基于 Crystal）需要 31 + 1 个文件

```
src/
├── Makefile                       ← 要改（out-of-tree）
├── Kconfig                         参考用
├── zram_drv.c      178 KB   块设备 + 六条接点
├── zram_drv.h       10 KB   数据结构
├── core.c          120 KB   模块入口 + 策略
├── memcg.c          92 KB   memcg 记账
├── zms.c            80 KB   ZMS 回写
├── zram_bridge.c    44 KB   桥接
├── stats.c          43 KB   统计
├── zcomp.c          13 KB   压缩前端
├── pressure.c      6.7 KB   压力通知
├── param.c         3.5 KB   模块参数
├── crystal_hybridswap_internal.h  31 KB
├── README.md / README_ZH.md        文档
└── sddc/
    ├── DESIGN.md          30 KB  ★ 必读
    ├── crystal_sddc.c    163 KB
    ├── crystal_sddc.h     10 KB
    ├── crystal_sddc_codec.c
    ├── crystal_sddc_codec_test.c
    └── lz4kd/
        ├── lz4kd.h
        ├── lz4kd_encode.c
        ├── lz4kd_encode_delta.c      ★ SDDC 核心
        ├── lz4kd_encode_private.h
        ├── lz4kd_decode.c
        ├── lz4kd_neon.c              ★ 必需，不编会 undefined
        ├── lz4kd_neon.h
        └── lz4kd_private.h

include/linux/
└── crystal_hybridswap.h            pressure.c 需要
```

### A.2 路线 B（从标准 zram 自建）起点

```
linux/drivers/block/zram/
├── Kconfig        约 60 行
├── Makefile       约 10 行
├── zcomp.c       约 550 行
├── zcomp.h        约 80 行
├── zram_drv.c   约 2100 行    ← 你要在这上面加 SDDC
└── zram_drv.h    约 130 行
```

**还要额外拿**：`sddc/` 整个目录 + `lz4kd/` 整个目录（从 Crystal 拿）。

---

## 附录 B：踩坑记录

### B.1 编译成功但 KO 是空壳

**症状**：`make` 显示成功，`zram.ko` 只有几百 KB，`insmod` 后没有 `/sys/block/zram0`。

**原因**：Makefile 用了 `obj-$(CONFIG_CRYSTAL_HYBRIDSWAP)`，树外编译时 Kconfig 不求值，变量为空 → `obj-n` → 一个文件都不编。

**修复**：改成 `obj-m += zram.o` + `ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP=1`。

### B.2 undefined symbol: crystal_lz4kd_repeat_end_neon

**原因**：没编 `lz4kd_neon.o`。`lz4kd_encode.c:282` 会调用它。

**修复**：Makefile 加 `ifeq ($(ARCH),arm64)` 分支编入，并移除 `-mgeneral-regs-only`。

### B.3 编译报 crystal_hybridswap.h 找不到

**原因**：`pressure.c` 用 `#include <linux/crystal_hybridswap.h>`，但树外编译时这个路径不存在。

**修复**：把文件放到 `src/include/linux/`，Makefile 加 `-I$(src)/include`。

注意：它用 `__has_include()` 保护，缺了也能编，但压力通知会退化成返回 `-ENODEV` 的桩函数。

### B.4 SDDC 没启用但也没报错

**原因**：`crystal_sddc_create()` 的 5 个条件之一不满足，函数 `return 0`（成功）但不创建。

**排查**：

```sh
cat /sys/block/zram0/sddc_stat | grep enabled     # 期望 1
cat /sys/block/zram0/comp_algorithm               # 方括号必须在 lz4kds
getconf PAGE_SIZE                                 # 必须 4096
dmesg | grep -i sddc                              # 看有无 allocation failed
```

### B.5 刷入后系统起不来

**可能原因**：热替换时 zram 正在使用中。

**检查** `post-fs-data.sh` 的四重检查是否都实现了（§8.2 第 6 条）。

**救援**：

```sh
# 进 recovery 或 fastboot
adb shell rm -rf /data/adb/modules/lz4kds_sidecar/
# 或刷回原厂 boot.img
```

### B.6 LZ4KDS 读回读到错误页/零页

**这是已知 bug**（whitewhale0612 README 明确警告）。

**三个可疑点**：

1. `zram_drv.c:3811-3814` 的 `-EAGAIN` 走 `goto retry`，重试路径的终止条件是否严密
2. 基准页被释放后，delta 的代际 cookie 校验是否够
3. `zs_map_object` 在同页并发访问时的映射生命周期

**排查建议**：加 `decode_failures` 计数，跑压力测试看是否增长。

### B.7 锁序死锁

**症状**：高负载下系统卡死，`dmesg` 有 hung task 警告。

**原因**：在持有 `index_lock` 时阻塞等待 slot lock，与并发 publication 形成 AB-BA。

**修复**：用 `bit_spin_trylock` 非阻塞版本，失败就放弃本次操作。

---

## 附录 C：快速命令速查

```bash
# 拿源码
git clone --depth=1 https://github.com/2108282/zram-lz4kds-sddc-houji-6.1

# 拿内核树
git clone --depth=1 -b android15-6.6 https://android.googlesource.com/kernel/common ~/kernel-6.6

# 拿工具链
bash tools/get-clang.sh --mirror tuna
export ANDROID_CLANG=$(ls -d work/clang/clang-r*/bin | tail -1)

# 编译
make -C ~/kernel-6.6 M=~/myzram/src ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC=$ANDROID_CLANG/clang LD=$ANDROID_CLANG/ld.lld \
  NM=$ANDROID_CLANG/llvm-nm OBJCOPY=$ANDROID_CLANG/llvm-objcopy \
  KBUILD_MODPOST_WARN=1 modules

# 验证
ls -lh ~/myzram/src/zram.ko
nm ~/myzram/src/zram.ko | grep crystal_sddc | head
strings ~/myzram/src/zram.ko | grep -E '^lz4kds?$'
modinfo ~/myzram/src/zram.ko | grep vermagic

# 打包
bash pipeline.sh devices/<设备名>
```
