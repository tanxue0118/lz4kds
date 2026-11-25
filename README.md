# lz4kds 侧载模块 · per-device KO 编译工作区

> **模块名：LZ4KDS侧载　模块 id：`lz4kds_sidecar`　作者：一只做梦的猫**
>
> 唯一目标：把 **lz4kds（LZ4KD + SDDC）** 算法侧载进设备运行内存，不写任何分区。
> 不做容量配置、不做算法切换 UI、不带 WebUI —— 容量与算法请在系统侧调整。

**文档导航**：[docs/INDEX.md](docs/INDEX.md) ｜
[SDDC 源码档案](docs/sddc-source.md) ｜
[5.10 移植任务表](docs/port-5.10.md) ｜
[AI 自动化手册](AGENTS.md)

---

## 一、两条架构路线（关键）

不同厂商的 zram 实现完全不同，**模板与替换对象都不一样**。`devices/<设备>/build.conf` 的 `[arch] type` 决定走哪条。

### 路线 A：`oplus`（OPPO / realme / 一加）

| 项 | 内容 |
|---|---|
| 替换对象 | `oplus_bsp_hybridswap_zram.ko`（厂商私有 zram + hybridswap 驱动）|
| 依赖 | `oplus_bsp_zsmalloc.ko`（**必须先加载**，导出 `zs_*_oplus`）|
| 原厂位置 | `/vendor/lib/modules/` |
| 加载时机 | KSU **preinit**（SELinux 策略加载前）|
| 模板 | `templates/oplus/` |

**为什么需要两个 KO：**

- **`oplus_bsp_zsmalloc.ko`** — 压缩页专用分配器。zram 把 4KB 页压成几百字节，普通 kmalloc 会严重碎片化，zsmalloc 按 size class 装箱。OPPO 改版后导出名带 `_oplus` 后缀（`zs_malloc_oplus` 等），SDDC 管 alias/delta 必须直接用它。
- **`oplus_bsp_hybridswap_zram.ko`** — 三合一：zram 驱动本体 + OPPO hybridswap（冷页回写 swap 分区）+ 本项目接入的 LZ4KD/SDDC。

加载顺序**不可颠倒**：hybridswap 在 `zram_init()` 里就要解析 `zs_*_oplus`，zsmalloc 不在就先 `Unknown symbol`。

### 路线 B：`xiaomi`（小米 / 标准 zram 内核）

| 项 | 内容 |
|---|---|
| 替换对象 | `zram.ko`（标准 zram 驱动）|
| 依赖 | 内核自带 zsmalloc，无需额外 KO |
| 原厂位置 | `/system_dlkm/flatten/lib/modules/zram.ko` |
| 加载时机 | `post-fs-data`（rmmod 原厂 → insmod 自编）|
| 模板 | `templates/xiaomi/` |

小米没有 `oplus_bsp_*` 这套私有驱动，走的是用 `crystal_hybridswap` 完整驱动整份替换 `zram.ko`。安全设计三层：

1. **KO 完整性**：安装时写入 `.ko_md5`，开机校验，不匹配直接放弃
2. **原厂还原**：insmod 失败立刻 `insmod` 回原厂 `zram.ko`
3. **熔断器**：用 `boot_id` 记账，连续两次开机未到 `boot_completed` 自动禁用模块

## 二、KO 从哪来（重要）

**包里的 KO 必须来自本次编译，不是从用户手机拷的，也不是仓库里的历史产物。**

```
① 用户设备 /vendor/lib/modules/*.ko          ← 原厂预编译产物（recon.sh 拷回）
                ↓ 仅作 CRC 参照 / 回退备份
② devices/<机型>/modules_*/                   ← extract_crcs.py 抽 208~226 条符号 CRC
                ↓
③ work/<机型>.Module.symvers                  ← 编译用符号表
                ↓ 对着厂商内核源码编
④ work/<机型>/kernel/.../oplus_bsp_hybridswap_zram.ko   ← ★ 新编 KO
                ↓ symgate 校验 + crc_align 对齐
⑤ dist/lz4kds侧载-<arch>-<日期>-<hash>.zip   ← 最终包
```

**模板里不预置任何 KO**（`templates/oplus/preinit/` 只有空的 preinit.conf 占位），
KO 全部由 `repack.sh` 从编译产物注入，`preinit.conf` 也在此时自动生成。

