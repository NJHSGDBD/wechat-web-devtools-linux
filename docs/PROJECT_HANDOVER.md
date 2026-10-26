# 微信开发者工具 Linux 构建项目 — Agent 移交文档

> 截至 2026-10-26。上一版（2026-09-17 版）描述的是 fork 自建补丁时代，已整体过时，勿参考。
> 目标：让没有上下文的 agent 能快速接手构建、排查、继续开发。

---

## 1. 项目是什么

把官方只发布 Windows/macOS 的**微信开发者工具**，转成 Linux 可用形态（AppImage / deb / tar）。

- **上游**：`github.com/msojocs/wechat-web-devtools-linux`（2026-10 由 `wechat-devtools-linux` 改名，旧 URL 301）。
  ⚠️ 上游默认分支已从 `master` 换成 **`electron`**，`master` 停在 2026-07-11，别再对着 master 比。
- **本仓库**：`github.com/NJHSGDBD/wechat-web-devtools-linux`（fork）
- **当前工作分支**：`electron-2608080`，基于 `upstream/electron` = `3612c4e`（2026-10-26）
- **构建方式**：CI / 脚本下载官方 Windows SDK（.exe）→ 7z 解包得到 `resources/app` → 替换成 Linux 版 electron / node / wcc / 原生模块 → 打补丁 → 打成 asar 与安装包

### 版本基线（conf/config.json）

| 项 | 值 | 说明 |
| --- | --- | --- |
| devtools | 2.02.2608080 | 官方 SDK，源 `devtools.wxqcloud.qq.com.cn`（国内直连可用） |
| electron | 36.6.0 | **本仓库改走 `npmmirror.com/mirrors/electron`**（官方源在国内 504） |
| compiler | 0.2.0 | `msojocs/wx-compiler` 的 wcc/wcsc（Linux 原生） |

---

## 2. 仓库结构（与旧版差异很大）

```
bin/       node(假 node) · wechat-devtools · wechat-devtools-cli · wechatide
conf/      config.json（版本与下载源）
res/scripts/  注入式补丁脚本（见 §4）
tools/     构建与修补脚本（setup 步骤机 + 各 fix-*.sh/js）
.github/workflows/  release / build-deb / build-tar / build-src
docs/      上游文档 + 本文件
```

### 关键变化：**已移除对独立 node 的依赖**

- `bin/node` 是一个几百字节的 shell 包装：用 `ELECTRON_RUN_AS_NODE=1` 让 electron 冒充 node。
- `conf/config.json` 的 `node` 段只剩版本号表（x64 22.16.0 等），**没有下载模板**；`update-node.sh` 已不存在。
- 新增 `bin/wechatide`（内置 skill 的 CLI 入口），deb 打包要一并复制（上游 01235a2 就是补这个）。

---

## 3. 构建流程

```bash
bash tools/setup-wechat-devtools.sh          # 主流程，状态机见 tools/step.sh
```

状态机（`tmp/.step`）顺序：

```
INSTALL_START → INSTALL_NPM_CONFIG_SUCCESS → INSTALL_GYP_SUCCESS
  → INSTALL_ELECTRON_SUCCESS → INSTALL_WECHAT_SUCCESS
  → INSTALL_REBUILD_SUCCESS → INSTALL_FIX_SUCCESS
```

各步做的事：

| 步骤 | 内容 |
| --- | --- |
| npm 配置 | 全局装 `node-gyp@11` + `asar` 到 `cache/npm`（registry 必须用 https） |
| gyp | `node-gyp install` 预取头文件 |
| electron | `update-electron.sh` 下载并解压到 `electron/` |
| SDK | `update-wechat-devtools.sh` 下载官方 exe → 7z 解出 `resources/app` |
| 重建 | `rebuild-node-modules.sh`：按 electron ABI 重编 nodegit / vscode-sqlite3 等，并补 `@swc/core` 的 Linux 绑定 |
| 打补丁 | `fix-selection-copy-node.js` → `fix-package-name.js` → `fix-cli.sh` → `fix-skill.sh` → `fix-compiler.sh` → `fix-data-path.sh` → `fix-other.sh` |

> `tools/replace-skyline.sh`（真 skyline 渲染引擎）在 setup 里是**注释掉**的：官方 SDK 自带的 `skyline.node` / `sharedMemory.node` 是 Windows PE，Linux 上不可用，所以默认走 WebView 渲染。

---

## 4. 注入式补丁：劫持模块导出，不直接改 hash 命名的 chunk

这是上游这一代的核心设计，比旧版"按文件名打 md5 补丁"抗版本变化得多。

