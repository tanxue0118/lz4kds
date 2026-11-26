# SDDC 源码档案

> 本文记录 SDDC（相似页去重 / 增量压缩层）的全部源码来源、版本、哈希、职责与阅读顺序。
> 目的是**后续可追溯**：任何一行 SDDC 代码都能查到它从哪来、属于谁、哪个变体。

- 归档日期：2026-11-25
- 相关移植任务：[port-5.10.md](port-5.10.md)
- 相关构建流程：[../AGENTS.md](../AGENTS.md)

---

## 1. SDDC 是什么

**SDDC = Similar-page Deduplication & Delta Compression**（相似页去重 + 增量压缩）。

在 zram 写路径上，对压缩后的字节流再做一次去重：

| 表示 | 条件 | 存储 |
|---|---|---|
| **REF**（普通流） | 无相似页 | 正常压缩流 |
| **ALIAS** | 内容完全相同 | 只存引用（cookie + 代际）|
| **DELTA** | 只有少量差异 | 存"基准页引用 + 差异字节流" |

读取时按状态机反向还原。算法底座是华为的 **LZ4KD**（delta 编码器 + 8 KiB reference/current 窗口）。

**核心收益**：Android 上大量页高度相似（.so、资源页），去重后压缩比可从 ~2.8x 提升到 ~5.0x（jkHXQ 在 RMX5010 实测：1.285 GB → 255 MB）。

**核心约束**：SDDC 必须挂在 zram 驱动的 store/read/free/reset/disksize 路径上，还要访问 zsmalloc 内部（alias/delta 的槽位大小判定），所以**不能做成纯 crypto 算法模块**。

---

## 2. 公开源码沿革

