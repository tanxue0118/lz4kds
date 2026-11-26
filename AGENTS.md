# AGENTS.md —— lz4kds 侧载模块 per-device KO 自动化编译手册（给 AI 的操作说明）

> 本手册指导 AI 把 `devices/<设备名>/` 里的用户取证文件，自动编译成该设备可用的 lz4kds 侧载模块 zip。
> 环境：Linux 或 WSL，需 git / make / python3 / kmod / zip / binutils。

---

## 0. 运行环境（必读，否则一定失败）

**必须是 Linux 环境：WSL2 / 原生 Linux / 容器。Windows 原生（MSYS/Cygwin/Git Bash）不支持。**

pipeline 阶段 0 会检测宿主，检测到 Windows 直接拒绝并提示。

| 需要 | 说明 |
|---|---|
| 宿主系统 | Linux（WSL2 推荐）。`uname -s` 必须是 `Linux` |
| 基础依赖 | `git make python3 gcc bc bison flex libssl-dev kmod zip binutils` |
| **Android clang** | 必需，含 `clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip` |

### 为什么 Windows NDK 的 clang 不能替代

Linux 内核 kbuild 不是"只用编译器"就能跑：

- `make prepare` 会把 `scripts/` 下的工具（`modpost`、`fixdep`、`resolve_btfids` 等）
  编译成**宿主可执行文件**，Windows 上无法产出可执行的 Linux ELF 宿主工具
- kbuild 大量依赖 POSIX 语义（fork/exec、符号链接、路径大小写、`/bin/sh`）
- NDK 的 clang 目标三元组是 Android，缺少内核构建所需的 `--target`/`-nostdinc` 组合与宿主侧配套

结论：**Windows 上跑 kbuild 没有受支持路径**，NDK clang 也无法绕过。

### 获取 clang 的 4 种方式

```bash
# 1) build.conf 指定（推荐，指到已有 AOSP 树）
clang_dir = /path/to/prebuilts/clang/host/linux-x86/clang-r536225/bin

# 2) 环境变量
export ANDROID_CLANG=/path/to/clang-r536225/bin

# 3) 用脚本获取（优先 gitiles 归档只拉单个版本，失败回退浅克隆）
bash tools/get-clang.sh                    # 默认版本
bash tools/get-clang.sh --mirror tuna      # 国内镜像（清华）
bash tools/get-clang.sh --ver clang-r487747c

# 4) 允许 pipeline 自动下载（约 2GB，30 分钟超时）
ALLOW_CLANG_DOWNLOAD=1 bash pipeline.sh devices/<设备>
```

**默认不自动下载**：未找到工具链时阶段 4 会立即失败并列出以上选项，不会挂住等 2GB。

### 阶段 0 的工具链探测顺序

`$ANDROID_CLANG` → `$CLANG_BIN` → `work/clang` → `~/android-clang`
→ `~/kernel/prebuilts/clang/host/linux-x86` → `/opt/android-clang` → `/usr/lib/llvm`
（目录下若有 `clang-r*/bin` 会自动取最新一个）

## 1. 目录语义

新建 AOSP zram 时按 [ACK 自建指南](docs/build-own-zram.md) 使用官方 manifest 和 Kleaf。本手册描述现有设备的侧载流水线。工作区若有 `archive/` 和 `_publish/`，前者是本地历史归档，后者是独立发布工作树。

```
lz4kds/
├── AGENTS.md              ← 本文档（AI 入口，先读）
├── README.md              ← 人类主文档（原理、架构、仓库归属）
├── pipeline.sh            ← 一键流水线（9 阶段，双架构）
├── docs/                  ← 专题文档（INDEX.md 是总索引）
│   ├── INDEX.md           文档导航
│   ├── sddc-source.md     SDDC 源码档案（来源/哈希/职责/阅读顺序）
│   └── port-5.10.md       5.10 移植任务表（14 项 API / 31 处调用）
├── source-oplus/          ← OPPO hybridswap 骨架源码（oplus 路线用）
├── source-xiaomi/         ← Crystal HybridSwap 完整驱动源码（xiaomi 路线用）
├── 模块模板/
│   ├── 一加/             ← 路线A：preinit 抢载（无预置 KO）
│   └── 小米/             ← 路线B：zram.ko 替换（含熔断与还原）
├── devices/               ← ★ 每设备一个文件夹
│   └── TEMPLATE/          空白模板（build.conf）
├── work/                  ← 构建缓存、日志及本地内核树
├── dist/                  ← 产物 zip
└── tools/                 ← recon.sh / extract_crcs.py / crc_align.py / symgate.sh / repack.sh
```