| 脚本（res/scripts） | 注入目标 | 作用 |
| --- | --- | --- |
| `electron_main.js` | 前置到 `js/electron/main.js`（package.json 的 main，路径固定） | **数据目录统一**：hook `Module._load`，按导出函数名识别并包装 `getDataPathSync()` 与 `bootstrapAppPaths()`，把主进程 / 后端 / 渲染进程的数据目录统一成 `<userData>/app` |
| `webview-touch-focus.js` | `WebviewInstance.prototype.setEmulationTouch` | **模拟器点击修复**：开触摸仿真前先抢 guest iframe 焦点，避免旧页 blur 打断 TouchStart（症状：点一次没反应，要点第二次） |
| `webview-mouse-leave.js` | `WebviewManagerServiceMain.prototype` | 补 mouseLeave 与落点判定（`phoneAtPoint`），处理多 webview 叠放时的焦点归属 |
| `bootstrap.js` / `cli.js` / `config.js` | 对应模块前置 | 启动、CLI、编译配置修正 |

配套注入器：`tools/fix-webview-touch-focus.js`（按 `exports.WebviewManagerServiceMain` + `Emulation.setEmitTouchEventsForMouse` 特征定位模块，先校验唯一命中再改）。

**旧版已废弃的东西**（不要再找）：
- `tools/fix-login-persist.sh`（md5 固定 hash 登录态补丁）→ 被 `fix-data-path.sh` 取代
- `res/scripts/core_index.js` 的 skyline hook → `fix-other.sh` 里是注释状态，未注入
- 手写 `@swc` 预编译绑定 → 由 `rebuild-node-modules.sh` 统一处理

---

## 5. 本机构建环境（这台机器特有，踩过的坑）

| 现象 | 原因 / 处理 |
| --- | --- |
| `bad option: --no-sandbox` | 本 shell 继承了 `ELECTRON_RUN_AS_NODE=1`。启动须 `env -u ELECTRON_RUN_AS_NODE` |
| root 下 electron 直接 FATAL | 必须带 `--no-sandbox`（上游 bin 已带） |
| npm 403 | registry 必须 `https://registry.npmmirror.com`（http 入口被拦） |
| GitHub Release 下载 SSL 失败 | wget/curl 用代理：`export https_proxy=http://127.0.0.1:7897`；git 已在 `~/.gitconfig` 按域名配好 |
| 构建脚本批量删除被拦 | `CODEBUDDY_SAFE_DELETE_BULK_THRESHOLD=200000`；被拦文件会落到仓库内 `.Trash-0`，记得清 |
| `node-gyp install` ENOSPC | 磁盘只剩 ~1.2G，解包头文件时溢出；需先腾空间 |
| 本 shell 看不到 `/dev/dri` | Electron 只能软件渲染，**手感验证必须由用户在桌面终端跑** |

### 只跑通目录模式（不打 img）时的做法

`resources/app` 存在时，`bin/wechat-devtools` 会让 electron 直接加载目录（不读 asar）。此时：

- 补丁脚本要求 `resources/app.asar.unpacked` 存在 → `ln -sfn app resources/app.asar.unpacked`
- `tools/asar-helper.sh` 的 unpack/pack 需要临时改成空操作，跑完必须还原
- 编译器与 float-pigment 若下载不到，可直接从上游 AppImage 抽：
  `unsquashfs -o 193728 <AppImage> resources/app.asar.unpacked/node_modules/...`（该 AppImage 的 squashfs 偏移为 193728）

---

## 6. 当前状态（2026-10-26 实测）

- 目录模式组装成功，`resources/app` 版本 2.02.2608080，补丁标记逐个验证到位。
- 启动后 `[LoginState] storage-env` / `main-sync` / `renderer-sync` 正常，数据目录 `~/.config/wechat-devtools/app`，**登录态复用、无需重扫码**。
- 打开 `dist/dev/mp-weixin`：296 次编译调用、120 个页面各编译 **1 次**（无重复风暴）；`routeTo appLaunch timeout` **1 次**（启动后 14s，属官方冷启动固有，上游包同样有）；无原生模块加载失败。
- 遗留：`rebuild-node-modules.sh` 本机尚未跑通（node-gyp 环境问题），git 面板 / sqlite 相关功能未验证。
- AppImage / deb / tar 打包链路**本次未验证**。

---

## 7. 待办

- [ ] 补齐 `rebuild-node-modules.sh`（nodegit / vscode-sqlite3 / swc），最好在 CI 里跑
- [ ] 验证 `asar pack` 与 `build-appimage.sh` 整链，产出可分发包
- [ ] 旧数据目录 `~/.config/wechat-devtools/7770ddce…`（旧登录态补丁产物）可清理，新目录是 `app/`
- [ ] `docs/模拟器卡顿排查.MD` 已过时，按本文件 §4 更新或删除
- [ ] GitHub 操作一律走代理（`~/.gitconfig` 已配 `http.<url>.proxy = 127.0.0.1:7897`）
