# 编译说明（Redmi K60 Pro / socrates / SM8550）

这个树是 LineageOS `lineage-24.0` 内核，额外集成了：

| 功能 | 位置 | 说明 |
|---|---|---|
| SukiSU Ultra | `KernelSU/`（git 子模块） | 分支 `builtin`（KernelSU + KPM + SUSFS 一体），内核侧通过软链 `drivers/kernelsu -> ../KernelSU/kernel` 引用 |
| SUSFS v2.4.0 | `fs/susfs.c` 等 27 个文件 | `susfs4ksu` 的 `gki-android13-5.15` 补丁，零冲突 |
| 机型配置 | `arch/arm64/configs/vendor/socrates-sukisu.config` | 叠加在 `gki_defconfig` + `kalama_GKI.config` + `socrates_GKI.config` 之上 |

## 0. 拉取

KernelSU 是子模块，**必须递归拉取**：

```bash
git clone --recursive https://github.com/xingstardog/android_kernel_xiaomi_socrates.git
```

已经 clone 过的补一次：

```bash
git submodule update --init --recursive
```

`drivers/kernelsu` 是指向 `../KernelSU/kernel` 的软链，这是上游 `setup.sh` 的做法。
Windows 上没开符号链接支持时，git 会把它落成一个普通文件，构建脚本会自动重建软链；
直接下载 zip 的话没有子模块内容，请用 clone。

## 1. 依赖

```bash
sudo apt update
sudo apt install -y bc bison build-essential flex libssl-dev libelf-dev \
    lz4 zstd cpio kmod rsync ccache python3 git curl dwarves openssl
```

`dwarves` 提供 `pahole`，`CONFIG_DEBUG_INFO_BTF=y` 必须有它。

## 2. 工具链

**必须用 AOSP 预编译的 `clang-r450784d`（clang 14.0.6）**，这是原厂 HyperOS 4 内核用的同一版。
换大版本会改变 CFI 类型哈希，Xiaomi 预编译的 vendor 模块会加载失败。

```bash
git clone --depth=1 --filter=blob:none --no-checkout -b android13-release \
    https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 clang-repo
cd clang-repo
git sparse-checkout init --cone
git sparse-checkout set clang-r450784d
git checkout android13-release
```

约 700 MB。下载完 `export CLANG_DIR=$PWD/clang-r450784d` 即可（脚本也会在
`../toolchain/clang-repo/clang-r450784d` 下自动找）。

## 3. 编译

```bash
./build-socrates.sh
```

产物：`out/arch/arm64/boot/Image`。

脚本会把三份 config 片段合并、生成 `.config`、同步 `auto.conf`、校验版本串，然后编译。
`JOBS` 默认按内存自动收敛（薄 LTO 的链接阶段是内存峰值）。

### 为什么不能手敲 `make`

三个坑，脚本里已经处理，自己编的时候别绕开：

1. **`LLVM=1` 必须传给每一次 make，包括 `gki_defconfig` 和 `olddefconfig`。**
   Kconfig 用 `$(CC)` 探测 `CC_IS_CLANG`。不带 `LLVM=1` 时它探到系统 gcc，
   判定 `CC_IS_CLANG=n`，于是 **LTO 和 `CONFIG_CFI_CLANG` 被静默关掉**。
   没有 CFI 的内核加载不了 Xiaomi 带 CFI 编译的 vendor 模块。

2. **`olddefconfig` 不刷新 `include/config/auto.conf`。**
   `scripts/setlocalversion` 读的是 auto.conf。不补一次 `touch .config && make syncconfig`，
   实际编出来的版本串会静默偏离 `.config` 里写的值，脚本的校验就会报错退出。

3. **版本串按源码树自己的版本生成。**
   默认：`5.15.223`（`Makefile` 的 `VERSION/PATCHLEVEL/SUBLEVEL`），
   `CONFIG_LOCALVERSION` 留空 + `CONFIG_LOCALVERSION_AUTO` 关闭 + 环境里 `LOCALVERSION`
   置空（否则 setlocalversion 追加 `+`）+ `BUILD_NUMBER` 不能存在（否则追加 `-ab<数字>`）。
   原厂 ROM 报的是 `5.15.194-android13-8-...`，这个前缀不参与 vendor 模块校验（见下节）。

