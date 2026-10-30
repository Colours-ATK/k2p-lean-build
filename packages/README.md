# 本地包说明（不进镜像种子,仅供可行性验证与按需安装）

这两个包不是 Lean/OpenWrt 自带的,是本次为「在 K2P 上装 xkcptun」而**搬进本仓库的第三方包**。它们由 `ci/build-extra.sh` 单独编译,产物以 `.ipk` 形式发布,不改动已验证的主固件流水线 `ci/build.sh`。

| 目录 | 来源 | 许可 | 说明 |
|---|---|---|---|
| `xkcptun/` | `openwrt/packages` 的 `net/xkcptun`(上游 v1.09.561,源码 `liudf0716/xkcptun`) | GPL-3.0-or-later | C 实现的 KCP 隧道,`DEPENDS:=+libevent2`;`libevent2` **在 Lean 核心树 `package/libs/libevent2` 里**,无需额外搬入 |
| `luci-app-xkcptun/` | `shangjiyu/openwrt-extra` 的 `packages/luci-app-xkcptun` | GPL-3.0 | 2017 年的老 LuCI 应用(**Lua CBI**,需要 `luci-compat` 提供旧 dispatcher,`luci.model.ipkg` 现在在独立包 `luci-lib-ipkg` 里) |

## 已知不匹配(必须在装界面前解决)

2026 版 `xkcptun` 的 UCI schema 与 2017 年的 LuCI 应用**不是同一套**:

- 新包 init 脚本读的选项:`enabled` / `local_interface` / `local_port` / `remote_addr` / `remote_port` / `target_addr` / `target_port` / `proto` / `proxy_type`,段类型为 `config global 'client'`、`config global 'server'`、`config client 'client1'`、`config server 'server1'`。
- 老 LuCI CBI 用的选项:`enable` / `localinterface` / `localport` / `remoteaddr` / `remoteport`,段类型只有 `client`。

也就是说:**老界面能打开,但保存的字段名与新 init 脚本不匹配,配置不会生效**。可行修法二选一(待设备实测后定):

1. 改写 `luasrc/model/cbi/xkcptun.lua`,对齐新 schema(段与选项名),保留 Lua CBI 路线;
2. 改用 LuCI JS 页面 + rpcd 读写 UCI(不依赖 `luci-compat`,与本镜像其余界面一致)。

## 其他已知点

- `xkcptun` 的 `redir`/`transparent` 代理模式需要 TPROXY/REDIRECT 规则;本机用的是 **firewall4/nftables**,老应用里基于 iptables 的规则不能直接用,要在 fw4 规则里补。
- 设备镜像内**没有 opkg 源列表**(`/usr/lib/opkg/lists` 为空),因此只能把 `.ipk` 拷到设备后 `opkg install /tmp/xxx.ipk`,不能在线 `opkg update/install`。
- 镜像当前 11,535,323 B,分区上限 16,121,856 B(15744k),**余量约 4.4 MB**;这几个包体积都在几百 KB 量级,放得下,但最终若要固化进镜像,仍需在种子与镜像断言里复核。
