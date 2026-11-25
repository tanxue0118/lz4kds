# 把 SDDC 编进 zram.ko：完整实施手册

> 本文回答一个问题：**SDDC 到底是怎么被编进 `zram.ko` 的，我要自己动手需要改哪里、注意什么。**
>
> 基于本工作区 `source-xiaomi/`（Crystal HybridSwap）实测源码，所有行号与函数名均来自真实文件。
> 最后更新：2026-11-25

---

## 0. 一句话原理

> SDDC 不是独立模块，它是 `zram.ko` 里的一个 `.o`。
> **要让 SDDC 生效 = 让 zram 的六条接点（store/read/free/reset/disksize/recompress）在关键位置调用 `crystal_sddc_*()`。**

---

## 1. 先搞清三条链路

SDDC 能工作，依赖三条链路同时成立。断任何一条，SDDC 静默降级为普通压缩。

```
链路①  编译链接
  Makefile 里 zram-y += sddc/crystal_sddc.o
       ↓
  符号进入 zram.ko

链路②  压缩后端支持 delta
  comp_algorithm 写成 "lz4kds"（不是 lz4kd）
       ↓
  zcomp.c 的 lz4kds_backend_ops 带 .compress_delta/.decompress_delta
       ↓
  zcomp_supports_delta() 返回 true

链路③  运行时创建 SDDC 管理器
  disksize 写入触发 zram_init()
       ↓
  crystal_sddc_create(zram, nr_pages) 返回 0 且 zram->sddc != NULL
       ↓
  六条接点开始走 SDDC 分支
```

---

## 2. 链路①：编译链接（Makefile）

### 2.1 需要编进去的文件

```
zram-y += sddc/crystal_sddc.o          ← SDDC 管理器本体（163 KB）
zram-y += sddc/crystal_sddc_codec.o    ← 字节级编解码适配
zram-y += sddc/lz4kd/lz4kd_encode.o    ← LZ4KD 编码
zram-y += sddc/lz4kd/lz4kd_encode_delta.o  ← delta 编码（关键）
zram-y += sddc/lz4kd/lz4kd_decode.o    ← 解码
zram-y += sddc/lz4kd/lz4kd_neon.o      ← NEON 加速（arm64）
```

### 2.2 NEON 是必需的，不是可选的

`lz4kd_encode.c:282` 会调用：

```c
return crystal_lz4kd_repeat_end_neon(q, r, in_end);
```

这个函数实现在 `lz4kd_neon.c`。**不编它 → 链接期 undefined symbol。**

Makefile 里必须这样写：

```makefile
ifeq ($(ARCH),arm64)
zram-y += sddc/lz4kd/lz4kd_neon.o
# 移除 -mgeneral-regs-only，允许 NEON intrinsics
CFLAGS_REMOVE_sddc/lz4kd/lz4kd_neon.o += -mgeneral-regs-only
CFLAGS_sddc/lz4kd/lz4kd_neon.o += -ffreestanding -isystem $(shell $(CC) -print-file-name=include)
endif
```

**为什么要 `-mgeneral-regs-only` 移除**：内核默认禁止浮点/SIMD 寄存器（中断上下文会破坏）。但 `lz4kd_encode.c` 用了 `kernel_neon_begin()/kernel_neon_end()` 包裹，是安全的。不移除这个 flag，NEON intrinsics 编不过。

### 2.3 out-of-tree 编译的坑

如果走 `make M=` 树外编译，**Kconfig 不求值**。所以：

```makefile
# ✗ 错：树外编译时 CONFIG_CRYSTAL_HYBRIDSWAP 为空，一个文件都不编
obj-$(CONFIG_CRYSTAL_HYBRIDSWAP) += zram.o

# ✓ 对：直接注入宏 + 无条件编
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1
ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC_LZ4KD=1
obj-m += zram.o
```

**症状**：如果漏了这一步，`make` 会“成功”，但产出的 `zram.ko` 只有几 KB（空壳），`insmod` 后没有 `/sys/block/zram0`。

