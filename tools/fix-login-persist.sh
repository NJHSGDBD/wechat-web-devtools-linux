#!/bin/bash
# 修复 Electron 版微信开发者工具"每次启动都要重新扫码登录"的问题(登录态不持久)
#
# 根因(Linux AppImage 特有,已实测闭环验证):
#   工具用 md5(应用路径) 作为数据目录 hash:数据目录 = <userData>/<md5>。
#   数据目录 hash 由两处独立代码产生,任一处都会导致"目录漂移":
#     1. getDataPathSync()   → md5(ELECTRON_BASE_APP_PATH || app.getAppPath())
#        → 登录态/项目数据(LocalStorageService / AppDirService)都用它;
#     2. bootstrap getDataDirHash() → md5(app.getAppPath())
#        → bootstrap 数据根/热更新(NW 兼容层)。
#   AppImage 每次启动挂载到随机 /tmp/.mount_XXXX,app.getAppPath() 随之变化,
#   两处 hash 每次都不同 → 每次启动都新建空数据目录:
#     - 上次登录写入的 <userData>/<旧hash>/WeappLocalData/ls_<md5("userInfo")>.json
#       (登录态,含签名票据,与 ls_encrypt_secret.json 密钥文件成对)读不到;
#     - isLogin 判定返回空 → 判定未登录 → 每次都要扫码,还留下 ~300MB 孤儿目录。
#   Windows/常规安装时 app.getAppPath() 固定,官方不会有此问题。
#
# 方案:把两处 hash 的输入从动态 appPath 改为固定值
#   md5("wechat-devtools-linux::" + app.getName()),数据目录 hash 恒定,
#   登录态/项目数据天然持久;另支持环境变量 WECHAT_DEVTOOLS_DATA_HASH
#   (32位hex)显式指定,便于需要隔离的场景。
#
# 两个适配形态(运行时加载的 js 不同,补丁目标也不同):
#   A. 目录模式(resources/app 存在,本仓库构建树可运行形态):
#      目标 = resources/app/js/{bd3919eb…,c47addee…}(Linux 构建独立模块),直接改文件。
#   B. asar 模式(只有 resources/app.asar,官方 continuous 包形态):
#      Linux 运行时 electron 自动加载 app.asar;目标模块在官方 asar 中被打包进大
#      bundle(js/common/cloud-functions-debugger-server/index.js 等),文件名不可预测,
#      因此按内容扫描定位(含 getDataDirHash / getDataPathSync 特征),改后写入
#      resources/app.asar.unpacked/<同路径> 同名覆盖(Electron require 时优先读取
#      unpacked 同名文件,无需重打 asar)。本机实测:官方包 asar 内两处 hash
#      逻辑集中在该 bundle,补丁后数据目录固定为 7770ddce…,启动免登录。
#
# 幂等:已含补丁标记则跳过;--force 强制重打。
# 兼容 python3.8+(CI/GitHub Actions 环境)。

set -e
script_dir="$(cd `dirname $0` && pwd -P)"
root_dir="${WDT_BUILD_ROOT:-$(cd `dirname $0`/.. && pwd -P)}"
source "$script_dir/error-handler.sh"
devtools_enable_error_trap

MARK="wechat-devtools-linux::"
FORCE=0
[ "$1" = "--force" ] && FORCE=1

notice() { echo -e "\033[36m $1 \033[0m"; }
warn() { echo -e "\033[43;37m 警告 \033[0m $1"; }

# ---------- 模式 A: 目录树存在,直接 patch ----------
if [ -d "$root_dir/resources/app/js" ]; then
  notice "[login-persist] 目录模式: patch resources/app/js"
  for rel in \
    "js/bd3919eb5ba5af9000b9c9b25a078747.js" \
    "js/c47addee36149e53772b60ab7e158ffe.js"; do
    target="$root_dir/resources/app/$rel"
    if [ ! -f "$target" ]; then
      warn "[login-persist] 跳过(缺失 $rel)"
      continue
    fi
    if [ $FORCE -eq 0 ] && grep -q "$MARK" "$target" 2>/dev/null; then
      notice "  已打过 $rel,跳过"
      continue
    fi
    cp "$target" /tmp/login-persist.bak.js
    python3 - "$target" <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
s = data.decode('utf-8', 'surrogateescape')
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
ok = False
for old, new in ((old1, new1), (old1b, new1b), (old2, new2)):
    if old in s:
        s = s.replace(old, new, 1); ok = True
        break
if ok:
    open(path, 'wb').write(s.encode('utf-8', 'surrogateescape'))
    print("[login-persist] patched %s" % path)
else:
    print("[login-persist] 未命中待替换片段(%s), 跳过(官方构建可能已变更此模块)" % path, file=sys.stderr)
PY
    if ! grep -q "$MARK" "$target"; then
      warn "[login-persist] 补丁未生效,请人工核对 $rel"
    fi
  done
  notice "[login-persist] 目录模式完成"
  exit 0
fi

# ---------- 模式 B: asar 模式(官方 continuous 包形态)----------
# 关键事实(本机实测):asar v4 节点 offset 是"相对内容区起点(base)"的相对偏移,
# base = 16B 文件头 + header JSON + 4 字节对齐(官方包实测 8090916)。直接按 offset
# 绝对读取会错位(读到别的文件),导致旧实现 patch 全部 miss / utf-8 崩溃。
# asar 内 js 与解包树是同一批 webpack 产物:js/bd3919eb…(getDataPathSync, 压缩单行)
# 与 js/c47addee…(getDataDirHash, 格式化)都在,文件名固定可见,无需内容扫描。
# 做法:读(base+offset)原内容 → 替换两处 hash 逻辑 → 写入 app.asar.unpacked 同名文件,
# 同时在 asar header 目标节点加 "unpacked": true(官方约定,electron 改读 unpacked)。
# asar 用"等长 header 重写"(JSON 尾部补空白),内容区一个字节都不动。
asar_file="$root_dir/resources/app.asar"
if [ ! -f "$asar_file" ]; then
  echo "[login-persist] 未找到 resources/app(目录)或 resources/app.asar,跳过"
  exit 0
