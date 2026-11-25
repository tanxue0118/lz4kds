# oplus 路线进阶手法参考（op13_zram_extend 分析）

> 本文分析一个真实在用的 OPPO 系（一加 13）zram 强化模块，提取其中**比本工作区现有实现更高级的手法**，
> 作为后续改进的参考清单。
>
> 样本：`op13_zram_extend` v1.3.8（作者 ItosEO，基于 whitewhale0612 实现），
> 目标内核 `6.6.118-android15-8-o-4k`。

---

## 1. 它做了什么

| 文件 | 作用 |
|---|---|
| `oplus_bsp_hybridswap_zram.ko` (3.0MB) | zram 驱动本体 + hybridswap，**early-init 抢载** |
| `oplus_bsp_fg_protect.ko` (263KB) | 前台保护，**bind mount 覆盖原厂 KO**，由原厂 modprobe 加载 |
| `oplus_exit_mm_optimize.ko` (287KB) | 进程退出内存优化，同上 |
| `early.sh` | early-init 阶段执行：环境校验、bind mount、insmod |
| `init.oplus.mm-sys.sh` (7.9KB) | **替换原厂 init 脚本**，控制 zram 容量/回写参数 |
| `service.sh` | 开机后校验、回写后端设置（分区 or Loop 文件）|
| `czram_verify` / `zram_backing` | C 写的校验工具与回写准备工具 |
| `config.sh` + `config.toml` | TOML 风格配置 + 严格校验的解析器 |
| `select-memory-opt.sh` | 安装时音量键选择开关 |

---

## 2. 值得吸收的手法（按价值排序）

### ★★★ 手法 1：用 `initrc/early.rc` 在 early-init 抢载（比 KSU preinit 更早）

```xml
# initrc/early.rc
on early-init
    exec u:r:ksu:s0 root -- /system/bin/sh /metadata/watchdog/ksu/op13_zram_extend/early.sh
```

通过 KernelSU 的 `initrc` 机制（`/data/adb/ksu/initrc/`），在 **Android init 的 early-init 阶段**
执行脚本，比本工作区当前使用的 `preinit` 更早、更确定。

**对比当前实现**：我们用 `preinit.conf` 的 `insmod` 行，依赖 KSU 解析配置文件；
它是直接挂 init rc，控制力更强（可以用 `exec` 指定 SELinux 域 `u:r:ksu:s0`）。

### ★★★ 手法 2：bind mount 覆盖原厂 KO，让原厂 modprobe 帮我们加载

```sh
for module in oplus_bsp_fg_protect oplus_exit_mm_optimize; do
    path=/vendor_dlkm/lib/modules/$module.ko
    mount -o bind "$stage/$module.ko" "$path"
done
```

**思路**：不改分区，只把原厂路径 bind mount 到我们的文件。这样原厂 init 脚本
`modprobe oplus_bsp_fg_protect` 时加载的其实是我们的版本 —— **不用自己管加载时机**。

回退也简单：`umount` 即可，或重启自动失效。

**当前实现缺这个**：我们只替换了 `hybridswap_zram.ko`，没处理其他伴生 KO。

### ★★★ 手法 3：替换原厂 init 脚本，精确控制 zram 参数

```sh
sed -e "s/^ZRAM_SIZE_MIB=.*/ZRAM_SIZE_MIB=$zram_size_mib/" \
    -e "s/^HYBRIDSWAP_ENABLED=.*/HYBRIDSWAP_ENABLED=$hybridswap_enabled/" \
    -e "s/^WRITEBACK_SIZE_MIB=.*/WRITEBACK_SIZE_MIB=$writeback_size_mib/" \
    "$stage/init.oplus.mm-sys.sh" > "$stage/init.oplus.mm-sys.active.sh"
chcon u:object_r:nandswap_exec:s0 "$stage/init.oplus.mm-sys.active.sh"
mount -o bind "$stage/init.oplus.mm-sys.active.sh" /product/bin/init.oplus.nandswap.sh
mount -o remount,bind,suid "$path"   # metadata 的 nosuid 会阻止 init 进入原厂域
```