### 2.4 头文件搜索路径

源码里有相对 include：

```c
// sddc/crystal_sddc_codec.c
#include "crystal_sddc.h"          // 同目录
#include "sddc/lz4kd/lz4kd.h"      // 跨目录
// pressure.c
#include <linux/crystal_hybridswap.h>  // 看起来像内核头，实际是本地副本
```

必须补：

```makefile
ccflags-y += -I$(src)
ccflags-y += -I$(src)/sddc
ccflags-y += -I$(src)/sddc/lz4kd
ccflags-y += -I$(src)/include     # ← crystal_hybridswap.h 在这
```

`pressure.c` 用了 `__has_include()` 保护，缺了也能编，但 `crystal_hybridswap_signal_pressure()` 会退化成返回 `-ENODEV` 的桩函数。

---

## 3. 链路②：压缩后端必须支持 delta

### 3.1 `lz4kd` 和 `lz4kds` 是两个不同算法

`zcomp.c:38-41` 的后端注册表：

```c
"lz4kd",     ← 纯 LZ4KD，只有 .compress/.decompress
"lz4kds",    ← LZ4KD + SDDC，额外有 .compress_delta/.decompress_delta
```

对比两个 backend ops：

```c
// lz4kd（纯）：只有基础压缩
static const struct zcomp_backend_ops lz4kd_pure_backend_ops = {
    .create = ..., .destroy = ...,
    .compress = ..., .decompress = ...,
    // 没有 delta 系列
};

// lz4kds（带 SDDC）：多了 delta
static const struct zcomp_backend_ops lz4kds_backend_ops = {
    .create = lz4kds_backend_create,
    .destroy = lz4kds_backend_destroy,
    .compress = lz4kds_backend_compress,
    .decompress = lz4kds_backend_decompress,
    .compress_delta = lz4kds_backend_compress_delta,        // ★
    .decompress_delta = lz4kds_backend_decompress_delta,    // ★
    .decompress_delta_borrowed = lz4kds_backend_decompress_delta_borrowed, // ★
};
```

**所以 `comp_algorithm` 必须是 `lz4kds`，写成 `lz4kd` SDDC 不会启用。**

### 3.2 delta 接口签名（`zcomp.h:23-36`）

```c
struct zcomp_backend_ops {
    int (*compress_delta)(struct zcomp_strm *zstrm,
                          const void *ref, unsigned int ref_len,
                          const void *src, unsigned int src_len,
                          void *dst, unsigned int *dst_len,
                          unsigned int out_limit);
    int (*decompress_delta)(struct zcomp_strm *zstrm,
                            const void *src, unsigned int src_len,
                            const void *ref, unsigned int ref_len,
                            void *dst, unsigned int *dst_len);
    /* @restored borrows backend storage until this stream is unlocked
     * or another delta operation is issued on it. */
    int (*decompress_delta_borrowed)(...);
};
```

**`decompress_delta_borrowed` 的语义要注意**：它借用后端 stream 的内部缓冲，**在 stream 解锁或下次 delta 操作前有效**。所以调用方必须在锁内用完，不能把指针带出去 —— 这是 SDDC 读路径容易出 bug 的地方之一。

---

## 4. 链路③：运行时创建 SDDC 管理器

### 4.1 创建时机：写 `disksize` 时

`zram_drv.c:5652`，在 `disksize_store()` 的最后：

```c
for (prio = 0; prio < ZRAM_MAX_COMPS; prio++) {
    if (!zram->comp_algs[prio]) continue;
    comp = zcomp_create(zram->comp_algs[prio]);   // 先创建压缩后端
    if (IS_ERR(comp)) { ... goto out_free_comps; }
    zram->comps[prio] = comp;
    zram->num_active_comps++;
}

err = crystal_sddc_create(zram, nr_pages);        // ★ SDDC 在压缩后端之后就绪后创建
if (err) goto out_free_comps;

zram->disksize = disksize;
set_capacity_and_notify(zram->disk, zram->disksize >> SECTOR_SHIFT);
```