`repack.sh` 支持 `FRESH_DIR` 新鲜度校验：指定后，传入的 KO 必须位于该目录内，
否则拒绝打包（`exit 3`）—— 防止误把仓库里的历史 KO 发出去。

## 三、目录结构

```
lz4kds/
├── README.md                  ← 本文件
├── AGENTS.md                  ← ★ 给 AI 的自动化操作手册
├── pipeline.sh                ← ★ 一键流水线（9 阶段，双架构）
├── docs/                      ← ★ 专题文档（见 docs/INDEX.md）
│   ├── INDEX.md               文档总索引
│   ├── sddc-source.md         SDDC 源码档案（来源/哈希/职责/阅读顺序）
│   └── port-5.10.md           5.10 移植任务表（14 项 API / 31 处调用）
├── source-oplus/              ← OPPO hybridswap 骨架源码（oplus 路线，来自 jkHXQ）
├── source-xiaomi/             ← Crystal HybridSwap 完整驱动源码（xiaomi 路线，来自 2108282/houji）
├── templates/
│   ├── oplus/                 ← 路线A：preinit 抢载（module.prop/customize.sh/service.sh/
│   │                            uninstall.sh/preinit/preinit.conf）—— 无预置 KO
│   └── xiaomi/                ← 路线B：zram.ko 替换（含 post-fs-data.sh 的熔断与还原逻辑）
├── devices/                   ← ★ 每台设备一个文件夹
│   └── TEMPLATE/              空白模板（build.conf 含 [arch] type 选择）
├── tools/
│   ├── recon.sh               用户端取证（全程只读）
│   ├── get-clang.sh           Android clang 获取（归档/镜像/超时）
│   ├── extract_crcs.py        vendor KO → Module.symvers + CRC 字典
│   ├── crc_align.py           __versions CRC 逐符号对齐
│   ├── symgate.sh             符号闸门
│   ├── repack.sh              双架构打包 + 新鲜度校验
│   └── 给用户的取证说明.md
└── work/  dist/               编译工作区 / 产物（均不入库）
```

## 三·五、运行环境（必读）

**必须在 Linux 环境跑：WSL2 / 原生 Linux / 容器。Windows 原生（含 Git Bash / MSYS）不支持。**

pipeline 阶段 0 检测到 Windows 会**立即拒绝**并提示改用 WSL。

**Windows NDK 的 clang 不能替代**：kbuild 的 `make prepare` 要把 `scripts/` 下的
`modpost`、`fixdep`、`resolve_btfids` 编译成**宿主可执行文件**，Windows 上产不出可执行的
Linux ELF 宿主工具；且 kbuild 依赖 fork/exec、符号链接、`/bin/sh` 等 POSIX 语义。
这不是换个编译器能绕过的问题。

Android clang 工具链获取（4 种）：

```bash
bash tools/get-clang.sh                  # 归档只拉单版本，失败回退浅克隆
bash tools/get-clang.sh --mirror tuna    # 国内镜像
export ANDROID_CLANG=/path/to/clang-r*/bin
# 或 build.conf 里填 clang_dir = ...
# 或允许 pipeline 自动下载：ALLOW_CLANG_DOWNLOAD=1 bash pipeline.sh ...
```

**默认不自动下载**：找不到工具链时阶段 4 立即失败并列出选项，不会挂住等 2GB。

## 四、最快用法

```bash
# 1) 把 tools/recon.sh + tools/给用户的取证说明.md 发给用户
#    用户回传 lz4kds_recon_<机型>.tgz

# 2) 建目录
cp -r devices/TEMPLATE devices/RMX5010-6.6.89-android15-8
tar xzf lz4kds_recon_RMX5010.tgz -C devices/RMX5010-6.6.89-android15-8 --strip-components=1

# 3) 填 build.conf：关键是 [arch] type 选 oplus 还是 xiaomi，以及 [kernel] 源码树

# 4) 出包
bash pipeline.sh devices/RMX5010-6.6.89-android15-8

# 产物: dist/lz4kds侧载-<oplus|xiaomi>-<日期>-<hash>.zip
# 报告: devices/<设备名>/RESULT.md
```

## 五、取证清单

### 必须有