关键细节：

- **`chcon u:object_r:nandswap_exec:s0`** —— 不设这个 SELinux 标签，init 拒绝执行
- **`mount -o remount,bind,suid`** —— `/metadata` 是 `nosuid`，不 remount 的话 init 起不来
- 用 `sed` 只改 3 个变量，**保留原厂脚本全部逻辑**（比我们自己重写安全得多）

**当前实现缺这个**：我们只在 `preinit.conf` 里写 `zram_algo=lz4kds`，容量和回写完全不管。
这个手法可以让我们既"只做侧载"又能继承原厂最优参数。

### ★★ 手法 4：TOML 配置 + 严格校验解析器

`config.sh` 里的 `load_config()` 值得学习：

- 逐项去重（重复键报错）
- 严格数值校验（无前导零、范围上限）
- **注释说明 mksh 的 32 位整数坑**：`zram_size_mib` 用 `env test` 而非内置 `test`，
  因为 mksh 内置 test 是 32 位
- 未知键直接报错（不静默忽略）

### ★★ 手法 5：`disable_pending` + `ksud module disable` 自动停用

```sh
disable_on_failure() {
    result=$?
    if [ "$result" -ne 0 ]; then
        touch "$stage/disable_pending"
        if /data/adb/ksud module disable op13_zram_extend && /data/adb/ksud initrc refresh; then
            rm -f "$stage/disable_pending"
            echo '模块已停用。修正问题后，在 KernelSU 管理器中重新启用并重启即可重试。'
        fi
    fi
}
trap disable_on_failure EXIT
```

比我们的 `touch disable` + 重启更主动：**直接用 ksud 命令行停用模块并刷新**，用户不用手动去管理器点。

### ★★ 手法 6：`active_boot`（boot_id）防止跨启动误判

```sh
cat /proc/sys/kernel/random/boot_id > "$stage/active_boot"
# service.sh 里：
[ "$(cat "$stage/active_boot")" = "$boot_id" ] || exit 0
```

和我们在 xiaomi 模板里用 boot_id 记账类似，但它是用来**确认"这次开机确实是我们接管的"**，
避免 service.sh 在未接管的开机上做多余动作。

### ★ 手法 7：回写后端双模式（分区 / Loop 文件）

```toml
writeback_size = 1024   # ≤1024 用原厂未加密 HybridSwap 分区（性能更好）
                        # >1024 用预分配 Loop 文件（Direct I/O）
```

`zram_backing prepare` 是个 C 工具，负责创建固定大小预分配的 Loop 文件。
这个功能超出我们"只侧载"的定位，但设计思路值得记录。

### ★ 手法 8：加载前检查模块是否已被占用

```sh
for module in oplus_bsp_hybridswap_zram oplus_bsp_fg_protect oplus_bsp_zram_opt oplus_exit_mm_optimize; do
    if grep -q "^$module " /proc/modules; then echo "接管失败：$module 已加载。"; exit 1; fi
done
[ ! -e /sys/block/zram0 ]
```

**要检查 4 个 KO**，不只 `hybridswap_zram`。我们当前只检查了 zram0 是否初始化。

---

## 3. 它比我们"严格"的地方

| 方面 | op13_zram_extend | 本工作区当前 |
|---|---|---|
| 加载时机 | `initrc/early.rc`（early-init）| `preinit.conf`（KSU preinit）|
| 伴生 KO | bind mount 3 个 KO 覆盖 | 只处理 hybridswap_zram |
| 容量控制 | 替换原厂 init 脚本 + 3 参数 | 不干预 |
| SELinux | 显式 `chcon` + `remount,bind,suid` | 未处理 |
| 失败处置 | `ksud module disable` + `initrc refresh` | `touch disable` 等用户手动 |
| 配置系统 | TOML + 严格校验 | build.conf（编译期）|
| 工具 | C 写的 `czram_verify`、`zram_backing` | 纯 shell |

---

