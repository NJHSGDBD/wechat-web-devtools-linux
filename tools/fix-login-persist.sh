#!/bin/bash
# 修复 Electron 版微信开发者工具"每次启动都要重新扫码登录"的问题(登录态不持久)
#
# 根因(Linux AppImage 特有,已实测闭环验证):
#   工具用 md5(应用路径) 作为数据目录 hash:数据目录 = <userData>/<md5>。
#   数据目录 hash 由两处独立代码产生,任一处都会导致"目录漂移":
#     1. js/bd3919eb5ba5af9000b9c9b25a078747.js  getDataPathSync()
#        → md5(ELECTRON_BASE_APP_PATH || app.getAppPath())
#        → 登录态/项目数据(LocalStorageService / AppDirService)都用它;
#     2. js/c47addee36149e53772b60ab7e158ffe.js   bootstrap getDataDirHash()
#        → md5(app.getAppPath()),用于 bootstrap 数据根/热更新(NW 兼容层)。
#   AppImage 每次启动挂载到随机 /tmp/.mount_XXXX,app.getAppPath() 随之变化,
#   两处 hash 每次都不同 → 每次启动都新建空数据目录:
#     - 上次登录写入的 <userData>/<旧hash>/WeappLocalData/ls_<md5("userInfo")>.json
#       (登录态,含签名票据,与 ls_encrypt_secret.json 密钥文件成对)读不到;
#     - isLogin 判定(IGlobalStoreService.get("userInfo") → LocalStorageService
#       读 WeappLocalData/ls_<md5(key)>.json)返回空 → 判定未登录 → 弹扫码页。
#   每次扫码还会留下一个 ~300MB 的孤儿 hash 目录。
#   Windows/常规安装时 app.getAppPath() 固定,官方不会有此问题。
#
# 方案:
#   把两处 hash 的输入从动态 appPath 改为固定值
#   md5("wechat-devtools-linux::" + app.getName()),数据目录 hash 恒定,
#   登录态/项目数据天然持久;另支持环境变量 WECHAT_DEVTOOLS_DATA_HASH
#   (32位hex)显式指定,便于需要隔离的场景。
#
# 补丁位置(两种模式):
#   A. 目录模式(resources/app 存在,构建/解包树):直接改目录内文件;
#   B. asar 模式(只有 resources/app.asar):用 @electron/asar 提取源文件,
#     改后写入 resources/app.asar.unpacked/js/ 同名文件覆盖生效
#     (Electron 对 asar 内文件 require 时优先读取 unpacked 同名文件),无需重打 asar。
#
# 幂等:已含补丁标记则直接退出;--force 强制重打。

set -e
script_dir="$(cd `dirname $0` && pwd -P)"
root_dir="${WDT_BUILD_ROOT:-$(cd `dirname $0`/.. && pwd -P)}"
source "$script_dir/error-handler.sh"
devtools_enable_error_trap

MARK="wechat-devtools-linux::"
FILES=(
  "js/bd3919eb5ba5af9000b9c9b25a078747.js"
  "js/c47addee36149e53772b60ab7e158ffe.js"
)

[ "$1" = "--force" ] && FORCE=1 || FORCE=0

already_patched() {
  local f="$1"
  [ -f "$f" ] && grep -q "$MARK" "$f" 2>/dev/null && return 0
  return 1
}

notice() { echo -e "\033[36m $1 \033[0m"; }
warn() { echo -e "\033[43;37m 警告 \033[0m $1"; }

# ---------- 模式 A: 目录树存在,直接 patch ----------
if [ -d "$root_dir/resources/app/js" ]; then
  notice "[login-persist] 目录模式: patch resources/app/js"
  for rel in "${FILES[@]}"; do
    target="$root_dir/resources/app/$rel"
    if [ ! -f "$target" ]; then
      warn "[login-persist] 跳过(缺失 $rel)"
      continue
    fi
    if [ $FORCE -eq 0 ] && already_patched "$target"; then
      notice "  已打过 $rel,跳过"
      continue
    fi
    cp "$target" /tmp/login-persist.bak.js
    python3 - "$target" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
ok = False
# ------- bd3919eb: getDataPathSync 的 md5 输入 -------
old1 = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const e=process.env.ELECTRON_BASE_APP_PATH||r.app.getAppPath(),i=t.createHash("md5");return i.update(e),i.digest("hex")}'
new1 = "function n(){if(a.default.isDev)return\"111111111111111111111111111111111\";const f=process.env.WECHAT_DEVTOOLS_DATA_HASH;if(f&&/^[a-f0-9]{32}$/.test(f))return f;const i=t.createHash(\"md5\");return i.update(\"wechat-devtools-linux::\"+r.app.getName()),i.digest(\"hex\")}"
old1b = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const e=process.env.ELECTRON_BASE_APP_PATH||r.app.getAppPath(),i=(0,t.createHash)("md5");return i.update(e),i.digest("hex")}'
new1b = new1.replace('i=t.createHash', 'i=(0,t.createHash)')
# ------- c47addee: bootstrap getDataDirHash -------
old2 = '''  const md5sum = crypto.createHash('md5')
  md5sum.update(baseAppPath)
  return md5sum.digest('hex')
}'''
new2 = '''  // [linux-login-persist] AppImage 挂载点随机导致 getDataDirHash 漂移、数据目录每次重建、登录态丢失。
  // 改为固定 hash(与挂载点无关), 登录态持久; 可用 WECHAT_DEVTOOLS_DATA_HASH 覆盖。
  const forcedHash = process.env.WECHAT_DEVTOOLS_DATA_HASH
  if (forcedHash && /^[a-f0-9]{32}$/.test(forcedHash)) {
    return forcedHash
  }
  const md5sum = crypto.createHash('md5')
  md5sum.update('wechat-devtools-linux::' + app.getName())
  return md5sum.digest('hex')
}'''
if old1 in s:
    s = s.replace(old1, new1, 1); ok = True