**顺序很关键**：SDDC 依赖 `zram->comps[ZRAM_PRIMARY_COMP]`，所以必须在 `zcomp_create()` 之后。

### 4.2 创建时的 6 个启用条件（`crystal_sddc.c:2534-2544`）

```c
if (!zram) return -EINVAL;
lockdep_assert_held(&zram->sddc_lifecycle_lock);
lockdep_assert_held_write(&zram->init_lock);
if (zram->sddc) return -EINVAL;

// ↓ 这行是「静默降级」的总闸门
if (PAGE_SHIFT != 12 ||                          // ① 必须 4 KiB 页
    !nr_pages ||                                 // ② disksize 非零
    nr_pages > CRYSTAL_SDDC_MAX_SLOTS ||         // ③ 容量不超上限
    !zram->comps[ZRAM_PRIMARY_COMP] ||           // ④ 主压缩后端存在
    !zcomp_supports_delta(zram->comps[ZRAM_PRIMARY_COMP]))  // ⑤ 后端支持 delta
    return 0;                                    // ← 返回 0（成功）但不创建！

sddc = kzalloc(sizeof(*sddc), GFP_KERNEL);
if (!sddc) {
    pr_warn("%s: SDDC manager allocation failed; using ordinary compression\n",
            zram->disk->disk_name);
    return 0;                                    // ← 内存不足也静默降级
}
```

**注意这里的陷阱**：条件不满足时 `return 0`（成功），**不是返回错误**。设计意图是“SDDC 是机会性优化，不行就普通压缩”，但这也意味着**你很难发现 SDDC 没启用**。

### 4.3 怎么确认 SDDC 真的启用了

| 检查项 | 命令 | 期望 |
|---|---|---|
| 算法名 | `cat /sys/block/zram0/comp_algorithm` | 方括号在 `lz4kds` 上 |
| SDDC 管理器 | `cat /sys/block/zram0/sddc_stat` | 出现 `enabled: 1` |
| 页大小 | `getconf PAGE_SIZE` | `4096` |
| 内核日志 | `dmesg \| grep -i sddc` | 无 “allocation failed” |

如果 `sddc_stat` 里 `enabled: 0`，按 4.2 的 5 个条件逐个排查。

### 4.4 销毁时机

```c
zram_drv.c:5531   crystal_sddc_stop(zram);    // reset 时停（还活着，可重启）
zram_drv.c:3597   crystal_sddc_destroy(zram); // 设备移除时销毁
```

`stop` 与 `destroy` 分开的设计意图：reset 后还能重新 `disksize` 起来，不必重新分配整个管理器。

---

## 5. 六条接点：SDDC 在哪里被调用

这是**你改 SDDC 时最需要看的部分**。所有调用点都在 `zram_drv.c`。

### 5.1 写路径（store）

```c
// zram_drv.c:4152（另一处 5152）
crystal_sddc_slot_stored_locked(zram, index);   // slot 写入完成，通知 SDDC 观察
// zram_drv.c:4178
crystal_sddc_job_key_locked(zram, index, &sddc_key);
```

**作用**：页写入后，SDDC 记录它的 hash，作为后续 delta 判定的候选。

### 5.2 读路径（read）

```c
// zram_drv.c:3811-3814
if (crystal_sddc_slot_allocated_locked(zram, index)) {
    ret = crystal_sddc_read_page_locked(zram, page, index);
    if (ret == -EAGAIN)
        goto retry;          // ← 走 retry 标签，不是本地计数
}
```

**这是 LZ4KDS 读回 bug 的可疑位置**：`-EAGAIN` 只重试 4 次，超过就走普通路径或返回错误。如果 SDDC 状态机在并发下给出错误的 `-EAGAIN`，可能读到错误页。

### 5.3 释放路径（free）

```c
// zram_drv.c:3641
sddc_kind = crystal_sddc_slot_free_locked(zram, index, reason);
```

**返回值 `sddc_kind` 决定后续行为**：