## 4. 但也要注意：它的做法与"只侧载"定位有冲突

op13_zram_extend 是**全面接管内存配置**（容量、回写、fg_protect、exit_mm_optimize），
而本工作区模块的定位是**只侧载 lz4kds 算法**。

如果要吸收它的手法，需要区分：

| 手法 | 是否适合"只侧载"定位 |
|---|---|
| 手法 1（early.rc 抢载）| ✅ 直接适用，控制力更强 |
| 手法 2（bind mount 伴生 KO）| ⚠️ 需先确认目标设备有哪些伴生 KO |
| 手法 3（替换原厂 init 脚本）| ⚠️ 会变成"干预容量"，与定位冲突；但可只改 `ZRAM_ALGO` 一项 |
| 手法 4（TOML 配置）| ✅ 可用于模块自身配置（如算法选择）|
| 手法 5（ksud 自动停用）| ✅ 强烈建议吸收 |
| 手法 6（active_boot）| ✅ 已部分实现 |
| 手法 7（回写模式）| ❌ 超出定位 |
| 手法 8（检查伴生 KO）| ✅ 建议吸收 |

---

## 5. 与 GitHub 自动构建的关系

`op13_zram_extend` 这类模块的 KO 是**预编译分发**的（作者在自己机器上编好后打包），
不是每台设备现场编译。这提示另一条路径：

> 对于**同一内核版本、同一厂商**的设备群（如都是 `6.6.118-android15-8-o-4k` 的一加 13 系列），
> 一份 KO 可以覆盖多台机器 —— 前提是符号集合一致（见 README 第 2 节"为什么区分设备"）。

所以 GitHub Actions 的价值不只是"帮你编一次"，而是：

1. **批量验证**：对多个候选内核树/配置跑编译，看哪个能过
2. **产物归档**：把编好的 KO 作为 Release 附件分发，用户直接下载（不用自己编）
3. **回归检查**：源码改动后自动验证两个架构都能编

---

## 6. 后续可做（按性价比排序）

| 优先级 | 改进项 | 说明 |
|---|---|---|
| P0 | 吸收手法 5（`ksud module disable` 自动停用）| 用户不用手动操作，安全性明显提升 |
| P0 | 吸收手法 8（检查 4 个伴生 KO 是否已加载）| 防止接管冲突 |
| P1 | 支持 `initrc/early.rc` 加载方式（手法 1）| 作为 `preinit` 的备选，哪个可靠用哪个 |
| P1 | 手法 3 的 `sed` 只改 `ZRAM_ALGO` 一项 | 保持只侧载定位，但避免被原厂脚本降级 |
| P2 | bind mount 伴生 KO（手法 2）| 需先确认各机型有哪些伴生 KO |
| P3 | TOML 配置系统（手法 4）| 当前 build.conf 已够用 |

---

## 7. 参考包原始文件清单

```
module.prop                     258 B   id=op13_zram_extend  v1.3.8
early.sh                      3,285 B   early-init 主脚本
initrc/early.rc                 106 B   init rc 挂载点
init.oplus.mm-sys.sh          7,899 B   原厂 init 脚本（被替换）
config.sh                     2,552 B   TOML 解析器
config.example.toml             415 B   配置模板
customize.sh                  3,073 B   安装逻辑（含 SELinux chcon）
install.sh                      487 B   Magisk/KSU 安装钩子
service.sh                    6,380 B   开机后校验与回写设置
select-memory-opt.sh            558 B   音量键选择
uninstall.sh                     64 B   清理 /metadata 目录
czram_verify                 17,144 B   C 校验工具
zram_backing                 11,888 B   C 回写准备工具
oplus_bsp_hybridswap_zram.ko  3.0 MB   zram + hybridswap
oplus_bsp_fg_protect.ko       263 KB   前台保护
oplus_exit_mm_optimize.ko     287 KB   进程退出优化
```

三个 KO 的 vermagic 均为 `6.6.118-android15-8-o-4k SMP preempt mod_unload modversions aarch64`。
