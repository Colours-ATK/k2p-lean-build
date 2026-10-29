#!/usr/bin/env python3
"""Patch the luci-app-mtwifi templates for a current LuCI tree.

1) The templates still reference PNG/GIF icons that this LuCI generation no
   longer ships (it ships SVG only), so the images render broken.
2) mtk_wifi_dev_cfg.htm calls print() while listing the raw profile. Under the
   ucode Lua compatibility bridge print() bypasses the template output buffer
   and the CGI returns no response at all (uhttpd reports 502). Buffer the
   lines and emit them through <%= %> instead.
"""
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])

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

dst.mkdir(parents=True, exist_ok=True)
patched_print = 0
for path in sorted(src.glob("*.htm")):
    text = path.read_text()
    for old, new in ICONS.items():
        text = text.replace(old, new)
    if path.name == "mtk_wifi_dev_cfg.htm":
        def repl(match):
            global patched_print
            body = match.group(2)
            if "print(line)" not in body:
                return match.group(0)
            patched_print += 1
            return match.group(1) + BUFFERED
        text = re.sub(r"(<textarea[^>]*>)<%(.*?)%>", repl, text, count=1, flags=re.S)
    (dst / path.name).write_text(text)

if patched_print != 1:
    sys.exit("expected exactly one print() block in mtk_wifi_dev_cfg.htm, patched %d" % patched_print)
print("templates patched: icons + buffered profile listing")