- `CRYSTAL_SDDC_NONE` → 普通 slot，正常 zs_free
- `CRYSTAL_SDDC_ALIAS` → 只减引用计数，**不能** zs_free 底层对象
- `CRYSTAL_SDDC_DELTA` → 释放 delta 对象，但基准页引用要单独处理

**这是最容易出内存 bug 的地方**：释放顺序错了会导致基准页被提前释放，alias/delta 变成悬空引用 → 读回读到错误页或零页。

### 5.4 重置路径（reset）

```c
// zram_drv.c:5531
crystal_sddc_stop(zram);
```

### 5.5 容量路径（disksize）

```c
// zram_drv.c:5652
err = crystal_sddc_create(zram, nr_pages);
```

### 5.6 记账路径

```c
// zram_drv.c:581
account->sddc = crystal_sddc_accounted_size_locked(zram, index, ...);
```

用于 `mm_stat` 的压缩大小统计 —— alias/delta 的实际占用和逻辑大小不同。

### 5.7 回写路径（ZMS）

```c
// zram_drv.c:1999-2180 一大段
if (crystal_sddc_slot_allocated_locked(zram, cur_index)) {
    if (crystal_sddc_native_wb_kind(...)) {
        err = crystal_sddc_native_wb_capture(...);      // 捕获 SDDC 原始表示
        err = crystal_sddc_flatten(...);                // 或压平成普通流
    }
    crystal_sddc_native_wb_install_locked(...);
    crystal_sddc_native_wb_finalize_locked(...);
}
```

**两种回写策略**：

- `native_wb`：delta/alias 原样写盘（省空间，但要维护引用状态）
- `flatten`：压平成普通压缩流再写（简单，但失去去重收益）

---

## 6. 数据结构：SDDC 挂在 zram 的哪里

`zram_drv.h:225` 起：

```c
struct zram {
    struct zram_table_entry *table;
    struct zs_pool *mem_pool;
    struct crystal_sddc *sddc;          // ★ SDDC 管理器指针

    struct zcomp *comps[ZRAM_MAX_COMPS];
    struct gendisk *disk;

    /* Serialize SDDC creation, quiescing, and teardown. */
    struct mutex sddc_lifecycle_lock;   // ★ 生命周期锁
    /* Protect SDDC pointer publication and operation admission. */
    spinlock_t sddc_lock;               // ★ 指针发布与准入锁

    struct rw_semaphore init_lock;
    spinlock_t ref_lock;
    refcount_t refcount;
    struct completion ref_completion;
    bool removing;
    unsigned long limit_pages;
    ...
};
```

### 三个锁的层级（改代码前必读）

```
sddc_lifecycle_lock  (mutex)
    └── init_lock  (rw_semaphore, write)
            └── sddc_lock  (spinlock)
                    └── per-slot lock  (zram->table[index].flags 的 ZRAM_LOCK bit)
                            └── index_lock  (SDDC 内部的 hash 桶锁)
```

源码注释明确警告（`crystal_sddc.c:1304-1308`）：

> Insertion runs under index_lock, while publication runs under a slot lock and then takes index_lock. **Never wait for the slot here**: a blocking acquisition would invert that order and can deadlock against a concurrent publication.

**所以你加新代码时**：不能在持有 `index_lock` 时阻塞等待 slot lock。

---

## 7. 实际动手：从零编出一个带 SDDC 的 zram.ko

### 7.1 前置条件

```bash
# ① Linux 环境（WSL2 也行）
uname -s   # 必须是 Linux

# ② Android clang
export ANDROID_CLANG=/path/to/clang-r536225/bin

# ③ 目标内核树（4 KiB 页 + CONFIG_ZRAM=m）
ls <kernel-tree>/drivers/block/zram/
```

### 7.2 最小编译命令

```bash
KT=/path/to/kernel-tree
SRC=/path/to/lz4kds/source-xiaomi
CL=$ANDROID_CLANG

make -C "$KT" M="$SRC" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CL/clang" LD="$CL/ld.lld" AR="$CL/llvm-ar" \
  NM="$CL/llvm-nm" OBJCOPY="$CL/llvm-objcopy" \
  OBJDUMP="$CL/llvm-objdump" STRIP="$CL/llvm-strip" \
  KBUILD_MODPOST_WARN=1 modules
```

