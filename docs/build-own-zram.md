# 从 AOSP ACK 自建带 SDDC 的 zram

从 [Android Common Kernel（ACK）](https://android.googlesource.com/kernel/common/) 的标准 zram 开始。先构建并验证原版，再逐步加入 LZ4KD codec、alias 和 delta。本指南以 ARM64、4 KiB 页、`android15-6.6` 为开发基线。目标设备如果运行 6.1 或 6.12，先在它对应的 ACK 分支核对接口。下面的构建命令适用于 ACK 基线和你后续实现的补丁，当前仓库的厂商侧载流水线与这套构建独立。

## 1. 选基线并构建原版

已有目标设备时，先收集运行内核和页大小。Android 系统版本可以比内核最初对应的 Android 版本新，选 ACK 时以运行内核的 release 和 KMI 代为准。手机上的 `getconf` 如果不可用，查询设备取证数据里的页大小。

```bash
adb shell uname -r
adb shell getconf PAGE_SIZE
```

| 内核系列 | ACK 分支 | Repo manifest 分支 |
|---|---|---|
| Android 14 / 6.1 | `android14-6.1` | `common-android14-6.1` |
| Android 15 / 6.6 | `android15-6.6` | `common-android15-6.6` |
| Android 16 / 6.12 | `android16-6.12` | `common-android16-6.12` |

在 Linux 主机或 WSL2 的 Linux 文件系统中执行。安装 `git`、`repo` 和官方内核构建文档列出的主机依赖。`repo sync` 会取回 Kleaf 和分支配套工具链，单独 clone `kernel/common` 只适合阅读或已有配套构建环境时使用。

```bash
mkdir -p ~/ack-zram
cd ~/ack-zram
repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6
repo sync -c
repo manifest -r > manifest-baseline.xml
git -C common rev-parse HEAD
git -C common switch -c zram-sddc

ACK_ROOT=$PWD
DIST_BASE="$ACK_ROOT/out/zram-baseline-dist"
tools/bazel run //common:kernel_aarch64_dist -- --destdir="$DIST_BASE"
find "$DIST_BASE" -type f -name 'zram.ko' -print
```

`manifest-baseline.xml` 记录各项目的提交。移到其他机器或公开补丁时，一并记录 manifest、`common` 提交、构建目标及配置改动。用同一基线的 `Image` 与模块产物跑后文的原版读回测试。已有可启动的 ACK 测试系统时，按它的镜像流程部署。使用 Cuttlefish 时按官方说明选与测试镜像架构匹配的 kernel / virtual-device 构建目标与模块集合。

来源：[AOSP 内核构建](https://source.android.com/docs/setup/build/building-kernels) · [GKI 版本规则](https://source.android.com/docs/core/architecture/kernel/gki-versioning) · [Android 15 / 6.6 发布记录](https://source.android.com/docs/core/architecture/kernel/gki-android15-6_6-release-builds)

## 2. 在 ACK 自带的 zram 上改

`android15-6.6` 的入口在 `common/drivers/block/zram/zram_drv.c` 的 `module_init(zram_init)`。同目录的 `zcomp.c` 通过压缩算法名连接 Crypto API，`Makefile` 组装 `zram.ko`，`Kconfig` 定义配置并由 `ZRAM` 选中 zsmalloc。该分支 ARM64 `gki_defconfig` 配置了 `CONFIG_ZRAM=m`。内建的 `CONFIG_ZRAM=y` 也能做树内开发，测试时随内核镜像交付；运行中的内建驱动无法用 `rmmod` 卸掉。

```bash
cd ~/ack-zram
ZRAM=common/drivers/block/zram
git -C common ls-files 'drivers/block/zram/*'
grep -nE 'module_init|zram_bvec_(read|write)|zram_free_page|zram_reset_device|disksize_store|ATTRIBUTE_GROUPS' "$ZRAM/zram_drv.c"
grep -nE 'backends\[|crypto_alloc_comp|crypto_comp_compress|crypto_comp_decompress' "$ZRAM/zcomp.c"
grep -nE '^CONFIG_(ZRAM|MODULES|MODULE_UNLOAD|MODVERSIONS)=' common/arch/arm64/configs/gki_defconfig
```

保留 ACK 的设备注册、块设备操作、swap 通知和 sysfs ABI。找所有调用者后再选接点，尤其是 partial I/O、discard、swap slot release、重压缩和 writeback。下面的函数名以查过的 ACK 6.6 为例，其他分支以实际源码为准。

来源：[ACK zram 源码](https://android.googlesource.com/kernel/common/+/refs/heads/android15-6.6/drivers/block/zram/) · [ARM64 GKI 配置](https://android.googlesource.com/kernel/common/+/refs/heads/android15-6.6/arch/arm64/configs/gki_defconfig) · [zram 用户态接口](https://docs.kernel.org/admin-guide/blockdev/zram.html)

## 3. 按四个可验证的补丁开发

| 补丁 | 改动 | 通过条件 |
|---|---|---|
| 1. LZ4KD 基础编解码 | 在 zram 内封装 scalar codec，管理压缩流和工作缓冲。通过 `comp_algorithm` 暴露 `lz4kd`，保留 ACK 原有默认算法和普通算法路径。 | codec 单测与 zram 逐字节读回通过，原有算法回归通过。 |
| 2. SDDC alias | 增加 per-device manager、异步观察和不可变引用对象。精确哈希仅用于找候选，提交前比较完整字节并复核 slot 身份。 | 相同数据触发 alias，覆写或释放原 slot 后仍能完整读回其他引用者的数据。 |
| 3. SDDC delta | 在同一个模块内给 `lz4kds` 提供带参考流的专用 delta 接口。候选基于正常 zram 会保存的字节流，包括普通压缩流和不可压缩时的原始页。 | 正常读回与单测通过、确实产生 delta 命中，且完整 delta 对象能落进更小的 zsmalloc size class。 |
| 4. 生命周期和兼容性 | 补齐相同填充值页、不可压缩页、partial I/O、释放、重压缩、reset/remove、回写和统计的处理与回归。 | 任一受支持路径都能读回原数据。资源不足或候选失效时回到普通存储。 |

### 3.1 编译与运行开关

在 `drivers/block/zram/Kconfig` 增加自己的功能选项，例如 `ZRAM_SDDC`，默认关闭。实现文件加入现有 `zram` 复合模块。例如新增 `sddc.o` 时使用 `zram-$(CONFIG_ZRAM_SDDC) += sddc.o`。用于验收的开发构建把实际选项写入所选 Kleaf 目标使用的配置，示例 ARM64 GKI 目标可在本地分支修改 `common/arch/arm64/configs/gki_defconfig`。确认最终生成的 `.config` 和构建日志反映所选配置。想保留 4 KiB 限制时，在 manager 创建时检查 `PAGE_SIZE`，并让不支持的页大小走普通路径。

`lz4kd` 提供普通压缩。`lz4kds` 由同一套普通 codec 加上参考流 delta 能力组成。ACK 6.6 的旧 `crypto_comp_*` API 可以继续服务标准算法，参考流参数由 zram 自己的 delta 接口传递。首版使用 scalar 路径。houji 参考版也显式关掉了内核态 NEON，优化 NEON 前先建立 scalar 的输出一致性与并发测试基线。

### 3.2 接点和引用所有权

| ACK 路径 | 自建 SDDC 要保证的行为 |
|---|---|
| `disksize_store()` | 先完成 table、zsmalloc pool 和压缩流的创建，再发布 SDDC manager。只有 4 KiB 页、主算法支持 delta、slot 数有效、资源分配成功时才启用。失败时维持可用的普通 zram 路径。 |
| 页写入 | 普通对象写入成功后，在 slot 锁内记录 `index`、代际、handle、大小与算法身份，再交给异步观察。转换提交前重新校验完整身份，禁止用陈旧数据覆盖新写入。 |
| 页读回 | 支持普通、全页相同、`REF`、`ALIAS`、`DELTA` 等表示。锁内捕获状态并 pin 引用、拷贝所需 delta 数据，解锁后按引用恢复普通流，再解压为页。并发冲突走可重试路径，损坏的数据返回 I/O 错误。 |
| `zram_free_page()` | 引用对象独立于原 slot。`REF` 和 `ALIAS` 释放自己的引用，`DELTA` 还要释放自己的 delta handle。最后一个引用者离开时才回收底层 reference。所有引用和对象各释放一次。 |
| 重压缩与回写 | 第一版把管理中的对象排除在重压缩外。若需要回写管理中的对象，先还原为普通 zram 表示，再交给 ACK 的现有回写逻辑，提交前复核身份。在支持之前跳过这些对象。ACK 的回写路径与 Crystal ZMS 不同。 |
| reset、移除及初始化失败 | 先关闭接收新任务、排空工作并等待在途操作，之后才能释放 slot、manager、pool 和压缩流。下一次初始化创建新 manager。 |
| `mm_stat` 与新增的 `sddc_stat` | `mm_stat` 保持原有 ABI。共享 reference 的字节只计一次，delta 计完整存储对象大小。单独暴露 `enabled`、当前 alias/delta、累计命中、恢复错误等指标，明确存量、累计量和重置时机。 |

观察和发布的锁顺序要能同时成立。一个可参考的做法是 slot 锁内发布索引，同时让持有索引锁的候选探测只尝试取 slot 锁，失败就跳过。退出流程在取得会阻塞工作线程的 `init_lock` 写锁前完成排空，等待期间不持有 slot 锁或指针发布自旋锁。单测覆盖 reference 代际变化、slot 反复复用、失败提交、损坏 delta、最后一次 put 及 reset 与读写交错。

## 4. 构建和验收改动

使用原版相同的 manifest、工具链和目标，输出到独立目录。以下命令从 `~/ack-zram` 执行。

```bash
cd ~/ack-zram
DIST_SDDC="$PWD/out/zram-sddc-dist"
tools/bazel run //common:kernel_aarch64_dist -- --destdir="$DIST_SDDC"
find "$DIST_SDDC" -type f -name 'zram.ko' -print
git -C common diff --check
```

**读回冒烟测试。** 在已启动对应构建、拥有 root、Bash 和 `cmp` 的 Linux 测试系统中运行。脚本只操作通过 `hot_add` 新建的测试 zram。原版用 `lzo-rle` 或机器上已有算法，改版再各跑一次 `lz4kd`、`lz4kds`。若选用其他算法，替换第一行变量。

```bash
(
    set -eu
    algo=lzo-rle
    control=/sys/class/zram-control
    work=$(mktemp -d)
    id=''
    cleanup() {
        if [[ $id =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$id" > "$control/hot_remove" ||
                printf '清理 zram%s 失败，请检查测试设备\n' "$id" >&2
        fi
        [[ ! -f $work/input.bin ]] || rm -- "$work/input.bin"
        [[ ! -f $work/output.bin ]] || rm -- "$work/output.bin"
        rmdir -- "$work"
    }
    trap cleanup EXIT

    id=$(cat "$control/hot_add")
    [[ $id =~ ^[0-9]+$ ]]
    sys="/sys/block/zram$id"
    disk="/dev/zram$id"
    for i in {1..20}; do
        [[ -b $disk ]] && break
        sleep 0.1
    done
    [[ -b $disk ]]
    printf '%s\n' "$algo" > "$sys/comp_algorithm"
    grep -F "[$algo]" "$sys/comp_algorithm"
    printf '16M\n' > "$sys/disksize"
    if [[ $algo == lz4kds ]]; then
        grep -Eq '^enabled:[[:space:]]+1$' "$sys/sddc_stat"
    fi

    dd if=/dev/urandom of="$work/input.bin" bs=4096 count=64 status=none
    dd if="$work/input.bin" of="$disk" bs=4096 oflag=direct status=none
    dd if="$disk" of="$work/output.bin" bs=4096 count=64 iflag=direct status=none
    cmp "$work/input.bin" "$work/output.bin"
    printf 'zram%s (%s) 读回一致\n' "$id" "$algo"
)
```

`enabled: 1` 只证明 manager 已经运行。随机页的冒烟测试也可以全部走普通路径。要证明 SDDC 本身工作，分别写入相同的非定值页与内容相近、能通过实际 delta 准入的页。等待 worker 排空，确认 `alias_hits` / `delta_hits` 分别增加，再直读校验每一页。用同一数据集测原版和改版，记录实际 `mem_used_total`、逻辑节省、吞吐及尾延迟。再做并发覆写、释放后读回、reset 后重新初始化、swap 压测和有回写时的回写读回。`decode_failures` 应保持为零，逐字节比对也必须通过。

## 5. 在目标设备使用前核对 KMI

开发时优先在同一构建产出的内核和模块上验收。替换设备现有 `.ko` 则是单独的集成工作。先核对目标 KMI 代、页大小、配置、符号导出及命名空间、模块签名与加载策略，再确认设备镜像或模块装载入口。ACK 分支名相同仅是初筛，设备上可能已有额外导出、特定模块依赖和不同的装载规则。

如果用 `make -C … M=…` 做树外验证，要指向对应的已配置构建树，并使用匹配的导出信息。`modules_prepare` 不生成 `Module.symvers`。已有模块的 `__versions` 只列出它自身带版本记录的导入，改写这些 CRC 不会更改 ABI。`kallsyms`、`vermagic` 和模块里的字符串都可用于排查，但最终依据是构建的符号检查、目标内核正常加载和实际数据读回。原型阶段使用对应镜像与模块集合，避免把这个 `.ko` 当成现有厂商侧载包的可替换文件。

来源：[AOSP 稳定 KMI](https://source.android.com/docs/core/architecture/kernel/stable-kmi) · [AOSP 可加载内核模块](https://source.android.com/docs/core/architecture/kernel/loadable-kernel-modules) · [Linux kbuild 外部模块](https://docs.kernel.org/kbuild/modules.html)

## 6. 保留的第三方参考

| 来源 | 值得借鉴的部分 |
|---|---|
| [2108282 的 houji 移植，固定到 `9b223f0`](https://github.com/2108282/zram-lz4kds-sddc-houji-6.1/tree/9b223f005da12d39167515c37828395f412e31f9/drivers/crystal_hybridswap/sddc) | `DESIGN.md` 的 slot、代际和引用所有权设计，`crystal_sddc_codec_test.c` 的 KUnit 用例，以及 `lz4kd/` 的 scalar 编解码与 delta 实现。该目录仍有 Crystal 私有依赖，按 ACK 接口拆分后再移植。 |
| [whitewhale0612 的 OnePlus 13T README](https://github.com/whitewhale0612/android_kernel_common_oneplus_sm8750-C16/blob/6.6.118-13T/README.md#压缩与写回测试) | 上游明确报告该分支曾有错误页或零页读回。用作错误读回和并发回归的依据，缺陷根因与其他分支的复现情况需要各自验证。 |

实际复用代码时，在补丁中记录来源仓库、提交、文件和修改，保留文件里的 SPDX 与版权声明。把 ACK 集成、codec 移植、alias/delta 与测试拆成独立提交，方便逐步验收、二分和回退。
