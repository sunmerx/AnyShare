#!/usr/bin/env python3
"""E-2 S0-① portal 功能探测:RemoteDesktop + InputCapture 会话。

Ubuntu 24.04 + GNOME 46 Wayland 实测脚本(SSH 亦可运行)。
所有 Request 型调用均"订阅先行"以规避 Response 竞态(xdg-desktop-portal 文档要求)。
RemoteDesktop 的 Start 会触发系统授权弹窗,请在桌面上点「允许」。
环境变量 SKIP_RD=1 可跳过 RemoteDesktop 段。
"""

import os
import secrets
import time
import traceback

os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{os.getuid()}/bus")

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()

PORTAL_DEST = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
props = dbus.Interface(bus.get_object(PORTAL_DEST, PORTAL_PATH), "org.freedesktop.DBus.Properties")


def call(iface, method, signature, args, path=PORTAL_PATH, timeout=30):
    return bus.call_blocking(PORTAL_DEST, path, iface, method, signature, args, timeout=timeout)


def get_version(iface):
    try:
        return int(props.Get(iface, "version"))
    except Exception as e:
        return f"ERR: {e}"


def notify(title, body):
    try:
        notif = dbus.Interface(
            bus.get_object("org.freedesktop.Notifications", "/org/freedesktop/Notifications"),
            "org.freedesktop.Notifications",
        )
        notif.Notify("AnyShare-E2-Spike", 0, "", title, body, [], {}, 8)
        print(f"  [桌面通知已发送] {title}: {body}")
    except Exception as e:
        print(f"  [桌面通知失败] {e}")


def as_str(value):
    try:
        if isinstance(value, dbus.ByteArray):
            return bytes(value).decode("utf-8", "replace")
        return str(value)
    except Exception:
        return repr(value)


def describe(state):
    if state["timed_out"]:
        return "TIMEOUT (无响应/未点击)"
    code = state["response"]
    names = {0: "OK", 1: "用户取消", 2: "其他错误"}
    desc = names.get(code, f"code={code}")
    extra = {k: as_str(v) for k, v in state["results"].items()}
    return f"response={code} ({desc}) results={extra}"


def request_path_for(token):
    sender = bus.get_unique_name()[1:].replace(".", "_")
    return f"{PORTAL_PATH}/request/{sender}/{token}"


def portal_request(iface, method, signature, base_args, options=None, timeout=180):
    """订阅先行 + handle_token + 等待 Response。options 必须是方法的最后一个参数。"""
    token = "ashs" + secrets.token_hex(4)
    path = request_path_for(token)
    merged = dict(options or {})
    merged["handle_token"] = token

    loop = GLib.MainLoop()
    state = {"response": -1, "results": {}, "timed_out": True}

    def on_response(response, results):
        state["response"] = int(response)
        state["results"] = {str(k): v for k, v in results.items()}
        state["timed_out"] = False
        loop.quit()

    match = bus.add_signal_receiver(
        on_response,
        signal_name="Response",
        dbus_interface="org.freedesktop.portal.Request",
        path=path,
    )
    GLib.timeout_add_seconds(timeout, loop.quit)

    req = call(iface, method, signature, tuple(base_args) + (merged,))
    actual = str(req) if req is not None else path
    if actual != path:
        match.remove()
        match = bus.add_signal_receiver(
            on_response,
            signal_name="Response",
            dbus_interface="org.freedesktop.portal.Request",
            path=actual,
        )

    loop.run()
    try:
        match.remove()
    except Exception:
        pass
    return state


print("== 1. 接口版本 ==")
for iface in [
    "org.freedesktop.portal.RemoteDesktop",
    "org.freedesktop.portal.InputCapture",
    "org.freedesktop.portal.ScreenCast",
]:
    print(f"  {iface.split('.')[-1]}: version={get_version(iface)}")

SKIP_RD = os.environ.get("SKIP_RD") == "1"

if not SKIP_RD:
    print()
    print("== 2. RemoteDesktop 会话(键盘+鼠标注入路径) ==")
    rd_version = get_version("org.freedesktop.portal.RemoteDesktop")
    rd_iface = "org.freedesktop.portal.RemoteDesktop"
    try:
        state = portal_request(
            rd_iface, "CreateSession", "a{sv}", (),
            {"session_handle_token": "ashsess" + secrets.token_hex(4)},
        )
        print(f"  CreateSession -> {describe(state)}")
        if state["response"] == 0 and "session_handle" in state["results"]:
            rd_session = as_str(state["results"]["session_handle"])

            state = portal_request(
                rd_iface, "SelectDevices", "oa{sv}",
                (dbus.ObjectPath(rd_session),),
                {"types": dbus.UInt32(1 | 2)},
            )
            print(f"  SelectDevices(keyboard+pointer) -> {describe(state)}")

            notify("AnyShare E-2 测试", "10 秒后弹出「远程交互」授权框,请点击「允许」")
            print("  [RemoteDesktop] 10 秒后调用 Start,请在桌面上点「允许」")
            for i in range(10, 0, -1):
                print(f"  ... {i}")
                time.sleep(1)
            state = portal_request(
                rd_iface, "Start", "osa{sv}",
                (dbus.ObjectPath(rd_session), ""),
                {},
            )
            print(f"  Start -> {describe(state)}")

            if state["response"] == 0 and isinstance(rd_version, int) and rd_version >= 2:
                try:
                    fd = call(rd_iface, "ConnectToEIS", "oa{sv}", (
                        dbus.ObjectPath(rd_session),
                        {},
                    ))
                    fd_num = fd.take() if hasattr(fd, "take") else fd
                    print(f"  ConnectToEIS -> fd={fd_num} (libei 注入通道握手成功)")
                except Exception as e:
                    print(f"  ConnectToEIS -> ERR {e}")
    except Exception as e:
        print(f"  ERR: {e}")
        traceback.print_exc()