## 2. 两条架构路线（最关键的分叉）

| | oplus | xiaomi |
|---|---|---|
| 替换对象 | `oplus_bsp_hybridswap_zram.ko` | `zram.ko` |
| 必需 KO | 2 个（zsmalloc 先 + hybridswap 后） | 1 个（zram.ko） |
| 依赖 | `oplus_bsp_zsmalloc.ko` 的 `zs_*_oplus` 导出 | 内核自带 zsmalloc |
| 原厂位置 | `/vendor/lib/modules/` | `/system_dlkm/flatten/lib/modules/` |
| 加载时机 | KSU preinit（SELinux 前） | post-fs-data（rmmod → insmod） |
| 模板 | `模块模板/一加/` | `模块模板/小米/` |
| 源码放置路径 | `vendor/oplus/kernel/mm/hybridswap_zram` | `drivers/block/zram` |
| 产物 KO 名 | `oplus_bsp_hybridswap_zram.ko` | `zram.ko` |

**判定方法**（build.conf `type=auto` 时 pipeline 自动执行，也适用于人工判断）：
看用户取证包的 `vendor_module_list.txt` / `system_dlkm_module_list.txt` / `modules_*` 目录
- 有 `oplus_bsp_hybridswap_zram.ko` → oplus
- 只有 `zram.ko`（在 system_dlkm/vendor_dlkm）→ xiaomi
- 两者都无且 `CONFIG_ZRAM=y` → 形态C，终止并报告

**为什么区分设备（实测结论，2026-11-25 三 KO 对照）**：
同一 KMI（如 android15-8）下，**符号 CRC 跨设备完全一致**（RMX5010 6.6.89 与 dali 6.6.118 原厂 KO 的 154 个共有符号 CRC 全同——CRC 按类型签名计算，GKI ABI 冻结期内不变）。
真正不通用的是**符号集合**：dali Crystal KO 的 248 个导入符号在 RMX5010 符号表中缺 97 个
（驱动代码不同：Crystal 直接操作 bio/XArray；版本差异：6.6.89→6.6.118 新增导出；
命名空间不同：OPPO 用 `zs_*_oplus`，dali 用标准 `zs_*`）。
所以区分设备的本质是"符号世界"不同，CRC/vermagic 反而是通用维度。

## 3. devices/<设备名>/ 规范

**命名**：`<机型代号>-<uname_r 关键段>`，如 `RMX5010-6.6.89-android15-8`、`houji-6.1.119-android14-11`

**内容**（recon.sh 产出，用户回传解压到此）：

```
devices/<设备名>/
├── build.conf              ← ★ AI 必须填写
├── 00_summary.txt          ← 快查摘要（先看）
├── DEVICE_FINGERPRINT.txt  ← 设备指纹（防发错包）
├── uname.txt / proc_version.txt
├── config.txt              ← 内核完整配置
├── kallsyms.txt            ← 符号闸门用
├── page_size.txt           ← 必须 4096
├── model.txt / brand.txt / device.txt / soc.txt / android_ver.txt / build_id.txt
├── zram_disksize.txt / zram_algo.txt / swaps.txt / meminfo.txt / zram_mmstat.txt
├── block_devices.txt / vendor_module_list.txt
├── modules_*/              ← vendor KO（CRC 参照 + 抽取来源）
└── RESULT.md               ← 流水线自动写入
```

**不采集 boot.img**；recon.sh 全程只读，除 `/sdcard` 外不写任何位置。

## 4. build.conf 字段（AI 需填）