- **最早找到的公开 Crystal SDDC 实现**是 [`whitewhale0612` 提交 `8d64a0e`](https://github.com/whitewhale0612/android_kernel_common_oneplus_sm8750-C16/commit/8d64a0e7cd215403b536764f3df871320bce5c2f)，提交标题是 `crystal_hybridswap: port SDDC`。该提交首次加入 `crystal_sddc.c/.h`、`DESIGN.md`，并改动 Crystal 私有 zram 接点。**它本身是移植到 Crystal HybridSwap 的实现，不是未经移植的 Huawei SDDC 原版。**目前找到的公开材料没有提供单独、未移植的 Huawei SDDC 源码树。
- **LZ4KD codec 是独立来源。** 前序 [`whitewhale0612` 提交 `a276cf1`](https://github.com/whitewhale0612/android_kernel_common_oneplus_sm8750-C16/commit/a276cf10e7d122d89ef6ac0d44a6057de0b1185d) 将 LZ4KD 普通与 delta codec 接入 Crystal。codec 源文件头注明 Huawei Technologies Co., Ltd. 2022，并带有 `BSD-3-Clause OR GPL-2.0`。
- [`Wcoom/oneplus_sm8750_kernel`](https://github.com/Wcoom/oneplus_sm8750_kernel) 是 whitewhale 内核仓库的 fork，可按上述提交查看同一公开代码及后续变化；它不是独立的 Huawei 原始仓库。
- [`2108282` houji 6.1 移植](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/commit/9b223f005da12d39167515c37828395f412e31f9) 是后续设备适配版，含 6.1 改动、DESIGN、KUnit 及其维护更新。

多内核版本移植可从首次公开 Crystal 快照开始，逐个适配 zram hooks；保留 houji 版的 KUnit、DESIGN 和后续修复作对照。

---

## 3. 本工作区内的两个变体

| 项 | `source-oplus/` | `source-xiaomi/` |
|---|---|---|
| 来源仓库 | `jkHXQ/RMX5010-lz4kds-zram` | `2108282/zram-lz4kds-sddc-houji-6.1` |
| 架构定位 | 接在 **OPPO 原厂** `oplus_bsp_hybridswap_zram` 驱动上 | **完整替换** 标准 `zram.ko` |
| 目标设备 | realme GT7 Pro (RMX5010, 6.6.89-android15-8) | 小米14 (houji, 6.1 GKI) |
| 源码文件数 | 94 | 31 |
| 是否有 DESIGN.md | ❌ | ✅ (`sddc/DESIGN.md`, 30KB) |
| 是否有 KUnit 测试 | ❌ | ✅ (`crystal_sddc_codec_test.c`) |
| 兼容层方式 | `crystal_sddc_compat.h`：`zs_*` → `zs_*_oplus` | 无（用内核标准 zsmalloc）|
| 产物 KO 名 | `oplus_bsp_hybridswap_zram.ko` | `zram.ko` |

### 文件哈希（SHA256）

```
source-oplus/sddc/
  83ea2890...751d759e   crystal_sddc.c            163,196 B
  be5d4109...c68d723    crystal_sddc_codec.c        4,499 B
  e4ec8551...52d6e401   crystal_sddc.h             10,088 B
  c5afa251...34e3030f   crystal_sddc_codec.h        1,537 B

source-xiaomi/sddc/
  8ad092a5...a3e3711d   crystal_sddc.c            162,383 B
  6363fa2c...62634183   crystal_sddc_codec.c        4,496 B
  e4ec8551...52d6e401   crystal_sddc.h             10,088 B   ← 与 oplus 完全相同
  c5afa251...34e3030f   crystal_sddc_codec.h        1,537 B   ← 与 oplus 完全相同
  90b0b087...97f49b     crystal_sddc_codec_test.c   9,821 B   ← 仅 xiaomi 有
```

> `crystal_sddc.h` 与 `crystal_sddc_codec.h` 两个变体**逐字节相同**，
> 说明 SDDC 的接口层是统一的上游代码，差异只在 `.c` 实现的驱动接点上。

---

## 4. 目录职责

### 4.1 SDDC 本体（两变体共有）

| 文件 | 职责 |
|---|---|
| `crystal_sddc.c` (~163KB) | 核心：相似页索引、引用对象、alias/delta 状态机、生命周期、锁序、统计 |
| `crystal_sddc.h` | 对外接口：`crystal_sddc_create/stop/destroy`、`slot_free_locked`、`read_page`、`flatten`、`native_wb_*` |
| `crystal_sddc_codec.c` | 字节级编解码适配（调用 LZ4KD 的 delta 编码器）|
| `crystal_sddc_codec.h` | codec 接口 |

### 4.2 仅 xiaomi 变体

| 文件 | 职责 |
|---|---|
| `sddc/DESIGN.md` (30KB) | **最有价值的文档**，10 章完整设计说明（见下节）|
| `sddc/crystal_sddc_codec_test.c` | KUnit 测试：往返、畸形流、8 KiB 边界 |
| `sddc/lz4kd/` | LZ4KD 编解码（encode/decode/delta/NEON）|
| `zram_drv.c` (~?KB) | 完整的 zram 驱动（SDDC 的所有接点在这里）|
| `zms.c` / `zms.h` | ZMS：把压缩对象打包写回 backing device |
| `zcomp.c` | 压缩后端前端 |
| `core.c` / `param.c` / `memcg.c` / `pressure.c` / `stats.c` / `zram_bridge.c` | 策略、参数、memcg、压力通知、统计、桥接层 |

### 4.3 仅 oplus 变体

| 文件 | 职责 |
|---|---|
| `crystal_sddc_compat.h` | **关键兼容层**：`zs_create_pool` → `zs_create_pool_oplus` 等宏映射；`zs_lookup_class_index` 退化为按字节比较（因 OPPO 设备不导出该 API）|
| `zcomp.c` | 私有后端 `lz4kd`（纯 LZ4KD）与 `lz4kds`（LZ4KD + SDDC），**不注册到全局 crypto API** |
| `zram_drv.c` (~81KB) | 在 OPPO 原厂 zram 的写/读/free/recompress/reset/disksize 六条路径接 SDDC 回调 |
| `hybridswap/` | OPPO 原厂 hybridswap core/swapd（ezreclaimd、hybridmain、hybridswapd）|
| `kcompressd.c` | 异步压缩内核线程 |
| `lz4k/` `lz4kd/` `zstd/` | 算法后端 |

---

## 5. DESIGN.md 章节导航（xiaomi 变体，强烈建议先读）

文件：`source-xiaomi/sddc/DESIGN.md`

| 章节 | 内容 | 对应代码 |
|---|---|---|
| 1. Scope | SDDC 启用条件（4 项前置）| `crystal_sddc_create` |
| 2. Stored Representations | REF / ALIAS / DELTA 三种表示 | `enum crystal_sddc_kind` |
| 2.1 Immutable references | 不可变引用与代际 cookie | `struct crystal_sddc_cookie` |
| 3. Delta Wire Format | delta 线格式（magic/version/header）| `CRYSTAL_SDDC_DELTA_MAGIC` 等 |
| 4. Candidate Discovery | 相似页候选发现（hash 桶）| `CRYSTAL_SDDC_HASH_BITS 17` |
| 5. Conversion Transaction | 转换事务（alias/delta/commit 规则）| `crystal_sddc_slot_stored_locked` |
| 6. Read and Writeback Paths | 驻留读、ZMS 回写、batch-in/prefetch/recompress | `crystal_sddc_read_page` |
| 7. Locking and Lifetime | 锁序与生命周期（**改代码前必读**）| `index_lock` / `slot lock` |
| 8. Accounting | 记账 | `crystal_sddc_get_stats` |
| 9. Failure Recovery | 失败恢复（回退到普通压缩）| `-EAGAIN` 重试路径 |
| 10. Diagnostics | 诊断（sysfs `sddc_stat`）| `sddc_stat_show` |

---

## 6. 关键可调参数（源码宏）

| 宏 | 默认值 | 位置 | 含义 |
|---|---|---|---|
| `CRYSTAL_SDDC_HASH_BITS` | 17（131072 桶）| `crystal_sddc.c:37` | 相似页索引规模 |
| `CRYSTAL_SDDC_DELTA_GAIN_MIN` | 8 | `:44` | delta 相对基准至少省多少字节才采纳 |
| `CRYSTAL_SDDC_DELTA_MIN_SIZE` | `PAGE_SIZE/8` | `:45` | delta 目标页最小尺寸 |
| `CRYSTAL_SDDC_SIMILARITY_MIN` | 16 | `:46` | 相似度阈值（连续相同字节）|
| `CRYSTAL_SDDC_OBSERVE_WORKS` | 2 | `:42` | 一个页被观察几次才进入判定 |

> 这些值都是**编译期宏**，改动需重编 KO。优化分析见工作区历史讨论（class_index 修正 / memcg 记账 / GAIN_MIN 偏保守等）。

---

## 7. 许可证与归属

| 组件 | 归属 | 许可证 |
|---|---|---|
| SDDC 状态机 / 引用生命周期 | Crystal HybridSwap（按源码版权与提交记录核对）| `GPL-2.0-or-later`（源码头 `SPDX-License-Identifier: GPL-2.0-or-later`）|
| LZ4K / LZ4KD 编解码 | 华为 HiSilicon | 随源码声明 |
| zram 驱动骨架 / hybridswap / ZMS | OPPO / realme（oplus 变体）| Dual BSD/GPL |
| oplus 适配层（compat/接点/自检）| jkHXQ（codxe）| GPL-2.0 |
| xiaomi 移植（6.1 适配/熔断/还原）| 2108282 | GPL-2.0 |
| 本侧载封装（模板/工具链/流水线/文档）| 一只做梦的猫 | GPL-2.0 |

分发编译产物时，保留实际使用的源文件、所应用的补丁及构建所需脚本，按各文件的许可证提供对应源码。

---

## 8. 公开源码参考

从 [AOSP ACK 基线](build-own-zram.md) 开始构建。下面的链接供阅读和溯源。

- [houji 的 SDDC 设计、codec 和 KUnit](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/tree/9b223f005da12d39167515c37828395f412e31f9/drivers/crystal_hybridswap/sddc)。适合参考 scalar 实现、代际、引用和测试。
- [Wcoom 的 Crystal 目录](https://github.com/Wcoom/oneplus_sm8750_kernel/tree/13d291aef3d1d9607ad3fa5ff30dc23b2888a3da/drivers/crystalfrostwork/crystal_hybridswap)。该仓库是 `whitewhale0612` 仓库的 fork，具体归属按文件和提交历史确认。
- [RMX5010 的适配层](https://github.com/jkHXQ/RMX5010-lz4kds-zram)。仅供维护工作区已有的 oplus 变体时对照。

---

## 9. 阅读建议（按顺序）

1. **`source-xiaomi/sddc/DESIGN.md`** —— 先建立整体模型（30KB，10 章）
2. **`source-xiaomi/sddc/crystal_sddc.h`** —— 接口面（两个变体相同）
3. **`source-xiaomi/sddc/crystal_sddc.c`** 的：
   - `crystal_sddc_delta_target_eligible()`（准入）
   - `crystal_sddc_create()`（初始化）
   - `crystal_sddc_read_page_locked()`（读路径）
   - `crystal_sddc_slot_free_locked()`（释放）
4. **`source-oplus/crystal_sddc_compat.h`** —— 理解为什么要做兼容层
5. **`source-oplus/zram_drv.c`** —— 看 SDDC 如何挂进 zram 六条路径
6. `docs/port-5.10.md` —— 如果要移植到老内核

---

## 10. 已知降级（oplus 变体相对上游）

来自 `jkHXQ` 适配层文档，改代码前必知：

| 项 | 上游行为 | oplus 适配层 | 影响 |
|---|---|---|---|
| per-memcg 记账 | 按 memcg 统计压缩/回写字节 | 空实现（no-op）| 厂商 memcg 统计不含 SDDC 引用；不影响正确性 |
| `zs_lookup_class_index` | 按 zsmalloc size class 判定收益 | 退化为按字节比较 | 可能放过极少数低收益 delta |
| native writeback | delta/alias 原样写入 ZMS 并跟踪引用 | 依赖厂商"读回整页再写盘" | 回写无 SDDC 优化，功能正确 |
| prefetch / batch-in / recompress | 有 SDDC 专项分支 | 厂商骨架无这些路径 | 按普通流处理 |
