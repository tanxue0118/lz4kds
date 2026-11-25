# 文档索引

> lz4kds 侧载模块工作区的全部文档导航。

---

## 快速入口

| 我想… | 看这里 |
|---|---|
| 搞清楚整个项目在干什么 | [../README.md](../README.md) |
| 让 AI 自动跑编译流程 | [../AGENTS.md](../AGENTS.md) |
| 把取证脚本发给用户 | [../tools/给用户的取证说明.md](../tools/给用户的取证说明.md) |
| 了解 SDDC 源码从哪来 | [sddc-source.md](sddc-source.md) |
| 把 SDDC 移植到 5.10 内核 | [port-5.10.md](port-5.10.md) |

---

## 一、核心文档

| 文档 | 内容 |
|---|---|
| [../README.md](../README.md) | **人类主文档**：两条架构路线（oplus/xiaomi）、原理、取证清单、仓库归属、安全性分析、算法切换机制、机型兼容性 |
| [../AGENTS.md](../AGENTS.md) | **AI 自动化手册**：运行环境（Linux/WSL 硬要求）、目录语义、build.conf 字段、9 阶段流水线、失败决策表、内核源码树查找表、模块约定、安全设计 |

## 二、专题文档（docs/）

| 文档 | 内容 |
|---|---|
| [sddc-source.md](sddc-source.md) | **SDDC 源码档案**：来源链（华为→Crystal→下游变体）、两个变体对比、文件哈希、职责分工、DESIGN.md 章节导航、可调参数、许可证归属、上游获取方式、阅读顺序、已知降级 |
| [port-5.10.md](port-5.10.md) | **5.10 移植任务表**：14 项缺失 API（31 处调用）、5.10 原厂 zram 参照写法（带行号）、未覆盖风险清单、建议移植顺序、验证方法、替代方案 |

## 三、用户侧材料

| 文档 | 内容 |
|---|---|
| [../tools/给用户的取证说明.md](../tools/给用户的取证说明.md) | 可直接转发给用户的取证指引：三步操作、采集清单、**安全性说明**（全程只读、不碰分区）|

## 四、设备目录规范

新设备取证后放入 `devices/<设备名>/`，流水线自动读写下列文件：

| 文件 | 用途 |
|---|---|
| `build.conf` | 流水线输入（架构/内核树/KO 名） |
| `00_summary.txt` | 快查摘要（先看这个） |
| `DEVICE_FINGERPRINT.txt` | 设备指纹 |
| `uname.txt` / `proc_version.txt` | 内核版本（KMI 判定） |
| `config.txt` | 完整内核配置 |
| `kallsyms.txt` | 符号表（符号闸门） |
| `page_size.txt` | 必须 4096 |
| `modules_*/` | vendor KO（CRC 参照 + stock 包内救生索） |
| `RESULT.md` | 流水线状态报告 |

> 设备目录通常不纳入版本控制（含厂商 KO 与设备指纹），见仓库 `.gitignore`。

## 五、外部参考仓库

本工作区依赖下列上游项目，来源与用途见 [../README.md](../README.md) 第六节：

| 仓库 | 用途 |
|---|---|
| `jkHXQ/RMX5010-lz4kds-zram` | **oplus 变体主源码**（`source-oplus/` 出处），含适配层兼容性与降级说明 |
| `2108282/zram-lz4kds-sddc-houji-6.1` | **xiaomi 变体主源码**（`source-xiaomi/` 出处），含 DESIGN.md 与 KUnit 测试 |
| `Wcoom/oneplus_sm8750_kernel` | Crystal HybridSwap 上游（SDDC 原始出处）|
| `misaka5202/zram-lkm` | 通用 crypto 算法 LKM（预编译方案，5.10 可用） |
| `okhsunrog/vpnhide-kmod` | 通用 GKI KO 构建流程范本 |
| `bol-van/extract-symvers-ng` | 从二进制 vmlinux 抽 Module.symvers（备用 CRC 源） |

## 六、代码资产

| 目录 | 内容 |
|---|---|
| `source-oplus/` | OPPO hybridswap 骨架 + SDDC（oplus 变体） |
| `source-xiaomi/` | Crystal HybridSwap 完整驱动 + SDDC + DESIGN.md（xiaomi 变体） |
| `templates/oplus/` | KSU 模板：preinit 抢载路线（无预置 KO） |
| `templates/xiaomi/` | KSU 模板：zram.ko 热替换路线（含 9 层安全） |
| `tools/` | 工具链：recon / get-clang / wsl-setup / extract_crcs / crc_align / symgate / repack |
| `pipeline.sh` | 9 阶段双架构流水线 |

## 七、文档维护约定

1. **改了代码就改对应文档** —— 尤其是 `AGENTS.md`（AI 依赖它）和本文索引
2. **设备相关记录放 `devices/<设备名>/`**，不混进 `docs/`
3. **新专题文档放进 `docs/` 并在此登记**
4. `docs/` 下的文档用相对链接互相引用，便于整体搬迁