### 自定义版本号

```bash
./build-socrates.sh --release 5.15.223-xingstar   # 完整串
./build-socrates.sh --release byxingstar          # 裸后缀，自动补成 5.15.223-byxingstar
```

`uname -r` 会变成 `5.15.223-xingstar`。不传这个参数时，版本串就是源码树的 `5.15.223`。

内核的版本串由 `VERSION.PATCHLEVEL.SUBLEVEL` 加后缀拼成，所以裸名称不可能成为完整串。
传一个不含 `5.15.` 前缀的值时，脚本会按默认 sublevel 展开并在开头打一行提示，避免必须
手写前缀。

实现上它会生成一个临时的配置片段（`$OUT/.release.config`），最后合并进去覆盖
`CONFIG_LOCALVERSION`，同时按你给的 sublevel 覆盖 `SUBLEVEL`。

**改这个串不会影响 vendor 模块加载。** 内核确实拿 vermagic 校验模块，但这个树是
`CONFIG_MODVERSIONS=y`，模块带 CRC 时 `kernel/module.c` 里的 `same_magic()` 会跳过
vermagic 的第一个空格之前的部分（正是内核版本串），只比较后面的标志位：

```c
/* First part is kernel version, which we ignore if module has crcs. */
if (has_crcs) {
    amagic += strcspn(amagic, " ");
    bmagic += strcspn(bmagic, " ");
}
```

所以只要标志位 `SMP preempt mod_unload modversions aarch64` 不变（改版本号不会变），
`vendor_dlkm` 里那些模块照常加载。实机验证过：`5.15.194-byxingstar` 刷入后 407 个模块
全部加载，显示、WiFi、触控正常，`boot_completed=1`。

真正会挂的是**模块 ABI 变化**：换 KMI generation、换编译器导致 CFI 变化、或者符号 CRC
漂移。那种情况才需要连 `vendor_dlkm` 一起重编。

## 4. KPM（默认已打好）

`CONFIG_KPM=y` 只提供 KPM 的 ioctl ABI，**运行时来自 KernelPatch**。
不注入 kpimg 的话，管理器的扩展探针会返回 0，App 显示"不支持 KPM"。

所以脚本默认在编译完成后自动完成这一步，产物直接就是能用的 KPM 镜像：

```
out/arch/arm64/boot/Image.kp
```

`kptools` 和 `kpimg` 不需要手动准备。脚本会自动 clone
`ShirkNeko/SukiSU_KernelPatch_patch` 并编译，缓存在 `~/.cache/socrates-kp`；
`kpimg` 需要的 Arm GNU 裸机工具链（`aarch64-none-elf-`）也会自动下载一次（约 92 MB）。
首次构建多花几分钟，之后走缓存。

只要纯净 Image、不打补丁：

```bash
./build-socrates.sh --no-kpm      # 产物 out/arch/arm64/boot/Image
```

superkey 用 `SKEY` 传入；不传则随机生成并写入树根 `.superkey`（权限 600）。
脚本用 `-S`（只存哈希），明文密钥不进镜像。

## 5. 打包 boot.img（默认已做，不需要原厂镜像）

`scripts/pack_boot.py` 里内置了 socrates 的完整布局，**不再需要 boot_stock.img**：

```
total        100663296   分区大小 96 MiB
page          4096       内核从 offset 4096 开始
header        1584       boot header v4
avb offset   47583232    vbmeta 块位置
avb blob        2304     OEM 签名的 vbmeta（已 base64 内嵌，附 sha256 校验）
```

产物是 **`out/boot.img`**，可以直接 `fastboot flash`。

需要换底包（别的 ROM、别的设备、或者你从手机重新 dump 的镜像）时再传模板：