```ini
[device]
model = RMX5010
kmi = android15-6.6
kernel_release = 6.6.89-android15-8-o-gxxxx

[arch]
type = oplus                     ; oplus | xiaomi —— 决定模板与替换对象

[kernel]
repo = https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750
branch = oneplus/sm8750_b_16.0.0_xxx
; local_tree = /path/to/kernel-tree
depth = 1

[build]
; ==== 以下 5 项留空 = pipeline 按 arch 自动填（强烈建议留空）====
; 源码目录：oplus → source-oplus ； xiaomi → source-xiaomi
source_dir =
; 源码放置路径：oplus → vendor/oplus/kernel/mm/hybridswap_zram ； xiaomi → drivers/block/zram
module_path =
; 产物 KO 名：oplus → oplus_bsp_hybridswap_zram.ko ； xiaomi → zram.ko
ko_name =
; 额外打包的设备 KO（oplus 需 zsmalloc，留空自动找）；xiaomi 无需
extra_ko =
; CRC 参照 KO（留空自动在取证包里找）
crc_ref_ko =
; ==== 以下手工填 ====
clang_dir =
extra_make_flags =

[pack]
algo = lz4kds                    ; oplus 写入 preinit.conf；xiaomi 运行时写入
```

> **注意**：`[build]` 段若填写了与 `[arch] type` 冲突的值（如 xiaomi 却填了 `oplus_bsp_hybridswap_zram.ko`），
> pipeline 阶段 5 会报 `build.conf 的 [build] 段与架构 xxx 冲突` 并中止——这是防止 v1 早期的真实 bug 重演。

## 5. 流水线

```bash
bash pipeline.sh devices/RMX5010-6.6.89-android15-8
```

| 阶段 | 动作 | 成功判据 |
|---|---|---|
| 0 环境 | 宿主必须是 Linux + 基础依赖 + 工具链预探测 | 全通过（Windows 直接拒绝）|
| 1 校验 | 页大小 + 架构判定 + 架构专属前置检查 | 全通过 |
| 2 抽 CRC | vendor KO → Module.symvers | 符号数 > 100 |
| 3 取树 | git clone / local_tree | 有 Makefile |
| 4 配置 | config → .config, olddefconfig, prepare, UTS_RELEASE | prepare 完成 |
| 5 编译 | 按 arch 选源码（source-oplus / source-xiaomi）→ module_path，注入 CONFIG 门 → M= 编译 | KO 生成 |
| 6 闸门1 | 符号 ⊆ kallsyms | exit 0 |
| 7 闸门2 | CRC 对齐参照 KO | 补丁完成 |
| 8 打包 | KO + 模板 → dist/ | zip 生成 |

产物：
- `dist/lz4kds侧载-<arch>-<日期>-<hash>.zip`
- `devices/<设备>/RESULT.md`（状态+停止阶段+原因）
- `work/<设备>/build.log`
- `devices/<设备>/built-*.ko`（KO 留档）

## 6. 失败处理决策表

| 现象 | 原因 | 处理 |
|---|---|---|
| 阶段1 CONFIG_ZRAM=y | zram 编进内核 | 终止，告知用户需刷内核 |
| 阶段1 缺 hybridswap KO | 用户是小米设备 | 改 [arch] type=xiaomi |
| 阶段1 缺 zsmalloc KO（oplus）| 取证不完整 | 让用户重跑 recon.sh |
| 阶段2 符号 < 100 | vendor KO 被 strip | 换 extract-symvers-ng 从 boot.img 抽 |
| 阶段4 olddefconfig 报错 | 树与 config 不匹配 | 核对分支，换树（第 7 节） |
| 阶段4 prepare 报 resolve_btfids | 主机 clang 差异 | 可忽略，重跑 |
| 阶段5 编译 undefined | 缺 CONFIG/头文件 | 对照 config.txt 补 |
| 阶段5 缺 hybrid_zsmalloc.c | 树不含厂商代码 | 换厂商树 |
| 闸门1 MISSING | 内核没导出该符号 | 换树，**禁止手改符号表** |
| 闸门2 unmatched 多 | 参照 KO 差异过大 | 核对 crc_ref_ko |
| repack exit 3 | KO 不在编译产物目录 | 确认用的是本次编译的 KO |
| insmod Exec format error | CRC/vermagic 不匹配 | 重跑 crc_align |
| insmod Unknown symbol | 符号不存在 | 让用户重跑 recon.sh |

## 7. 内核源码树查找表

| 特征 | 源码树 |
|---|---|
| oplus SM8750（一加13/13T/Ace5 Pro/Ace6） | https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750 |
| oplus SM8650（8 Gen3） | https://github.com/OnePlusOSS/android_kernel_oneplus_sm8650 |
| oplus RMX5010 GT7 Pro 6.6.89 | whitewhale0612/android_kernel_common_oneplus_sm8750-C16 或 OnePlusOSS 对应分支 |
| 小米（houji 等 6.1 GKI） | MiCode/Xiaomi_Kernel_OpenSource 对应分支 |
| 纯 GKI（Pixel 等） | https://android.googlesource.com/kernel/common -b <KMI> |
| 都找不到 | 回复用户：需要厂商内核源码，该设备暂无公开树 |