fi

python3 - "$asar_file" "$root_dir" "$MARK" "$FORCE" <<'PY'
import json, os, struct, sys
asar_path, root_dir, mark = sys.argv[1], sys.argv[2], sys.argv[3]
force = sys.argv[4] == '1'
unpacked_root = os.path.join(root_dir, 'resources', 'app.asar.unpacked')

data = open(asar_path, 'rb').read()
hdr = struct.unpack('<4I', data[:16])
json_len = hdr[3]
# asar v4 内容区 base = 16B 文件头 + JSON + 4 字节对齐(官方包实测 base=8090916)
base = 16 + json_len + ((4 - (16 + json_len) % 4) % 4)
obj = json.loads(data[16:16 + json_len].decode('utf-8', 'replace'))
root = obj['files']

FILES = [
    'js/bd3919eb5ba5af9000b9c9b25a078747.js',
    'js/c47addee36149e53772b60ab7e158ffe.js',
]

old1 = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const e=process.env.ELECTRON_BASE_APP_PATH||r.app.getAppPath(),i=t.createHash("md5");return i.update(e),i.digest("hex")}'
new1 = 'function n(){if(a.default.isDev)return"111111111111111111111111111111111";const f=process.env.WECHAT_DEVTOOLS_DATA_HASH;if(f&&/^[a-f0-9]{32}$/.test(f))return f;const i=t.createHash("md5");return i.update("wechat-devtools-linux::"+r.app.getName()),i.digest("hex")}'
old1b = old1.replace('i=t.createHash', 'i=(0,t.createHash)')
new1b = new1.replace('i=t.createHash', 'i=(0,t.createHash)')
old2 = '  const md5sum = crypto.createHash(\'md5\')\n  md5sum.update(baseAppPath)\n  return md5sum.digest(\'hex\')\n}'
new2 = ('  // [linux-login-persist] AppImage 挂载点随机导致 getDataDirHash 漂移、数据目录每次重建、登录态丢失。\n'
        '  // 改为固定 hash(与挂载点无关), 登录态持久; 可用 WECHAT_DEVTOOLS_DATA_HASH 覆盖。\n'
        "  const forcedHash = process.env.WECHAT_DEVTOOLS_DATA_HASH\n"
        '  if (forcedHash && /^[a-f0-9]{32}$/.test(forcedHash)) {\n'
        '    return forcedHash\n'
        '  }\n'
        "  const md5sum = crypto.createHash('md5')\n"
        "  md5sum.update('wechat-devtools-linux::' + app.getName())\n"
        "  return md5sum.digest('hex')\n"
        '}')
VARIANTS = [
    (old1.encode('utf-8', 'surrogateescape'), new1.encode('utf-8', 'surrogateescape')),
    (old1b.encode('utf-8', 'surrogateescape'), new1b.encode('utf-8', 'surrogateescape')),
    (old2.encode('utf-8', 'surrogateescape'), new2.encode('utf-8', 'surrogateescape')),
]

patch_count = 0
for rel in FILES:
    cur = root
    for p in rel.split('/'):
        cur = cur['files'] if 'files' in cur else cur
        cur = cur[p]
    if cur is None:
        print("[login-persist] asar 中不存在 %s, 跳过" % rel, file=sys.stderr)
        continue
    out = os.path.join(unpacked_root, rel)
    if not force and os.path.exists(out):
        with open(out, 'rb') as f:
            if mark.encode() in f.read():
                print("[login-persist] 已打过 %s(unpacked), 跳过" % rel)
                continue
    if 'offset' not in cur:
        print("[login-persist] %s 已是 unpacked(无 offset), 跳过" % rel, file=sys.stderr)
        continue
    off, size = int(cur['offset']), cur['size']
    raw = data[base + off: base + off + size]
    body = raw
    hit = 0
    for old, new in VARIANTS:
        c = body.count(old)
        if c > 0:
            body = body.replace(old, new)
            hit += c
    if hit > 0:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'wb') as f:
            f.write(body)
        # 官方约定的 unpacked 标记:节点带 unpacked:true 且无 offset(electron 读 app.asar.unpacked 同名文件)
        cur['unpacked'] = True
        cur.pop('offset', None)
        print("[login-persist] patched %s (asar内 %dB, 替换 %d 处, 写入 unpacked)" % (rel, size, hit))
        patch_count += 1
    else:
        print("[login-persist] %s 未命中待替换片段(官方构建可能已变更), 跳过" % rel, file=sys.stderr)

if patch_count == 0:
    print("[login-persist] 无任何目标被 patch, 请人工核对", file=sys.stderr)
    sys.exit(1)

new_json = json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode('utf-8', 'replace')
if len(new_json) > json_len:
    print("[login-persist] 新 header 过长(unpacked 标记不应变长), 中止", file=sys.stderr)
    sys.exit(1)
new_json = new_json + b' ' * (json_len - len(new_json))  # 尾部空白补足等长(JSON 合法)
tmp = asar_path + '.login-persist.tmp'
with open(tmp, 'wb') as f:
    f.write(data[:16])
    f.write(new_json)
    f.write(data[16 + json_len:])
os.replace(tmp, asar_path)
print("[login-persist] asar 重写完成(等长 header, 内容区不变)")
PY
echo "  [login-persist] asar 模式完成(unpacked 覆盖 + unpacked 标记生效)"