elif old1b in s:
    s = s.replace(old1b, new1b, 1); ok = True
elif old2 in s:
    s = s.replace(old2, new2, 1); ok = True
else:
    print(f"[login-persist] 未命中待替换片段({path}), 跳过该文件(官方构建可能已变更此模块)", file=sys.stderr)
    sys.exit(0)
open(path, 'w', encoding='utf-8').write(s)
print(f"[login-persist] patched {path}")
PY
    if ! grep -q "$MARK" "$target"; then
      warn "[login-persist] 补丁未生效,请人工核对 $rel"
    fi
  done
  notice "[login-persist] 目录模式完成"
  exit 0
fi

# ---------- 模式 B: asar 模式,unpacked 覆盖 ----------
asar_file="$root_dir/resources/app.asar"
if [ ! -f "$asar_file" ]; then
  echo "[login-persist] 未找到 resources/app(目录)或 resources/app.asar,跳过"
  exit 0
fi

mkdir -p "$root_dir/resources/app.asar.unpacked/js"

for rel in "${FILES[@]}"; do
  cover="$root_dir/resources/app.asar.unpacked/$rel"
  mkdir -p "$(dirname "$cover")"
  if [ $FORCE -eq 0 ] && already_patched "$cover"; then
    notice "  已打过 $rel(unpacked),跳过"
    continue
  fi
  # 从 app.asar 提取原始文件(解析 asar v4 JSON header,无第三方依赖)
  python3 - "$asar_file" "$rel" "$cover" <<'PY'
import json, sys
asar_path, target, out = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(asar_path, 'rb').read()
i = data.find(b'{"files"')
if i < 0:
    print("[login-persist] asar header not found", file=sys.stderr)
    sys.exit(2)
dec = json.JSONDecoder()
obj, _ = dec.raw_decode(data[i:].decode('utf-8', 'replace'))
files = obj['files']

def locate(node, parts):
    cur = node
    for p in parts:
        if 'files' in cur:
            cur = cur['files']
        if p not in cur:
            return None
        cur = cur[p]
    return cur

n = locate(files, target.split('/'))
if not n:
    print(f"[login-persist] {target} not found in asar", file=sys.stderr)
    sys.exit(2)
off = int(n['offset'])
size = n['size']
with open(out, 'wb') as f:
    f.write(data[off:off + size])
print(f"[login-persist] extracted {target} ({size}B)")
PY
  if [ ! -s "$cover" ]; then
    echo "[login-persist] 提取失败: $rel"
    exit 1
  fi
  cp "$cover" /tmp/login-persist.bak.js
  python3 - "$cover" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()
ok = False
old1 = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const e=process.env.ELECTRON_BASE_APP_PATH||r.app.getAppPath(),i=t.createHash("md5");return i.update(e),i.digest("hex")}'
new1 = "function n(){if(a.default.isDev)return\"111111111111111111111111111111111\";const f=process.env.WECHAT_DEVTOOLS_DATA_HASH;if(f&&/^[a-f0-9]{32}$/.test(f))return f;const i=t.createHash(\"md5\");return i.update(\"wechat-devtools-linux::\"+r.app.getName()),i.digest(\"hex\")}"
old1b = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const e=process.env.ELECTRON_BASE_APP_PATH||r.app.getAppPath(),i=(0,t.createHash)("md5");return i.update(e),i.digest("hex")}'
new1b = new1.replace('i=t.createHash', 'i=(0,t.createHash)')
old2 = '''  const md5sum = crypto.createHash('md5')
  md5sum.update(baseAppPath)
  return md5sum.digest('hex')
}'''
new2 = '''  // [linux-login-persist] AppImage 挂载点随机导致 getDataDirHash 漂移、数据目录每次重建、登录态丢失。
  // 改为固定 hash(与挂载点无关), 登录态持久; 可用 WECHAT_DEVTOOLS_DATA_HASH 覆盖。
  const forcedHash = process.env.WECHAT_DEVTOOLS_DATA_HASH
  if (forcedHash && /^[a-f0-9]{32}$/.test(forcedHash)) {
    return forcedHash
  }
  const md5sum = crypto.createHash('md5')
  md5sum.update('wechat-devtools-linux::' + app.getName())
  return md5sum.digest('hex')
}'''
if old1 in s:
    s = s.replace(old1, new1, 1); ok = True
elif old1b in s:
    s = s.replace(old1b, new1b, 1); ok = True
elif old2 in s:
    s = s.replace(old2, new2, 1); ok = True
else:
    print(f"[login-persist] 未命中待替换片段({path}), 跳过该文件", file=sys.stderr)
    sys.exit(0)
open(path, 'w', encoding='utf-8').write(s)
print(f"[login-persist] patched {path}")
PY
  if ! grep -q "$MARK" "$cover"; then
    warn "[login-persist] 补丁未生效,请人工核对 $rel"
  fi
done

notice "[login-persist] asar 模式完成(unpacked 覆盖生效)"