产物：`$SRC/zram.ko`

### 7.3 验证产物真的带了 SDDC

```bash
# ① 大小合理（带 SDDC 约 1.5-3 MB，空壳几百 KB）
ls -lh $SRC/zram.ko

# ② 符号检查：SDDC 函数必须在里面
nm $SRC/zram.ko | grep crystal_sddc | head -10
# 期望看到：crystal_sddc_create / _read_page_locked / _slot_free_locked ...

# ③ 字符串检查：delta 后端注册名
strings $SRC/zram.ko | grep -E '^lz4kds?$'

# ④ vermagic 正确
modinfo $SRC/zram.ko | grep vermagic
```

**如果 `nm` 里没有 `crystal_sddc_*`** → Makefile 没编进去（回到第 2 节）。
**如果 `strings` 里没有 `lz4kds`** → `zcomp.c` 的后端注册被条件编译掉了。

### 7.4 用 pipeline 一键跑

```bash
# build.conf: type = xiaomi, local_tree 指向内核树
bash pipeline.sh devices/<设备名>
```

pipeline 阶段 5 会自动走树外模式，阶段 6/7 做符号与 CRC 闸门。

---

## 8. 想改 SDDC？先看这份阅读顺序

| 顺序 | 文件 | 为什么 |
|---|---|---|
| 1 | `sddc/DESIGN.md`（30 KB） | 10 章完整设计：表示形式、delta 线格式、候选发现、事务、锁序、失败恢复 |
| 2 | `sddc/crystal_sddc.h` | 接口面（128 行），先看有哪些函数 |
| 3 | `crystal_sddc.c` 的 `crystal_sddc_delta_target_eligible()` | delta 准入判定（收益门槛） |
| 4 | `crystal_sddc.c` 的 `crystal_sddc_create()` | 初始化与资源分配 |
| 5 | `crystal_sddc.c` 的 `crystal_sddc_read_page_locked()` | 读路径（bug 高发区） |
| 6 | `crystal_sddc.c` 的 `crystal_sddc_slot_free_locked()` | 释放路径（引用计数） |
| 7 | `zram_drv.c` 的六条接点（第 5 节） | 看 SDDC 怎么被调用 |
| 8 | `zcomp.c` 的 `lz4kds_backend_ops` | 看 delta 编解码怎么接 |

---

## 9. 关键可调参数

全部是编译期宏，在 `sddc/crystal_sddc.c` 顶部：

| 宏 | 默认 | 行 | 含义 | 调大/调小的影响 |
|---|---|---|---|---|
| `CRYSTAL_SDDC_HASH_BITS` | 17（131072 桶） | 37 | 相似页索引规模 | 大→命中率高但占内存；小→冲突多 |
| `CRYSTAL_SDDC_DELTA_GAIN_MIN` | 8 | 44 | delta 至少省多少字节 | **偏保守**，考虑 header 收益可能为负 |
| `CRYSTAL_SDDC_DELTA_MIN_SIZE` | `PAGE_SIZE/8` | 45 | delta 目标最小尺寸 | 小→更多尝试但开销大 |
| `CRYSTAL_SDDC_SIMILARITY_MIN` | 16 | 46 | 相似度阈值（连续相同字节） | 大→误判少但漏掉潜在 delta |
| `CRYSTAL_SDDC_OBSERVE_WORKS` | 2 | 42 | 观察几次才判定 | 大→更准但延迟高 |

**建议**：想做实验就先把这几个改成 `module_param`，运行时可调，不用反复重编。

---

## 10. 已知问题与改造方向

### 10.1 LZ4KDS 读回 bug（P0）

whitewhale0612 README 原文：

> ⚠️ `LZ4KDS` 仍存在已知的读回稳定性问题：读回时可能读到错误页或零页，进而导致应用崩溃或 `system_server` 崩溃。**不建议在日常使用中启用**

