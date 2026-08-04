# ZCode for NixOS / Nix

Z.ai 出品的 ZCode 桌面 AI 编程 IDE 的 Nix 打包。基于 Electron 应用打包的最佳实践，
覆盖 ZCode 官方发布的全部 4 个平台：`x86_64-linux`、`aarch64-linux`、`x86_64-darwin`、
`aarch64-darwin`。

## 目录结构

```
zcode-nix/
├── flake.nix      # Flake 入口，导出 4 个平台的 packages.<system>.default 与 apps.<system>.update-sources
├── package.nix    # mkDerivation，按 stdenv.isLinux / stdenv.isDarwin 分支解包与安装
├── sources.nix    # 锁定的版本、4 个平台的 URL + nix32 sha256（由 update.sh 自动生成）
├── update.sh      # 抓取 https://zcode.z.ai/cn#all-downloads，挑选最高 semver，prefetch 写回 sources.nix
└── README.md      # 本文件
```

## 已校验的版本

| 项 | 值 |
| --- | --- |
| 版本 | `3.6.5` |
| 验证日期 | 2026-08-04 |
| 验证方式 | 真实下载全部 4 个 CDN artifact → `sha256sum` → `nix hash convert --hash-algo sha256 --to nix32` |

### 平台与哈希一览

| 系统 | URL | sha256 (nix32) |
| --- | --- | --- |
| `x86_64-linux` | `…/3.6.5/linux-x64/ZCode-3.6.5-linux-x64.deb` | `011j8pcbb3iaxdx1pvpi5wbwr9qzzpfpmqk1xnrc1ka6ik6h7674` |
| `aarch64-linux` | `…/3.6.5/linux-arm64/ZCode-3.6.5-linux-arm64.deb` | `1l1aiazqhqggvms4m0gvv2ablmwrpyj3q2safk5r8i0yx34ny2js` |
| `x86_64-darwin` | `…/3.6.5/macos-x64/ZCode-3.6.5-mac-x64.dmg` | `1y2dbk2y95kvgwgkax4jnpwq9rkfynlzjmz70c5984c4h8k68jcg` |
| `aarch64-darwin` | `…/3.6.5/macos-arm64/ZCode-3.6.5-mac-arm64.dmg` | `12xcfymghm6j49m35b6r3309inifqmyk1cs3lk1mz0jizarkxyg4` |

对应 hex 摘要（用于审计）：

```
x86_64-linux  : e49803cd8c46cdc0b2ed61e27addfd1fa7cc172ff1ee1b7aeb2a8eb5d8453204
aarch64-linux : 5a0a6fc9e81e4494cb744a0b3ca4bf9957ba94d8fb814a74ddef6188bf8a2ad0
x86_64-darwin : 8f496426828411940a03e757f9a9f56ee684f9b59274351f7f7b96e4c55c4df8
aarch64-darwin: e4f93eb3fa51825fc3a443b3307dc52eda98c018d9ac326a22d254f8aa77ac8b
```

## 平台实现说明

### Linux (`x86_64-linux` / `aarch64-linux`)

- **源**：`.deb`（Debian binary package, format 2.0，data.tar.xz）
- **解包**：`ar x` + `tar -xvf data.tar.*`，得到 `opt/ZCode/*` 和 `usr/share/{applications,icons,doc}/...`
- **修复依赖**：`autoPatchelfHook` 递归 patch ELF，配合 `dpkg`/`makeWrapper`
- **buildInputs**：根据 `readelf -d opt/ZCode/zcode` 的 NEEDED 列表反推，包含 39 个包：
  - 直接 NEEDED：`alsa-lib`、`at-spi2-{atk,core}`、`atk`、`cairo`、`cups`、`dbus`、`expat`、
    `glib`、`gtk3`、`libX11`/`libXcomposite`/`libXdamage`/`libXext`/`libXfixes`/`libXi`/`libXrandr`、
    `libgbm`、`libxcb`、`libxkbcommon`、`nss`/`nspr`、`pango`、`systemd`（libudev）
  - 间接 / Electron dlopen：`libGL`、`libdrm`、`mesa`、`libxshmfence`、`fontconfig`、`freetype`、
    `gdk-pixbuf`、`libXrender`、`zlib`
  - 运行时常用：`libnotify`、`libsecret`、`libuuid`、`libxkbfile`、`libkrb5`、`util-linux`
- **autoPatchelfIgnoreMissingDeps**：忽略 `libc.musl-*` 与 `ld-musl-*`（部分 ZCode 版本在
  x64 deb 内误打了 arm64 的 ssh2 原生模块）
