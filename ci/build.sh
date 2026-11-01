#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && $(uname -s) == Linux ]] || { printf 'GitHub Linux runner required\n' >&2; exit 2; }
base=$GITHUB_WORKSPACE
work=$base/work
out=$base/deliverable
stage=W2
report() {
  rc=$?
  mkdir -p "$out"
  printf 'stage=%s exit=%s\n' "$stage" "$rc" > "$out/stage-exit.txt"
  for f in "$work"/logs/*.log; do
    [ -f "$f" ] && gzip -n -c "$f" > "$out/$(basename "$f").gz"
  done
  printf 'stage=%s exit=%s\n' "$stage" "$rc" >> "$GITHUB_STEP_SUMMARY"
  return $rc
}
trap report EXIT
if [[ -e "$work" ]]; then
  # a restored download cache may pre-create work/lede/dl; nothing else may exist
  mapfile -t pre < <(find "$work" -mindepth 1 -maxdepth 1 -printf '%f
')
  [[ ${#pre[@]} -eq 1 && "${pre[0]}" == lede && -d "$work/lede/dl" && $(find "$work/lede" -mindepth 1 -maxdepth 1 -printf '%f
' | wc -l) -eq 1 ]] || { printf 'Unexpected pre-existing work tree
' >&2; exit 1; }
fi
[[ ! -e "$out" ]]
mkdir -p "$work/feed-sources" "$work/logs" "$out"
{
  uname -a
  nproc
  free -h
  df -h "$base"
  printf 'workflow_commit=%s\nrun=%s\n' "$GITHUB_SHA" "$GITHUB_RUN_ID"
} | tee "$out/environment.txt"
free_kb=$(df -Pk "$base" | awk 'NR==2 {print $4}')
(( free_kb >= 30 * 1024 * 1024 )) || { printf 'Insufficient free disk: require 30 GiB\n' >&2; exit 1; }
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential gcc-multilib g++-multilib \
  git gawk gettext flex bison libncurses-dev libssl-dev zlib1g-dev libelf-dev \
  python3 python3-setuptools rsync unzip file wget curl ccache swig patch \
  pkg-config autoconf automake libtool gperf squashfs-tools jq zstd
free_kb=$(df -Pk "$base" | awk 'NR==2 {print $4}')
(( free_kb >= 30 * 1024 * 1024 ))
jobs=$(nproc)
(( jobs <= 4 )) || jobs=4
available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( available_kb >= 4 * 1024 * 1024 ))
(( available_kb >= 8 * 1024 * 1024 )) || jobs=2
printf 'build_jobs=%s\n' "$jobs" >> "$out/environment.txt"

stage=W3
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W3"
export GIT_TERMINAL_PROMPT=0
while read -r name url sha; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
  case "$name" in
    lede) directory=$work/lede ;;
    packages|luci|routing) directory=$work/feed-sources/$name ;;
    *) printf 'Unapproved source: %s\n' "$name" >&2; exit 1 ;;
  esac
  git init "$directory"
  git -C "$directory" remote add origin "$url"
  git -C "$directory" fetch --depth 1 origin "$sha"
  git -C "$directory" checkout --detach "$sha"
  [[ $(git -C "$directory" rev-parse HEAD) == "$sha" ]]
  printf '%s %s %s\n' "$name" "$url" "$sha" >> "$out/sources.lock"
done < "$base/configs/sources.lock"
cd "$work/lede"
grep -Fq 'src-link' scripts/feeds
for name in packages luci routing; do
  printf 'src-link %s %s\n' "$name" "$work/feed-sources/$name"
done > feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
for name in packages luci routing; do
  expected=$(awk -v n="$name" '$1==n {print $3}' "$base/configs/sources.lock")
  actual=$(git -C "feeds/$name" rev-parse HEAD)
  [[ "$actual" == "$expected" ]]
  printf '%s %s\n' "$name" "$actual" >> "$out/feeds.lock"
done
git rev-parse HEAD > "$out/source.lock"

mkdir -p "$work/lede/files/usr/lib/lua" "$work/lede/files/etc/wireless"
cp "$base/assets/l1dat_parser.lua" "$work/lede/files/usr/lib/lua/l1dat_parser.lua"
cp "$base/assets/l1profile.dat" "$work/lede/files/etc/wireless/l1profile.dat"
mkdir -p "$work/lede/files/etc/init.d"
cp "$base/assets/firmware.sh" "$work/lede/files/etc/init.d/firmware.sh"
mkdir -p "$work/lede/files/usr/lib/lua/luci/view/admin_mtk"
mkdir -p "$work/lede/files/etc/uci-defaults"
cp "$base/assets/99-k2p-lan-ip" "$work/lede/files/etc/uci-defaults/99-k2p-lan-ip"
chmod 0755 "$work/lede/files/etc/uci-defaults/99-k2p-lan-ip"
[[ -x "$work/lede/files/etc/uci-defaults/99-k2p-lan-ip" ]]
python3 "$base/assets/patch-templates.py" "$work/lede" "$work/lede/files"
compgen -G "$work/lede/files/usr/lib/lua/luci/view/admin_mtk/*.htm" > /dev/null
printf 'Patched mtwifi templates: svg icons and buffered profile listing
'
chmod 0755 "$work/lede/files/etc/init.d/firmware.sh"
[[ -s "$work/lede/files/usr/lib/lua/l1dat_parser.lua" && -s "$work/lede/files/etc/wireless/l1profile.dat" && -x "$work/lede/files/etc/init.d/firmware.sh" ]]
printf 'W4: installed l1dat_parser and l1profile overrides
'

# ---- 驱动源码补丁 ----
# 闭源 mt7615d 的补丁必须在编译前应用。用 patch 而不是直接改文件，
# 是为了让补丁是否真的打上由构建流程自证（apply 失败即中止）。
stage=W4P
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W4P"
mtwifi_src="$work/lede/package/lean/mt/drivers/mt7615d/src/mt_wifi"
[[ -d "$mtwifi_src" ]] || { printf 'mt7615d source tree not found: %s\n' "$mtwifi_src" >&2; exit 1; }
for p in "$base"/patches/*.patch; do
  [[ -e "$p" ]] || continue
  printf 'applying %s\n' "$(basename "$p")"
  patch -p1 -d "$mtwifi_src" < "$p" || { printf 'Failed to apply %s\n' "$p" >&2; exit 1; }
  # 应用后自证：补丁必须真的改到了源码，而不是被静默跳过
  patch -p1 -R --dry-run -d "$mtwifi_src" < "$p" >/dev/null 2>&1 || { printf 'Patch %s did not take effect\n' "$p" >&2; exit 1; }
  # 让后面的 git diff --exit-code（工作区 vs 索引）通过：把改动放进索引
  git -C "$work/lede" add -A -- package/lean/mt/drivers/mt7615d/src/mt_wifi
done
printf 'W4P: driver patches applied
'

stage=W4
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W4"
grep -Fq 'define Device/phicomm_k2p' target/linux/ramips/image/mt7621.mk
grep -Eq 'IMAGE_SIZE[[:space:]]*:=[[:space:]]*15744k' target/linux/ramips/image/mt7621.mk
[[ ! -e .config ]]
cp "$base/configs/k2p.seed.config" .config
make defconfig 2>&1 | tee "$work/logs/config.log"
{
  echo '=== providers of packages this build tries to keep absent ==='
  for symbol in luci-compat kmod-ipt-offload luci-proto-ipv6 default-settings; do
    echo "--- $symbol"
    grep -R --include=Makefile -l "+$symbol" package/ feeds/ 2>/dev/null | head -10 || true
  done
  echo '=== resolved values of tracked symbols ==='
  grep -E 'CONFIG_PACKAGE_(luci-compat|default-settings|luci-proto-ipv6|kmod-ipt-offload|luci-app-turboacc|kmod-mt7615d_dbdc|mt_wifi|luci-app-mtwifi)=' .config || true
} | tee "$work/logs/exclusion-providers.txt"
bash "$base/ci/verify-config.sh" "$base/configs/k2p.seed.config" .config 2>&1 | tee "$out/config-check.txt"
[[ $(grep -Ec '^CONFIG_TARGET_ramips_mt7621_DEVICE_.*=y$' .config) == 1 ]]
cp .config "$out/config.snapshot"
./scripts/diffconfig.sh > "$out/config.diff"
[[ -s "$out/config.diff" ]]
cp "$out/config.diff" .config
make defconfig >> "$work/logs/config.log" 2>&1
bash "$base/ci/verify-config.sh" "$base/configs/k2p.seed.config" .config
./scripts/diffconfig.sh > "$work/reproduced.diff"
cmp "$out/config.diff" "$work/reproduced.diff"
printf 'Required/forbidden settings and minimal configuration reconstruction passed\n' >> "$out/config-check.txt"

stage=W5
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W5"
{
  echo '=== disk before download ==='
  df -h "$base"
} | tee "$work/logs/disk.log"
make download -j"$jobs" 2>&1 | tee "$work/logs/download.log"
{
  echo '=== disk after download ==='
  df -h "$base"
  du -sh "$work/lede/dl" 2>/dev/null || true
} | tee -a "$work/logs/disk.log"

# 先把交叉工具链、内核、闭源驱动串行编出来：这三步是最高风险组件，
# 串行可避免驱动在内核产物就绪前启动；失败时日志带 V=s，可直接看到错误行。
stage=W5T
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W5T"
make toolchain/install -j"$jobs" 2>&1 | tee "$work/logs/toolchain-compile.log"
stage=W5K
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W5K"
make target/linux/compile V=s 2>&1 | tee "$work/logs/kernel-compile.log"
kernel_dir=$(find "$work/lede/build_dir" -maxdepth 2 -type d -name 'linux-ramips_*' | head -1)
[[ -n "$kernel_dir" && -f "$kernel_dir/Module.symvers" && -f "$kernel_dir/.modules" ]] \
  || { printf 'Kernel build artefacts missing (kernel_dir=%s)\n' "$kernel_dir" >&2; exit 1; }
printf 'W5K: kernel built at %s
' "$kernel_dir"
stage=W5D
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W5D"
make package/lean/mt/drivers/mt7615d/compile V=s 2>&1 | tee "$work/logs/mtwifi-compile.log"
[[ -f "$work/lede/build_dir/target-mipsel_24kc_musl/linux-ramips_mt7621/mt7615d-5.0.4.0/mt_wifi_ap/mt_wifi.ko" ]] \
  || { printf 'mt_wifi.ko was not produced\n' >&2; exit 1; }
printf 'W5D: mt_wifi.ko built\n'

stage=W5
make -j"$jobs" 2>&1 | tee "$work/logs/build.log"
{
  echo '=== disk after build ==='
  df -h "$base"
  du -sh "$work/lede/build_dir" "$work/lede/staging_dir" "$work/lede/tmp" 2>/dev/null || true
} | tee -a "$work/logs/disk.log"

stage=W6
printf 'T+%s %s begin
' "$(date -u +%H:%M:%S)" "W6"
printf 'W6: start image verification
'
mapfile -d '' images < <(find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*phicomm_k2p*sysupgrade.bin' -print0)
(( ${#images[@]} == 1 )) || { printf 'Expected exactly one K2P sysupgrade image\n' >&2; exit 1; }
fw=$(realpath "${images[0]}")
[[ -s "$fw" ]]
image_size=$(stat -c%s "$fw")
printf 'W6: image size %s
' "$image_size"
printf 'image_size_bytes=%s\n' "$image_size" >> "$out/image-check.txt"
(( image_size <= 15744 * 1024 )) || { printf 'Final image exceeds the 15744 KiB firmware partition\n' >&2; exit 1; }
file "$fw" >> "$out/image-check.txt"
printf 'W6: extracting metadata
'
staging_dir/host/bin/fwtool -q -i "$out/image-metadata.json" "$fw"
[[ -s "$out/image-metadata.json" ]] || { printf 'Image metadata could not be extracted\n' >&2; exit 1; }
grep -q '"k2p"' "$out/image-metadata.json" || { printf 'Image metadata does not list the K2P device\n' >&2; cat "$out/image-metadata.json" >&2; exit 1; }
mapfile -d '' profile_json < <(find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*.json' -print0)
if (( ${#profile_json[@]} > 0 )); then
  WORK_DIR="$PWD/bin/targets/ramips/mt7621" python3 scripts/json_overview_image_info.py "$out/profiles-overview.json" || true
fi
printf 'W6: locating root filesystem
'
mapfile -d '' roots < <(find bin/targets/ramips/mt7621 -type f -name 'root.squashfs' -print0)
if (( ${#roots[@]} >= 1 )); then
  rootfs=$(realpath "${roots[0]}")
  rootfs_opts=""
  unsquashfs -l "$rootfs" > "$out/rootfs-listing.txt" 2>&1 || { printf 'Cannot list root filesystem\n' >&2; exit 1; }
else
  python3 - "$fw" "$work/rootfs-offset" <<'PY'
import pathlib, subprocess, sys
image, output = map(pathlib.Path, sys.argv[1:])
data = image.read_bytes()
position = data.find(b'hsqs')
while position >= 0:
    result = subprocess.run(['unsquashfs', '-s', '-o', str(position), str(image)], capture_output=True)
    if result.returncode == 0:
        output.write_text(str(position))
        break
    position = data.find(b'hsqs', position + 1)
else:
    raise SystemExit('No valid squashfs root filesystem found inside the image')
PY
  offset=$(< "$work/rootfs-offset")
  rootfs=$fw
  rootfs_opts="-o $offset"
  unsquashfs -l -o "$offset" "$fw" > "$out/rootfs-listing.txt" 2>&1 || { printf 'Cannot list the root filesystem inside the image\n' >&2; exit 1; }
fi
for name in usr/lib/lua/l1dat_parser.lua etc/wireless/l1profile.dat etc/wireless/mt7615/mt7615.1.2G.dat etc/wireless/mt7615/mt7615.1.5G.dat usr/sbin/iwpriv usr/sbin/smartdns usr/sbin/dnsmasq; do
  printf 'W6: checking %s\n' "$name"
  grep -q "$name" "$out/rootfs-listing.txt" || { printf 'Missing image content: %s\n' "$name" >&2; exit 1; }
  printf 'present: %s\n' "$name" >> "$out/image-check.txt"
done
if grep -q 'etc/wireless/mt7615/mt7615\.1\.dat' "$out/rootfs-listing.txt"; then
  printf 'Unexpected fallback-branch profile present, expected the DBDC branch\n' >&2
  exit 1
fi
if grep -q 'etc/wireless/mt7603' "$out/rootfs-listing.txt"; then
  printf 'Unexpected MT7603 radio configuration present\n' >&2
  exit 1
fi
printf 'W6: verifying mount-point removal
'
# 挂载点功能已删除：/sbin/block、/etc/config/fstab、/etc/init.d/fstab 都不应存在
for gone in sbin/block etc/config/fstab etc/init.d/fstab; do
  if grep -q "$gone" "$out/rootfs-listing.txt"; then
    printf 'Mount-point feature still present in the image: %s\n' "$gone" >&2
    exit 1
  fi
  printf 'absent: %s\n' "$gone" >> "$out/image-check.txt"
done
# fstools 必须保留：overlay / mount_root 依赖它的 libfstools.so，与 block-mount 是两个独立包
grep -q 'libfstools\.so' "$out/rootfs-listing.txt" || { printf 'fstools missing (libfstools.so), overlay would break\n' >&2; exit 1; }
printf 'present: libfstools.so\n' >> "$out/image-check.txt"
printf 'W6: verifying the apcli EDCA override landed in the driver
'
# 驱动补丁是否真的编进了 .ko：用字符串自证，而不是相信补丁应用成功
ko=$(find "$work/lede" -path '*mt_wifi.ko' -type f 2>/dev/null | head -1)
[[ -n "$ko" ]] || { printf 'mt_wifi.ko not found in the build tree\n' >&2; exit 1; }
strings "$ko" | grep -q 'ApCliEdcaCwmin' || { printf 'Driver lacks the ApCliEdcaCwmin profile key\n' >&2; exit 1; }
printf 'driver supports ApCliEdcaCwmin\n' >> "$out/image-check.txt"
printf 'W6: verifying boot hook content
'
if command -v unsquashfs >/dev/null && [ -n "${rootfs:-}" ]; then
  hook=$(unsquashfs -cat ${rootfs_opts:-} "$rootfs" etc/init.d/firmware.sh 2>/dev/null)
  printf '%s\n' "$hook" | grep -q "mtkwifi up" || { printf 'Boot hook missing from the image
' >&2; exit 1; }
  printf '%s\n' "$hook" | grep -qx "START=40" || { printf 'Boot hook must start after S20network (START=40)
' >&2; exit 1; }
  printf '%s\n' "$hook" | grep -q "mkdir -p /tmp/profiles" || { printf 'Boot hook must create /tmp/profiles before mtkwifi up
' >&2; exit 1; }
  unsquashfs -cat ${rootfs_opts:-} "$rootfs" usr/lib/lua/luci/view/admin_mtk/mtk_wifi_dev_cfg.htm 2>/dev/null | grep -q "print(line)" && { printf 'Unpatched mtwifi template in the image
' >&2; exit 1; }
  unsquashfs -cat ${rootfs_opts:-} "$rootfs" usr/lib/lua/mtkwifi.lua 2>/dev/null | grep -q "pcall(io.popen" || { printf 'Unpatched mtkwifi.read_pipe in the image
' >&2; exit 1; }
  printf 'OK: boot hook present in image
' >> "$out/image-check.txt"
fi
grep 'etc/uci-defaults/' "$out/rootfs-listing.txt" | awk '{print $NF}' | sort -u > "$out/upstream-uci-defaults.txt" || true
git diff --exit-code > "$out/source-tree-diff.txt" 2>&1 || { printf 'Tracked source files changed during the build\n' >&2; cat "$out/source-tree-diff.txt" >&2; exit 1; }
for name in packages luci routing; do git -C "feeds/$name" diff --exit-code || exit 1; done
find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*.manifest' -exec cp '{}' "$out/" \;
compgen -G "$out/*.manifest" > /dev/null
cp "$fw" "$out/"
cp "$base/configs/k2p.seed.config" "$out/seed.config"
for name in config download build toolchain-compile kernel-compile mtwifi-compile; do
  [[ -f "$work/logs/$name.log" ]] || continue
  gzip -n -c "$work/logs/$name.log" > "$out/$name.log.gz"
done
printf 'Candidate build only. No device boot, radio stability or Breed compatibility test has been performed. Back up and verify the device before any manual flashing.\n' > "$out/verification-scope.txt"
cd "$out"
find . -maxdepth 1 -type f ! -name sha256sums -print0 | sort -z | xargs -0 sha256sum > sha256sums
sha256sum -c sha256sums
printf 'All cloud-side checks passed; device validation remains outstanding.\n' >> "$GITHUB_STEP_SUMMARY"