三个可疑点：

1. `zram_drv.c:3813` 的 `-EAGAIN` 走 `goto retry`，重试路径没有显式上限（依赖外层循环）
2. 基准页被释放后，delta 的代际 cookie 校验是否严密
3. `zs_map_object` 在同页并发访问时的映射生命周期

### 10.2 压缩比没有传说中高

同作者实测：LZ4KDS **2.17x**，LZ4 1.57x，ZSTD 1.96x。不是网上说的 5x。

### 10.3 `zs_lookup_class_index` 兜底不准

`crystal_hybridswap_internal.h:27`，`< 6.4` 内核走：

```c
static inline unsigned int zs_lookup_class_index(struct zs_pool *pool, unsigned int size)
{
    (void)pool;
    return DIV_ROUND_UP(size, 32);   // ← 近似值，不是真实 size class
}
```

**后果**：可能放过“字节更小但落同一 size class”的 delta，收益为负。

### 10.4 改造优先级

| 优先级 | 事项 |
|---|---|
| P0 | 修读回 bug（可用性前提） |
| P0 | 验证 6.12 能否编过（无实测样本） |
| P1 | 参数化 SDDC 阈值（改 module_param） |
| P1 | 修正 `zs_lookup_class_index` 兜底逻辑 |
| P2 | 补 SDDC 状态机 KUnit 测试 |

---

## 11. 完整检查清单

编译前：

- [ ] 内核 `CONFIG_ARM64_4K_PAGES=y`
- [ ] 内核 `CONFIG_ZRAM=m`（必须模块）
- [ ] `CONFIG_ZSMALLOC` 可用
- [ ] `CONFIG_MEMCG=y` + `CONFIG_CGROUPS=y`
- [ ] Makefile 用 `obj-m` 不是 `obj-$(CONFIG_...)`
- [ ] Makefile 有 `ccflags-y += -DCONFIG_CRYSTAL_HYBRIDSWAP_SDDC=1`
- [ ] Makefile 编了 `lz4kd_neon.o`（arm64）
- [ ] 头文件路径含 `-I$(src)/include`

编译后：

- [ ] KO 大小 > 1 MB
- [ ] `nm zram.ko | grep crystal_sddc` 有输出
- [ ] `strings zram.ko | grep lz4kds` 有输出
- [ ] vermagic 与目标内核匹配

刷入后：

- [ ] `cat /sys/block/zram0/comp_algorithm` 方括号在 `lz4kds`
- [ ] `cat /sys/block/zram0/sddc_stat` 显示 `enabled: 1`
- [ ] `dmesg` 无 `SDDC manager allocation failed`
- [ ] `decode_failures` 持续为 0

---

## 附：本文对应的源码位置速查

| 内容 | 文件:行 |
|---|---|
| SDDC 结构体指针 | `zram_drv.h:228` |
| SDDC 三把锁 | `zram_drv.h:231-234` |
| 创建条件（静默降级） | `crystal_sddc.c:2534-2544` |
| 创建调用 | `zram_drv.c:5652` |
| 停止调用 | `zram_drv.c:5531` |
| 销毁调用 | `zram_drv.c:3597` |
| 写路径接点 | `zram_drv.c:4152` / `5152`（stored）、`4178`（job_key） |
| 读路径接点 + 重试 | `zram_drv.c:3811-3814` |
| 释放路径接点 | `zram_drv.c:3641` |
| 记账接点 | `zram_drv.c:581`（accounted_size）、`490`（snapshot） |
| 回写接点 | `zram_drv.c:2001-2180`（native_wb / flatten） |
| 统计接点 | `zram_drv.c:3280`（get_stats）、`2466`（debug_snapshot） |
| delta 后端 ops | `zcomp.c:155-165` |
| delta 接口定义 | `zcomp.h:23-36` |
| 参数宏 | `crystal_sddc.c:37-46` |
| 锁序警告 | `crystal_sddc.c:1304-1308` |