- **桌面集成**：重写 `zcode.desktop` 的 `Exec=`/`TryExec=`/`Icon=`，安装 hicolor 图标 16–1024
- **启动 wrapper**：`--no-sandbox`（chrome-sandbox 无法在只读 store 里 setuid）+
  `--enable-features=UseOzonePlatform` + `--ozone-platform-hint=auto`（Wayland 优先、回退 X11）+
  `ZCODE_USER_DATA_DIR=$HOME/.zcode`
- **安装布局**：`$out/share/zcode/`（应用本体）、`$out/bin/zcode`（启动器）、
  `$out/share/{applications,icons,doc}/`（系统菜单集成）

### macOS (`x86_64-darwin` / `aarch64-darwin`)

- **源**：`.dmg`（HFS+ 镜像，内含 `ZCode 3.6.5/ZCode.app` 或 `ZCode 3.6.5-arm64/ZCode.app`）
- **解包**：`_7zz`（7-Zip 24.x 静态二进制）解压 dmg，定位 `ZCode.app`，复制到 `$out/Applications/`
- **不调用 autoPatchelf**：Mach-O 二进制已经用 `@rpath` 链接到内置的 Electron Framework、
  Squirrel、Mantle、ReactiveObjC 等框架，依赖 Apple 系统框架（Cocoa、AppKit 等），
  在真正的 Darwin 主机上不需要 patch
- **清理**：删除 7zz 提取出的 `*:com.apple.cs.*` 扩展属性伪文件（码签名元数据，干扰 launcher）
- **启动 wrapper**：`$out/bin/zcode` 包装 `open -n /Applications/ZCode.app/Contents/MacOS/ZCode`，
  透传 `ZCODE_USER_DATA_DIR=$HOME/.zcode` 与命令行参数
- **二进制架构已验证**：x64 dmg 内为 `Mach-O 64-bit x86_64 executable`；
  arm64 dmg 内为 `Mach-O 64-bit arm64 executable`

## 快速开始

```bash
# 拉取最新版（重新抓下载页、prefetch 4 个 artifact、回写 sources.nix）
nix run .#update-sources

# 构建当前平台的包
nix build .#default
# 或显式指定平台（在对应主机上）：
nix build .#packages.x86_64-linux.default
nix build .#packages.aarch64-linux.default
nix build .#packages.x86_64-darwin.default
nix build .#packages.aarch64-darwin.default

# 运行
./result/bin/zcode
```

### 接入 NixOS / home-manager

```nix
# flake.nix
inputs.zcode.url = "github:redskaber/zcode-nix";

# configuration.nix / home.nix
environment.systemPackages = [
  inputs.zcode.packages.${pkgs.system}.default
];
```

### macOS 上接入 nix-darwin

```nix
# 在 darwin-configuration.nix 里
environment.systemPackages = [
  inputs.zcode.packages.aarch64-darwin.default  # 或 x86_64-darwin
];
```

## 校验记录

本次发布前在项目环境内完成了下列校验：

1. **下载完整性**：从 `cdn-zcode.z.ai` 真实下载 4 个 artifact，文件大小分别为
   138 MB（x64 deb）、132 MB（arm64 deb）、188 MB（x64 dmg）、180 MB（arm64 dmg），
   与 HTTP `Content-Length` 一致。
2. **哈希计算**：`sha256sum` 得到 hex 摘要 → 用 Nix 2.33.0 的
   `nix hash convert --hash-algo sha256 --to nix32` 转成 nix32，全部为 52 字符且
   字符集符合 Nix 规范（`0-9abcdfghijklmnpqrsvwxyz`，去掉 e/o/t/u）。
3. **deb 结构检查**：`dpkg-deb -x` + `readelf -d` 完整核对 `opt/ZCode/zcode` 的 35 个
   NEEDED 库，逐一映射到 nixpkgs attribute。
4. **dmg 结构检查**：用 7-Zip 24.09 解开 dmg，确认 `ZCode.app` 完整结构
   （`Contents/{MacOS,Frameworks,Resources,_CodeSignature}`）、Info.plist 中的
   `CFBundleShortVersionString = 3.6.5`、`CFBundleIdentifier = dev.zcode.app`、
   `CFBundleURLSchemes = ["zcode"]`，并 `file` 验证两个二进制分别是
   x86_64 与 arm64 的 Mach-O。