```bash
./build-socrates.sh --stock /path/to/boot.img
```

模板会覆盖内置布局，几何参数和 vbmeta 都从模板里读。

内嵌的 vbmeta 描述的是原厂内核，换内核后哈希必然不匹配。解锁状态下可以启动
（orange state），这与任何第三方 boot 镜像相同，无解。

布局来源：原厂 `boot_b.img`（HyperOS 4，`CP2A.260605.016`）。内嵌布局与用模板打包
的结果**逐字节一致**，已用 sha256 `f62dc2fd…` 核对过。

## 6. 刷入

```bash
fastboot getvar current-slot      # 先确认活动槽位
fastboot flash boot_a out/boot.img
```

回滚就是刷回原厂 boot。

## 7. GitHub Actions

`.github/workflows/build-kernel.yml` 跑完整流程，产出 `Image` / `Image.kp` / `boot.img`，
作为 artifact 上传。两种 runner 都支持，用 `runner` 参数切换。

**self-hosted（默认）** 用绑定了家里小服务器的 runner。组织级 runner 只对注册它的仓库可见，
别人 fork 之后用不了——在 fork 里选 self-hosted 会一直排队到超时。

**github-hosted** 给 fork 用，不需要任何准备。规格是公开仓库 4 核 / 16 GB 内存 / 14 GB 硬盘
（私有仓库降到 2 核 8 GB）。工作流会先删掉预装的 Android SDK、.NET、ghc 等腾空间，否则
14 GB 装不下这套构建。

手动触发：

```bash
gh workflow run build-kernel -f runner=self-hosted -f release=byxingstar
gh run watch
```

输入参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `runner` | `self-hosted` | `github-hosted` 用于没有自建 runner 的场景 |
| `release` | 空 | 内核版本后缀，空则用树自己的 `5.15.223` |
| `patch_kpm` | `true` | 注入 KernelPatch（KPM 运行时） |
| `pack_boot` | `true` | 打包 `boot.img`（用内置布局，不需要模板） |
| `full_rebuild` | `false` | 先删掉增量输出目录，从头编 |

**两种 runner 都不需要准备任何厂商文件。** 打包所需的几何参数和 vbmeta 块都在
`scripts/pack_boot.py` 里。

self-hosted 上 clang（2.7 GB）和 KernelPatch 缓存首次运行后一直复用，增量编译通常几分钟。

github-hosted 的机器是一次性的，`~/.cache/socrates` 留不下来，所以**每次都要重新下 clang
和 ARM 工具链**（约 3–5 分钟、3 GB 流量），编译时间也翻倍到 35–50 分钟。换来的是零配置。

两个 secret（都可选）：

- `KP_SUPERKEY`：KernelPatch 超级密钥。不设的话每次构建随机生成，密钥会变。
- `BOOT_STOCK_URL`：想用别的底包时，用这个直链下发模板，覆盖内置布局。

增量编译依赖 `~/.cache/socrates/out`，所以重复构建通常只要几分钟。

## 已验证

在 HyperOS 4（`Redmi/socrates/socrates:17/CP2A.260605.016/OS4.0.0.13.XMKCNXM`）上实测：

```
Linux version 5.15.194-byxingstar
  (xingstar@...) (clang 14.0.6, LLD 14.0.6) #1 SMP PREEMPT
vermagic: 5.15.194-byxingstar SMP preempt mod_unload modversions aarch64
/proc/config.gz: CONFIG_KSU=y CONFIG_KPM=y CONFIG_KSU_SUSFS=y
                 CONFIG_LTO_CLANG_THIN=y CONFIG_CFI_CLANG=y
```

407 个 vendor 模块全部加载，WiFi 已连接（1200 Mbps），`wm size` 正常，`boot_completed=1`。
那次用的是自定义 release（`5.15.194-byxingstar`），正面验证了版本前缀不参与模块校验。

默认构建现在报的是源码树自己的 `5.15.223`，行为与上面一致。
