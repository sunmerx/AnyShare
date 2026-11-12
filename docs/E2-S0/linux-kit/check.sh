#!/bin/bash
# AnyShare E-2 S0-① 检查脚本:Ubuntu 22.04 + GNOME + Wayland 的屏幕/输入共享能力探测
# 用法:bash check.sh
# 说明:只读检查,不安装/不修改任何东西。把完整输出贴回给主会话即可。

echo "===== 1. 会话与桌面环境 ====="
if [ -z "$XDG_SESSION_TYPE" ]; then
  echo "(SSH 环境:XDG_SESSION_TYPE 未设置,用 loginctl 查询)"
  SESSION_ID=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USER" '$3==u {print $1}' | head -1)
  if [ -n "$SESSION_ID" ]; then
    loginctl show-session "$SESSION_ID" -p Type -p Desktop -p Active -p Remote 2>/dev/null
  else
    echo "(找不到图形会话)"
  fi
fi
echo "session type: $XDG_SESSION_TYPE"
echo "desktop:      $XDG_CURRENT_DESKTOP"
gnome-shell --version 2>/dev/null || echo "gnome-shell: not found"

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

echo ""
echo "===== 2. libei / portal 相关包 ====="
apt policy libei1 2>/dev/null | head -4
echo "---"
dpkg -l 2>/dev/null | grep -iE "libei|xdg-desktop-portal" | awk '{print $2, $3}'

echo ""
echo "===== 3. xdg-desktop-portal 能力(看 RemoteDesktop / InputCapture 是否存在) ====="
gdbus introspect --session --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop 2>/dev/null \
  | grep -iE "RemoteDesktop|InputCapture|Screencast" | sort -u
echo "(若无 RemoteDesktop/InputCapture 输出,即为不支持)"

echo ""
echo "===== 4. 屏幕捕获 portal(对照项) ====="
gdbus introspect --session --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop 2>/dev/null \
  | grep -iE "ScreenCast" | sort -u

echo ""
echo "===== 5. mutter 合成器信息 ====="
gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
    --method org.gnome.Shell.Eval "global.get_window_actors().length" 2>/dev/null \
  || echo "(eval 接口被禁用,跳过)"

echo ""
echo "===== 6. X11 兜底链路检查 ====="
which xdotool >/dev/null 2>&1 && echo "xdotool: 已安装" || echo "xdotool: 未安装(可选,验证 X11 会话时再装: sudo apt install xdotool)"
echo "x11 session 可选性: 注销后在登录界面点右下角齿轮,看是否有 'Ubuntu on X11'"

echo ""
echo "===== 7. Wayland 下 xdotool 行为对照(可选,仅当已装 xdotool)====="
if which xdotool >/dev/null 2>&1; then
  echo "尝试: xdotool getmouselocation"
  xdotool getmouselocation 2>&1 | head -2
  echo "(Wayland 原生会话下预期报错或仅对内嵌 XWayland 应用生效)"
fi

echo ""
echo "===== 完成 ====="