else:
    print()
    print("== 2. RemoteDesktop: 跳过(SKIP_RD=1) ==")

print()
print("== 3. InputCapture 会话(边缘屏障捕获路径) ==")
ic_iface = "org.freedesktop.portal.InputCapture"
notify("AnyShare E-2 测试", "即将请求「输入捕获」会话,若出现弹窗请点「允许」")
try:
    state = portal_request(
        ic_iface, "CreateSession", "sa{sv}", ("",),
        {
            "session_handle_token": "ashsess" + secrets.token_hex(4),
            "capabilities": dbus.UInt32(1 | 2),
        },
    )
    print(f"  CreateSession -> {describe(state)}")
    if state["response"] == 0 and "session_handle" in state["results"]:
        ic_session = as_str(state["results"]["session_handle"])

        state = portal_request(
            ic_iface, "GetZones", "oa{sv}",
            (dbus.ObjectPath(ic_session),),
            {},
        )
        print(f"  GetZones -> {describe(state)}")

        fd_ok = False
        try:
            fd = call(ic_iface, "ConnectToEIS", "oa{sv}", (
                dbus.ObjectPath(ic_session),
                {},
            ))
            fd_num = fd.take() if hasattr(fd, "take") else fd
            fd_ok = True
            print(f"  ConnectToEIS -> fd={fd_num} (libei 捕获通道握手成功)")
        except Exception as e:
            print(f"  ConnectToEIS -> ERR {e}")

        if state["response"] == 0 and "zones" in state["results"]:
            try:
                zones = state["results"]["zones"]
                z = zones[0]
                width, height = int(z[0]), int(z[1])
                if width < int(z[2]) or height < int(z[3]):
                    width, height = int(z[2]), int(z[3])
                print(f"  zone 尺寸推断: {width}x{height}")

                barriers = [
                    {"barrier_id": dbus.UInt32(1), "x1": 0, "y1": 0, "x2": 0, "y2": height},
                    {"barrier_id": dbus.UInt32(2), "x1": width, "y1": 0, "x2": width, "y2": height},
                    {"barrier_id": dbus.UInt32(3), "x1": 0, "y1": 0, "x2": width, "y2": 0},
                    {"barrier_id": dbus.UInt32(4), "x1": 0, "y1": height, "x2": width, "y2": height},
                ]
                token = "ashs" + secrets.token_hex(4)
                path = request_path_for(token)
                loop = GLib.MainLoop()
                bstate = {"response": -1, "results": {}, "timed_out": True}

                def on_bresp(response, results):
                    bstate["response"] = int(response)
                    bstate["results"] = {str(k): v for k, v in results.items()}
                    bstate["timed_out"] = False
                    loop.quit()

                match = bus.add_signal_receiver(
                    on_bresp,
                    signal_name="Response",
                    dbus_interface="org.freedesktop.portal.Request",
                    path=path,
                )
                req = call(ic_iface, "SetPointerBarriers", "oa{sv}aa{sv}u", (
                    dbus.ObjectPath(ic_session),
                    {"handle_token": token},
                    [dbus.Dictionary(b, signature="sv") for b in barriers],
                    dbus.UInt32(0),
                ))
                GLib.timeout_add_seconds(120, loop.quit)
                loop.run()
                try:
                    match.remove()
                except Exception:
                    pass
                print(f"  SetPointerBarriers(4 边) -> {describe(bstate)}")
            except Exception as e:
                print(f"  zone/barriers ERR: {e}")
                traceback.print_exc()

        try:
            call(ic_iface, "Enable", "oa{sv}", (
                dbus.ObjectPath(ic_session),
                {"capabilities": dbus.UInt32(1 | 2), "zone_set": dbus.UInt32(0)},
            ))
            print("  Enable -> 已调用(无返回值方法)")
        except Exception as e:
            print(f"  Enable ERR: {e}")
except Exception as e:
    print(f"  ERR: {e}")
    traceback.print_exc()

print()
print("== 探测结束 ==")
