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
[[ ! -e "$work" && ! -e "$out" ]]
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

stage=W4
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
make download -j"$jobs" V=s 2>&1 | tee "$work/logs/download.log"
make -j"$jobs" V=s 2>&1 | tee "$work/logs/build.log"

stage=W6
mapfile -d '' images < <(find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*phicomm_k2p*sysupgrade.bin' -print0)
(( ${#images[@]} == 1 )) || { printf 'Expected exactly one K2P sysupgrade image\n' >&2; exit 1; }
fw=$(realpath "${images[0]}")
[[ -s "$fw" ]]
image_size=$(stat -c%s "$fw")
printf 'image_size_bytes=%s\n' "$image_size" >> "$out/image-check.txt"
(( image_size <= 15744 * 1024 )) || { printf 'Final image exceeds the 15744 KiB firmware partition\n' >&2; exit 1; }
file "$fw" >> "$out/image-check.txt"
python3 scripts/json_overview_image_info.py "$fw" > "$out/image-info.json" 2>"$out/image-info.err" || { cat "$out/image-info.err" >&2; exit 1; }
grep -q '"k2p"' "$out/image-info.json" || { printf 'Image metadata does not list the K2P device\n' >&2; cat "$out/image-info.json" >&2; exit 1; }
mapfile -d '' roots < <(find bin/targets/ramips/mt7621 -type f -name 'root.squashfs' -print0)
(( ${#roots[@]} == 1 )) || { printf 'Expected exactly one root filesystem image\n' >&2; exit 1; }
rootfs=$(realpath "${roots[0]}")
unsquashfs -l "$rootfs" > "$out/rootfs-listing.txt" 2>&1 || { printf 'Cannot list root filesystem\n' >&2; exit 1; }
for name in etc/wireless/l1profile.dat etc/wireless/mt7615/mt7615.1.dat etc/wireless/mt7615/mt7615.2.dat usr/sbin/iwpriv usr/sbin/smartdns usr/sbin/dnsmasq; do
  grep -q "$name" "$out/rootfs-listing.txt" || { printf 'Missing image content: %s\n' "$name" >&2; exit 1; }
  printf 'present: %s\n' "$name" >> "$out/image-check.txt"
done
if grep -q 'etc/wireless/mt7603' "$out/rootfs-listing.txt"; then
  printf 'Unexpected MT7603 radio configuration present\n' >&2
  exit 1
fi
grep 'etc/uci-defaults/' "$out/rootfs-listing.txt" | awk '{print $NF}' | sort -u > "$out/upstream-uci-defaults.txt" || true
git diff --exit-code > "$out/source-tree-diff.txt" 2>&1 || { printf 'Tracked source files changed during the build\n' >&2; cat "$out/source-tree-diff.txt" >&2; exit 1; }
for name in packages luci routing; do git -C "feeds/$name" diff --exit-code || exit 1; done
find bin/targets/ramips/mt7621 -maxdepth 1 -type f -name '*.manifest' -exec cp '{}' "$out/" \;
compgen -G "$out/*.manifest" > /dev/null
cp "$fw" "$out/"
cp "$base/configs/k2p.seed.config" "$out/seed.config"
for name in config download build; do gzip -n -c "$work/logs/$name.log" > "$out/$name.log.gz"; done
printf 'Candidate build only. No device boot, radio stability or Breed compatibility test has been performed. Back up and verify the device before any manual flashing.\n' > "$out/verification-scope.txt"
cd "$out"
find . -maxdepth 1 -type f ! -name sha256sums -print0 | sort -z | xargs -0 sha256sum > sha256sums
sha256sum -c sha256sums
printf 'All cloud-side checks passed; device validation remains outstanding.\n' >> "$GITHUB_STEP_SUMMARY"