## 8. 工具单步用法

```bash
# 抽 CRC
python3 tools/extract_crcs.py devices/<D>/modules_vendor_lib_modules work/<D>

# 符号闸门
bash tools/symgate.sh <新编.ko> devices/<D>/kallsyms.txt

# CRC 对齐（原地改 KO）
python3 tools/crc_align.py <新编.ko> <参照.ko>

# 打包（务必带 FRESH_DIR 防误用历史 KO）
ARCH=oplus  FRESH_DIR=<编译产物目录> bash tools/repack.sh <hybridswap.ko> <zsmalloc.ko>
ARCH=xiaomi FRESH_DIR=<编译产物目录> bash tools/repack.sh <zram.ko>
```

## 9. 模块约定（重要）

- **id**：`lz4kds_sidecar`　**名称**：`LZ4KDS侧载`　**作者**：一只做梦的猫
- **定位单一**：只把 lz4kds 算法侧载进运行内存
  - 不做容量配置、不做算法切换 UI、不带 WebUI、不带 zram.sh
  - 容量与算法请用户走系统侧
- **模板不预置 KO**：`模块模板/一加/preinit/` 只有占位 preinit.conf，
  KO 与最终 preinit.conf 由 repack.sh 从编译产物注入生成
- **oplus 加载顺序固定**：`insmod zsmalloc` → `insmod hybridswap zram_algo=<X>`，不可颠倒

## 9.5 安全设计（参考 dali Crystal r48 的实战经验）

### xiaomi 路线（post-fs-data 热替换）安全层，按顺序：

1. `disable` 标记 → 直接退出
2. **safe_mode**：上次开机 `ro.boot.bootreason` 含 panic/watchdog → 写 `data/safe_mode` 跳过本次
   （boot_count 熔断会把"非我方崩溃"算在自己头上，bootreason 归因可避免误熔断）
3. boot_count 熔断（≥3 次失败自动 `touch disable`）
4. 设备/内核门禁：`.target_device` / `.target_kernel` 由 repack 写入，安装与运行双查
5. KO sha256 校验（`zram.ko.sha256` 由 repack 生成）
6. **空闲四重检查**：disksize=0 + initstate=0 + 不在 /proc/swaps + holders 为空
7. 依赖加载：zsmalloc 未载则用随包 `stock/zsmalloc.ko`
8. 失败回滚：insmod 失败立刻 `insmod stock/zram.ko`
9. **stock KO 随包**：`stock/` 目录由 repack 从设备取证目录复制（DEVICE_DIR），回滚永不依赖系统状态

### repack 门禁（防事故）：

| 门禁 | 行为 | 防什么 |
|---|---|---|
| `FRESH_DIR` | KO 不在编译产物目录 → exit 3 | 误把仓库历史 KO 发给用户 |
| KO 内容检查 | strings 找 `zram_algo` 处理逻辑，缺失则告警 | 重编丢失算法钉死逻辑（dali r48 P1 教训：厂商脚本抢先写 lz4 造成每轮开机 22s 降级窗口）|
| stock 随包 | DEVICE_DIR 找原厂 zram.ko 复制进包 | 回滚时系统路径上原厂 KO 已不存在 |
| 设备/内核指纹 | device.txt/uname.txt → .target_device/.target_kernel | 包发错机型 |

### 打包流水线二进制保护（dali r42 教训）：

repack 只做文件复制与 sha256 计算，**绝不对 KO/二进制做文本处理**（无 CRLF 转换、无 sed 改写 KO）。
`zram.ko.sha256` / `.ko_md5` 之类的指纹文件由脚本生成后与实际文件比对校验。

## 10. 合规

- 分发 zip 必须随附 source（GPL-2.0）
- 保留上游归属：华为 LZ4KD / Crystal HybridSwap SDDC / OPPO 原厂驱动 / jkHXQ 适配层 / 2108282 小米移植
- 产物仅用于已解锁 Bootloader + KernelSU/Magisk 的设备