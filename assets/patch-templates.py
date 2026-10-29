#!/usr/bin/env python3
"""Patch the luci-app-mtwifi sources for a current LuCI tree.

Usage: patch-templates.py <lede_root> <files_root>

1) The templates still reference PNG/GIF icons that this LuCI generation no
   longer ships (it ships SVG only), so the images render broken.
2) mtk_wifi_dev_cfg.htm calls print() while listing the raw profile. Under the
   ucode Lua compatibility bridge print() bypasses the template output buffer
   and the CGI returns no response at all (uhttpd reports 502). Buffer the
   lines and emit them through <%= %> instead.
3) mtkwifi.read_pipe() uses io.popen(), which the same bridge does not provide;
   it returns nil and every caller that does string.find() on the result dies
   with "bad argument #1 to 'find' (string expected, got nil)" as soon as an
   apcli interface exists. Fall back to luci.sys.exec() and always return a
   string.
"""
import pathlib
import re
import sys

lede = pathlib.Path(sys.argv[1])
files = pathlib.Path(sys.argv[2])

ICONS = {
    "loading.gif": "loading.svg",
    "wifi_big.png": "wifi.svg",
    "signal-75-100.png": "signal-075-100.svg",
    "signal-none.png": "signal-none.svg",
}

BUFFERED = (
    '<%= (function()\n'
    '            local t = {}\n'
    '            local fd = io.open(dev.profile)\n'
    '            if fd then\n'
    '                for line in fd:lines() do t[#t+1] = line end\n'
    '                fd:close()\n'
    '            end\n'
    '            return table.concat(t, "\\n")\n'
    '        end)() %>'
)

READ_PIPE_OLD = """function mtkwifi.read_pipe(pipe)
    local fp = io.popen(pipe)
    local txt =  fp:read("*a")
    fp:close()
    return txt
end"""

READ_PIPE_NEW = """function mtkwifi.read_pipe(pipe)
    local ok, fp = pcall(io.popen, pipe)
    if ok and fp then
        local txt = fp:read("*a")
        fp:close()
        if txt then return txt end
    end
    -- io.popen is unavailable inside the LuCI ucode compatibility bridge
    local ok2, sys = pcall(require, "luci.sys")
    if ok2 and sys and sys.exec then
        local res = sys.exec(pipe)
        if res then return res end
    end
    return ""
end"""

# ---- 1) templates -----------------------------------------------------------
tpl_src = lede / "package/lean/mt/luci-app-mtwifi/luasrc/view/admin_mtk"
tpl_dst = files / "usr/lib/lua/luci/view/admin_mtk"
tpl_dst.mkdir(parents=True, exist_ok=True)

patched_print = 0
for path in sorted(tpl_src.glob("*.htm")):
    text = path.read_text()
    for old, new in ICONS.items():
        text = text.replace(old, new)
    if path.name == "mtk_wifi_dev_cfg.htm":
        def repl(match):
            global patched_print
            if "print(line)" not in match.group(2):
                return match.group(0)
            patched_print += 1
            return match.group(1) + BUFFERED
        text = re.sub(r"(<textarea[^>]*>)<%(.*?)%>", repl, text, count=1, flags=re.S)
    (tpl_dst / path.name).write_text(text)

if patched_print != 1:
    sys.exit("expected exactly one print() block, patched %d" % patched_print)

# ---- 2) mtkwifi.lua ---------------------------------------------------------
lua_src = lede / "package/lean/mt/luci-app-mtwifi/root/usr/lib/lua/mtkwifi.lua"
lua_dst = files / "usr/lib/lua/mtkwifi.lua"
lua_dst.parent.mkdir(parents=True, exist_ok=True)
lua_text = lua_src.read_text()
if READ_PIPE_OLD not in lua_text:
    sys.exit("mtkwifi.read_pipe block not found in %s" % lua_src)
lua_dst.write_text(lua_text.replace(READ_PIPE_OLD, READ_PIPE_NEW))

print("patched: templates (icons + buffered listing) and mtkwifi.read_pipe")