5. **Nix 求值**：在 `nixos-unstable` tarball 上对 4 个平台分别跑
   `nix eval --impure --expr` 用 mock pkgs 调用 `package.nix`，
   确认 `pname`/`version`/`platforms`/`mainProgram`/`license`/`buildInputs` 数量全部符合预期。
6. **Dry-run 构建**（Linux x64）：`nix build --dry-run --override-input nixpkgs
   github:NixOS/nixpkgs/archive/nixos-unstable.tar.gz .#packages.x86_64-linux.default`
   成功，输出 `these 2 derivations will be built`（fetchurl + zcode-3.6.5）+
   `these 309 paths will be fetched (535.5 MiB download, 1.9 GiB unpacked)`，无
   `undefined variable` 或 evaluation error。
7. **`update.sh` 端到端**：在本地运行 `./update.sh`，自动生成的 `sources.nix` 与
   手工校对版本完全一致（URL + 哈希逐字符匹配）。
8. **Bash 语法**：`bash -n update.sh` 通过。

## 常见问题

### Linux

- **OAuth 登录后浏览器找不到 zcode app**（`zcode://` 回调失败）：
  这个问题是本包重点修复的内容。根因是 ZCode 在启动时需要调用 `update-desktop-database`
  和 `xdg-mime` 来注册 `zcode://` 协议处理器，但这些工具默认不在 NixOS 的 PATH 里。
  此外 ZCode 写入 `~/.local/share/applications/zcode.desktop` 的 `Exec=` 指向 raw binary
  （不带 `--no-sandbox`），而 `chrome-sandbox` 在只读 store 里无法 setuid。

  本包的修复方式：
  1. 在 wrapper 的 PATH 里加入 `desktop-file-utils`、`shared-mime-info`、`xdg-utils` —
     让 `update-desktop-database` / `xdg-mime` 可被调用
  2. 删除 `chrome-sandbox` — Electron 回退到 user namespace sandbox（不需要 setuid）

  **升级后如果仍然失败**，需要清除旧的桌面文件（旧版的 `Exec=` 指向旧 nix store 路径）：

  ```bash
  rm ~/.local/share/applications/zcode.desktop
  # 重启 zcode，它会用新路径重新生成
  ```

  如果你的内核禁用了 user namespace（`sysctl kernel.unprivileged_userns_clone` 返回 `0`），
  回调仍会失败。解决方法：手动编辑 `~/.local/share/applications/zcode.desktop`，把
  `Exec=` 改成 `Exec=env ELECTRON_DISABLE_SANDBOX=1 <原路径> %U`，或者从终端启动
  `zcode`（wrapper 已带 `--no-sandbox`）。

- **Wayland 黑屏 / 输入法失效**：wrapper 已经默认加上 `--ozone-platform-hint=auto`，
  理论上会优先 Wayland，失败回退 X11。如需强制 X11：`zcode --ozone-platform=x11`。
- **沙箱报错**：由于 Nix store 只读，`chrome-sandbox` 无法以 setuid 形式生效，所以
  wrapper 显式加了 `--no-sandbox`。在多用户机器上请自行评估风险。
  从桌面文件 / 浏览器启动时（不带 `--no-sandbox`），Electron 会用 user namespace sandbox。
- **远程模型/登录态丢失**：默认数据目录 `$HOME/.zcode`，与官方一致。需要迁移时
  改 `ZCODE_USER_DATA_DIR` 即可。
- **autoPatchelf 报 `sshcrypto.node` 找不到 libc**：是上游把 arm64 二进制塞进 x64
  deb 的已知问题；`autoPatchelfIgnoreMissingDeps` 已经覆盖。

### macOS

- **"App is damaged and can't be opened"**：Nix 安装的 .app 丢了 Apple 码签名，
  在 Gatekeeper 启用时会被拦截。解决：
  - 临时：`xattr -dr com.apple.quarantine /Applications/ZCode.app`
  - 永久（不推荐）：`sudo spctl --master-disable`
- **首次启动很慢**：macOS 在第一次打开未签名 .app 时会做全文件扫描；之后会缓存。
- **想用原生菜单栏 / Dock**：直接 `open /Applications/ZCode.app` 即可，不需要走 `bin/zcode`。
  `bin/zcode` 是为 CLI 用户准备的、能透传 `ZCODE_USER_DATA_DIR` 的等价入口。

## License

Derivation 脚本（`flake.nix` / `package.nix` / `sources.nix` / `update.sh`）按 MIT
风格随意使用；ZCode 二进制本身遵循其自有 EULA（`meta.license = licenses.unfree`）。
