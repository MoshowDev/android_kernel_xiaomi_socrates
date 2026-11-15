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

## 5. 打包 boot.img（默认已做）

需要你自己设备的原厂 boot.img 当模板——它只能从你的手机或 ROM 包里取，不能随仓库分发。
脚本默认会在这两个位置找：

```
./boot_stock.img
../boot_stock.img
```

找到就自动打包，产物是 **`out/boot.img`**，可以直接 fastboot 刷。
也可以用 `--stock /path/to/boot.img` 显式指定，或 `export STOCK_BOOT=...`。

一份都没有的话，脚本会在结尾报错并给出取镜像的命令；这时加 `--no-pack` 可以只留 Image。

从手机取（需要 root）：

```bash
adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot.img'
adb pull /sdcard/boot.img boot_stock.img
```

`scripts/pack_boot.py` 保持原厂几何布局（内核偏移、AVB 块偏移、分区大小），只替换内核载荷。

注意：boot 里的 vbmeta 是 OEM 私钥签名的，换内核后哈希必然不匹配。解锁状态下可以启动
（orange state），这与任何第三方 boot 镜像相同，无解。

## 6. 刷入

```bash
fastboot flash boot_a out/arch/arm64/boot/Image.kp.boot.img   # 注意确认当前槽位
```

回滚就是刷回原厂 boot。

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