| # | 文件 | 用途 |
|---|---|---|
| 1 | `uname -r` | KMI 判定 + vermagic |
| 2 | `/proc/config.gz` | 内核配置（ZRAM 是 y/m 决定路线可行性）|
| 3 | `/vendor/lib/modules/*.ko` 全套 | 抽符号 CRC；原厂 KO 作对齐参照 |
| 4 | `/proc/kallsyms` | 符号闸门 |

### 建议

| # | 文件 | 用途 |
|---|---|---|
| 5 | 原厂 zram 状态 | 回退参考 |
| 6 | `/proc/version` | localversion |
| 7 | 设备信息 + `PAGE_SIZE` | 机型记录 + 4K 页判断 |
| 8 | `/proc/meminfo`、`/system_dlkm/lib/modules/` | 容量判断；小米路线找原厂 zram.ko |

### 明确不采集

- **boot.img** —— 几十上百 MB，会让回传包膨胀。CRC 从 vendor KO 抽已足够。
- **任何分区写操作** —— `recon.sh` 全程只读，除 `/sdcard` 外不写任何位置。
  boot / persist / modem / tz / vbmeta / super / xbl **零接触**。

## 六、用到的仓库

| 仓库 | 作用 |
|---|---|
| **[jkHXQ/RMX5010-lz4kds-zram](https://github.com/jkHXQ/RMX5010-lz4kds-zram)** | **主源码来源**（oplus 路线）。RMX5010 上给 `oplus_bsp_hybridswap_zram` 接 LZ4KD+SDDC 的适配源码与模块结构 |
| **[2108282/zram-lz4kds-sddc-houji-6.1](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1)** | **xiaomi 路线参考** + CRC 补丁脚本。小米14 的 crystal_hybridswap 完整驱动移植，含 boot_id 熔断、原厂还原、崩溃归因 |
| **[misaka5202/zram-lkm](https://github.com/misaka5202/zram-lkm)** | 通用 crypto 算法 LKM。把 lz4k/lz4kd 做成跨 KMI 可加载模块（7 个 KMI）|
| **[okhsunrog/vpnhide-kmod](https://github.com/okhsunrog/vpnhide-kmod)** | 通用 GKI KO 构建流程范本（任意 GKI 设备出 KO 的标准步骤）|
| **[bol-van/extract-symvers-ng](https://github.com/bol-van/extract-symvers-ng)** | 备用 CRC 来源：从二进制 vmlinux 直接抽 Module.symvers |
| **[Wcoom/oneplus_sm8750_kernel](https://github.com/Wcoom/oneplus_sm8750_kernel)** | Crystal HybridSwap 上游（`drivers/crystalfrostwork/crystal_hybridswap`）|

### 上游归属（发布时保留）

| 组件 | 来源 | 许可证 |
|---|---|---|
| zram 驱动骨架、hybridswap core/swapd、回写、memcg 策略 | OPPO / realme 原厂 | Dual BSD/GPL |
| LZ4KD / LZ4K 编解码 | 华为 HiSilicon | 随源码声明 |
| SDDC 相似页索引、alias/delta、生命周期状态机 | Crystal HybridSwap（Wcoom）| GPL-2.0-or-later |
| lz4kd/lz4kds 后端、zram 接点、兼容层、自检 | jkHXQ 适配层 | GPL-2.0 |
| xiaomi 路线移植（熔断/还原/归因） | 2108282 | GPL-2.0 |
| 本侧载模块封装（双架构模板、工具链、流水线） | 一只做梦的猫 | GPL-2.0 |

## 七、安全性：侧载失败会变砖吗

**不会。** 源码里有三层保护：

### 第一层：模块 init 阶段

```c
if (!zcomp_available_algorithm(zram_algo)) {
    pr_err("unsupported zram_algo=%s\n", zram_algo);
    return -EINVAL;                    // 算法名不认识，拒绝加载
}
if (!strcmp(default_compressor, "lz4kds")) {
    ret = lz4kds_codec_selftest();
    if (ret) {
        pr_err("codec self test failed (%d), refusing to load\n", ret);
        return ret;                    // codec 自检失败，拒绝加载
    }
}
```

模块 init 返回错误 → 内核放弃 insmod → 原厂驱动仍在（或 fallback 回原厂 KO）。

### 第二层：设备初始化阶段

```c
if (codec_ret) {
    pr_err("codec self test failed, disabling SDDC\n");
    crystal_sddc_stop(zram);
    crystal_sddc_destroy(zram);        // 只停 SDDC，模块不卸载
    sddc_enabled = false;
}
```

**温和降级**：SDDC 关掉，普通 lz4kd 单页压缩继续工作。

### 第三层：IO 自检

真实写入一页再读回比对，失败只关 SDDC。且在 `swapon` 之前执行，不碰用户数据。

### 风险边界

| 情况 | 结果 |
|---|---|
| 算法名写错 / codec 自检失败 | insmod 失败，回原厂 ✅ |
| SDDC 运行出错 / IO 自检失败 | 只关 SDDC，lz4kd 继续 ✅ |
| CRC 没对齐 + MODVERSIONS 严格 | `Exec format error`，安全 ✅ |
| KO 与内核 ABI 结构不符 | 内核可能 panic ⚠️ |
| **写坏 bootloader 分区** | **本模块完全够不着** ✅ |

真砖需要写坏 `xbl/abl/tz` 等 bootloader 分区，本模块只改运行内存，够不着。
最坏情况是开机循环重启 —— 进 recovery 删掉 `/data/adb/modules/lz4kds_sidecar/` 即可恢复。
实际最常见的"故障"是 zram 起不来导致没 swap、后台被杀，禁用模块重启就好。

## 八、算法切换机制

模块通过两个东西实现"自动切到 lz4kds"：

### 1. `zram_algo=lz4kds` 启动参数

写入 `preinit.conf` 的 insmod 行，`zram_init()` 读它设为 `default_compressor`。

### 2. `lz4kds_nodegrade` 防降级（源码默认 true）

```c
/*
 * The vendor init script insists on writing "lz4" before programming
 * disksize, so lz4kds_nodegrade turns that specific request into a
 * no-op instead of letting it downgrade us.
 */
static bool lz4kds_nodegrade = true;
```

**这是关键**：OPPO 原厂 init 脚本会在设 `disksize` 前强写 `lz4`。不拦的话，你侧载的 lz4kds 会在开机后被悄悄降级成 lz4，等于白干。`nodegrade=true` 把这次写操作变成 no-op。

启动链：
```
preinit → insmod zsmalloc → insmod hybridswap zram_algo=lz4kds
       → zram_init(): default=lz4kds, nodegrade=true
       → 厂商脚本 echo lz4 > comp_algorithm   ← 被拦，忽略
       → 厂商脚本 echo <size> > disksize
       → zram0 以 lz4kds 创建 ✅
```

### 用户想换算法

```sh
# 方式一：改 preinit.conf 重启（推荐）
sed -i 's/zram_algo=lz4kds/zram_algo=lz4kd/' \
  /data/adb/modules/lz4kds_sidecar/preinit/preinit.conf
ksud initrc refresh && reboot

# 方式二：运行时切换（会丢当前 zram 内容）
su -c '
SIZE=$(cat /sys/block/zram0/disksize)
swapoff /dev/block/zram0
echo lz4kd > /sys/block/zram0/comp_algorithm
echo $SIZE > /sys/block/zram0/disksize
mkswap /dev/block/zram0 && swapon /dev/block/zram0
'
```

## 九、机型兼容性

| 条件 | 判据 |
|---|---|
| 页大小 | `PAGE_SIZE` = 4096（16K 页无缘）|
| 内核形态 | oplus: `CONFIG_ZRAM=m` + 原厂 hybridswap KO；xiaomi: `CONFIG_ZRAM=m` + 原厂 zram.ko |
| 同 BSP 同小版本 | 一份 KO 覆盖多机型，需逐机型过符号闸门 |
| 同厂跨小版本 | 重新对齐 CRC/符号 |
| 跨大版本 / 跨厂商 | 排除 |

已知实测：
- ✅ realme GT7 Pro (RMX5010, 6.6.89-android15-8) — oplus 路线，压缩比约 5.0x
- ✅ 小米14 (houji, 6.1 GKI) — xiaomi 路线，Actions 云编译
- ✅ 一加 SM8750 全家 — whitewhale0612 内核内建 lz4kds

## 十、合规

- GPL-2.0：分发二进制必须随附 source
- 保留全部上游归属声明（见上表）
- 产物仅用于已解锁 Bootloader + KernelSU/Magisk 的设备
