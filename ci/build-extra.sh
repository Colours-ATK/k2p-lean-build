#!/usr/bin/env bash
# Compile extra packages (xkcptun and its LuCI app) against the pinned Lean
# tree without touching the validated image pipeline (ci/build.sh).
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
[[ ! -e "$out" ]]
mkdir -p "$work/feed-sources" "$work/logs" "$out/ipk"

stage=W2
printf 'T+%s %s begin\n' "$(date -u +%H:%M:%S)" "W2"
{
  uname -a
  printf 'free_kb=%s\n' "$(df -Pk "$base" | awk 'NR==2 {print $4}')"
  printf 'mem_available_kb=%s\n' "$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
} >> "$out/environment.txt"
free_kb=$(df -Pk "$base" | awk 'NR==2 {print $4}')
(( free_kb >= 20 * 1024 * 1024 ))
available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
(( available_kb >= 4 * 1024 * 1024 ))
jobs=$(nproc)
(( jobs <= 4 )) || jobs=4
(( available_kb >= 8 * 1024 * 1024 )) || jobs=2
printf 'build_jobs=%s\n' "$jobs" >> "$out/environment.txt"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  git gawk gettext flex bison libncurses-dev libssl-dev zlib1g-dev libelf-dev \
  python3 python3-setuptools rsync unzip file wget curl ccache swig patch \
  pkg-config autoconf automake libtool gperf squashfs-tools jq zstd cmake \
  lua5.1 > "$work/logs/apt.log" 2>&1

stage=W3
printf 'T+%s %s begin\n' "$(date -u +%H:%M:%S)" "W3"
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

stage=W4
printf 'T+%s %s begin\n' "$(date -u +%H:%M:%S)" "W4"
mkdir -p package/xkcptun package/luci-app-xkcptun
cp -a "$base/packages/xkcptun/." package/xkcptun/
cp -a "$base/packages/luci-app-xkcptun/." package/luci-app-xkcptun/
for f in package/xkcptun/Makefile package/xkcptun/files/xkcptun.config package/xkcptun/files/xkcptun.init package/xkcptun/LICENSE package/luci-app-xkcptun/Makefile package/luci-app-xkcptun/luasrc/controller/xkcptun.lua package/luci-app-xkcptun/luasrc/model/cbi/xkcptun.lua; do
  [[ -s "$f" ]] || { printf 'missing vendored file: %s\n' "$f" >&2; exit 1; }
done
lua5.1 -e 'assert(loadfile("package/luci-app-xkcptun/luasrc/controller/xkcptun.lua"))' || { printf 'controller lua syntax error\n' >&2; exit 1; }
lua5.1 -e 'assert(loadfile("package/luci-app-xkcptun/luasrc/model/cbi/xkcptun.lua"))' || { printf 'cbi lua syntax error\n' >&2; exit 1; }
printf 'Vendored packages and Lua syntax checks passed\n' >> "$out/environment.txt"

cat > .config <<'EOF'
CONFIG_TARGET_ramips=y
CONFIG_TARGET_ramips_mt7621=y
CONFIG_TARGET_ramips_mt7621_DEVICE_phicomm_k2p=y
CONFIG_PACKAGE_libevent2=m
CONFIG_PACKAGE_xkcptun=m
CONFIG_PACKAGE_luci-compat=m
CONFIG_PACKAGE_luci-lib-ipkg=m
CONFIG_PACKAGE_luci-app-xkcptun=m
EOF
make defconfig 2>&1 | tee "$work/logs/config.log"
cp .config "$out/config.snapshot"
{
  echo '=== resolved values of the tracked package symbols ==='
  grep -E '^(# )?CONFIG_PACKAGE_(libevent2|xkcptun|luci-compat|luci-lib-ipkg|luci-app-xkcptun|luci-base|lua5\.1|liblua|luci)=' .config || true
} | tee "$out/selection.txt"
for symbol in libevent2 xkcptun luci-compat luci-lib-ipkg luci-app-xkcptun; do
  grep -qE "^CONFIG_PACKAGE_$symbol=(m|y)$" .config || { printf 'package not selected: %s\n' "$symbol" >&2; exit 1; }
done

stage=W5
printf 'T+%s %s begin\n' "$(date -u +%H:%M:%S)" "W5"
make download -j"$jobs" 2>&1 | tee "$work/logs/download.log"
for p in libevent2 xkcptun luci-compat luci-lib-ipkg luci-app-xkcptun; do
  make "package/$p/compile" -j"$jobs" 2>&1 | tee "$work/logs/build-$p.log"
done

stage=W6
printf 'T+%s %s begin\n' "$(date -u +%H:%M:%S)" "W6"
find bin/packages -name '*.ipk' -type f | sort > "$work/logs/ipk-list.txt"
{
  echo '=== built ipk files ==='
  while read -r ipk; do
    printf '%10d  %s\n' "$(stat -c %s "$ipk")" "$ipk"
  done < "$work/logs/ipk-list.txt"
} | tee "$out/ipk-sizes.txt"
while read -r ipk; do
  cp "$ipk" "$out/ipk/$(basename "$ipk")"
done < "$work/logs/ipk-list.txt"
{
  echo '=== control metadata of the relevant packages ==='
  while read -r ipk; do
    name=$(basename "$ipk")
    case "$name" in
      *xkcptun*|*libevent2*|*luci-compat*|*luci-lib-ipkg*) ;;
      *) continue ;;
    esac
    echo "--- $name ($(stat -c %s "$ipk") bytes)"
    tar -xzOf "$ipk" control.tar.gz 2>/dev/null | tar -xzO ./control 2>/dev/null || true
    echo
  done < "$work/logs/ipk-list.txt"
} > "$out/ipk-control.txt"
grep -q "xkcptun" "$out/ipk-control.txt" || { printf 'xkcptun package metadata missing\n' >&2; exit 1; }
{
  echo '=== relevant packages selected in .config ==='
  grep -E '^CONFIG_PACKAGE_(libevent2|xkcptun|luci-compat|luci-lib-ipkg|luci-app-xkcptun|luci-base|lua5\.1|liblua)=' .config || true
} > "$out/selection.txt"
printf 'Extra packages compiled and collected\n' >> "$out/environment.txt"
