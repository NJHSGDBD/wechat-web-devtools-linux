#!/bin/bash
root_dir=$(cd `dirname $0`/.. && pwd -P)
source "$root_dir/tools/error-handler.sh"
devtools_enable_error_trap
set -ex

# 从js获取配置
electron_url=$(node "$root_dir/tools/parse-config.js" --get-electron-url $@)
file_name=$(basename "$electron_url")
# 备用源:github releases(与 npmmirror 文件一致,互为兜底,避免单点网络 504)
secondary_url=$(echo "$electron_url" | sed 's#https://npmmirror.com/mirrors/electron/v#https://github.com/electron/electron/releases/download/v#')
# download
local_path="$root_dir/cache/$file_name"
if [ ! -f "$local_path" ]; then
    for url in "$electron_url" "$secondary_url"; do
        echo "[update-electron] downloading $url"
        if wget -c -T 120 --tries=5 -O "$local_path.tmp" "$url"; then
            mv "$local_path.tmp" "$local_path"
            break
        fi
        echo "[update-electron] download failed, trying next source"
        rm -f "$local_path.tmp"
    done
    if [ ! -f "$local_path" ]; then
        echo "[update-electron] all download sources failed" >&2
        exit 1
    fi
fi
# extract
rm -rf "$root_dir/electron"
mkdir -p "$root_dir/electron"
unzip -q "$local_path" -d "$root_dir/electron"

if [ -f "$root_dir/node/bin/node" ]; then
    cd "$root_dir/electron"
    cp ../node/bin/node node
    ln -s node node.exe
    ln -s node node-18.exe
fi

if [ -d "$root_dir/resources" ]; then
    cd "$root_dir/electron"
    rm -rf resources
    ln -sr ../resources resources
fi
