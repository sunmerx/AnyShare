#!/usr/bin/env python3
"""E-2 演示:Windows 鼠标 -> Ubuntu 注入(RemoteDesktop portal + libei EIS)。

流程:portal 建立 RemoteDesktop 会话(需在桌面点「允许」)-> ConnectToEIS 取 fd ->
ctypes 调用 libei 作为 sender 接入 -> UDP(53319) 接收 Windows 端发来的归一化坐标/按键并入。

UDP 协议(JSON 行, 65536 内):{"t":"m","x":0..1,"y":0..1} / {"t":"b","b":272|273,"p":true|false} / {"t":"bye"}
安全:2.5s 无包自动 stop_emulating;Ctrl+C 退出。
"""

import ctypes
import json
import os
import secrets
import select
import socket
import sys
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
UDP_PORT = 53319
IDLE_STOP_SECONDS = 2.5

# ---------------- portal ----------------

def call(iface, method, signature, args, path=PORTAL_PATH, timeout=30):
    return bus.call_blocking(PORTAL_DEST, path, iface, method, signature, args, timeout=timeout)


def request_path_for(token):
    sender = bus.get_unique_name()[1:].replace(".", "_")
    return f"{PORTAL_PATH}/request/{sender}/{token}"


def portal_request(iface, method, signature, base_args, options=None, timeout=180):
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


def notify(title, body):
    try:
        notif = dbus.Interface(
            bus.get_object("org.freedesktop.Notifications", "/org/freedesktop/Notifications"),
            "org.freedesktop.Notifications",
        )
        notif.Notify("AnyShare-E2-Demo", 0, "", title, body, [], {}, 8)
    except Exception:
        pass


def get_remote_desktop_fd():
    rd_iface = "org.freedesktop.portal.RemoteDesktop"
    state = portal_request(rd_iface, "CreateSession", "a{sv}", (), {"session_handle_token": "ashsess" + secrets.token_hex(4)})
    if state["response"] != 0:
        print(f"[portal] CreateSession 失败: {state}")
        return None
    session = str(state["results"]["session_handle"])

    state = portal_request(rd_iface, "SelectDevices", "oa{sv}", (dbus.ObjectPath(session),), {"types": dbus.UInt32(2)})
    if state["response"] != 0:
        print(f"[portal] SelectDevices 失败: {state}")
        return None

    notify("AnyShare E-2 演示", "10 秒后弹出「远程交互」授权框,请点击「允许」")
    print("[portal] 10 秒后弹出授权框,请在 Ubuntu 桌面点击「允许」")
    for i in range(10, 0, -1):
        print(f"  ... {i}")
        time.sleep(1)

    state = portal_request(rd_iface, "Start", "osa{sv}", (dbus.ObjectPath(session), ""), {})
    print(f"[portal] Start -> response={state['response']}{'' if state['response'] == 0 else ' ' + str(state)}")
    if state["response"] != 0:
        return None

    fd = call(rd_iface, "ConnectToEIS", "oa{sv}", (dbus.ObjectPath(session), {}))
    fd_num = fd.take() if hasattr(fd, "take") else int(fd)
    print(f"[portal] ConnectToEIS -> fd={fd_num}")
    return fd_num


# ---------------- libei ----------------

EI_EVENT_CONNECT = 1
EI_EVENT_DEVICE_ADDED = 5
EI_DEVICE_CAP_POINTER_ABSOLUTE = 2

BTN_LEFT = 0x110
BTN_RIGHT = 0x111


class Libei:
    def __init__(self, fd):
        self.lib = ctypes.CDLL("libei.so.1")
        lib = self.lib
        lib.ei_new_sender.restype = ctypes.c_void_p
        lib.ei_new_sender.argtypes = [ctypes.c_char_p]
        lib.ei_setup_backend_fd.restype = ctypes.c_int
        lib.ei_setup_backend_fd.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.ei_dispatch.restype = ctypes.c_int
        lib.ei_dispatch.argtypes = [ctypes.c_void_p]
        lib.ei_get_event.restype = ctypes.c_void_p
        lib.ei_get_event.argtypes = [ctypes.c_void_p]
        lib.ei_event_get_type.restype = ctypes.c_uint32
        lib.ei_event_get_type.argtypes = [ctypes.c_void_p]
        lib.ei_event_unref.argtypes = [ctypes.c_void_p]
        lib.ei_event_get_device.restype = ctypes.c_void_p
        lib.ei_event_get_device.argtypes = [ctypes.c_void_p]
        lib.ei_device_has_capability.restype = ctypes.c_bool
        lib.ei_device_has_capability.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        lib.ei_device_get_width.restype = ctypes.c_int
        lib.ei_device_get_width.argtypes = [ctypes.c_void_p]
        lib.ei_device_get_height.restype = ctypes.c_int
        lib.ei_device_get_height.argtypes = [ctypes.c_void_p]
        lib.ei_device_start_emulating.restype = ctypes.c_int
        lib.ei_device_start_emulating.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        lib.ei_device_stop_emulating.argtypes = [ctypes.c_void_p]
        lib.ei_device_pointer_motion_absolute.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_double]
        lib.ei_device_button_button.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_bool]
        lib.ei_device_frame.argtypes = [ctypes.c_void_p, ctypes.c_uint64]

        self.ei = lib.ei_new_sender(b"anyshare-demo")
        rc = lib.ei_setup_backend_fd(self.ei, fd)
        print(f"[libei] setup_backend_fd rc={rc}")
        self.device = None
        self.width = 2048
        self.height = 1280
        self.emulating = False

    def pump_once(self):
        self.lib.ei_dispatch(self.ei)

    def wait_for_pointer(self, timeout=15.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pump_once()
            while True:
                ev = self.lib.ei_get_event(self.ei)
                if not ev:
                    break
                etype = self.lib.ei_event_get_type(ev)
                if etype == EI_EVENT_CONNECT:
                    print("[libei] EIS 连接建立")
                elif etype == EI_EVENT_DEVICE_ADDED:
                    dev = self.lib.ei_event_get_device(ev)
                    caps = []
                    if self.lib.ei_device_has_capability(dev, EI_DEVICE_CAP_POINTER_ABSOLUTE):
                        caps.append("pointer-absolute")
                        self.device = dev
                    elif self.lib.ei_device_has_capability(dev, 1):
                        caps.append("pointer-relative")
                    if self.lib.ei_device_has_capability(dev, 4):
                        caps.append("keyboard")
                    if self.lib.ei_device_has_capability(dev, 16):
                        caps.append("scroll")
                    print(f"[libei] 设备加入: {', '.join(caps) or '无已知能力'}")
                    if self.device is not None:
                        w = self.lib.ei_device_get_width(dev)
                        h = self.lib.ei_device_get_height(dev)
                        if w > 0 and h > 0:
                            self.width, self.height = w, h
                        print(f"[libei] 绝对指针区域: {self.width}x{self.height}")
                        return True
                self.lib.ei_event_unref(ev)
            time.sleep(0.02)
        return False

    def start(self):
        if not self.emulating and self.device is not None:
            rc = self.lib.ei_device_start_emulating(self.device, 1)
            self.emulating = True
            self.frame()
            print(f"[libei] start_emulating rc={rc}")

    def stop(self):
        if self.emulating and self.device is not None:
            self.frame()
            self.lib.ei_device_stop_emulating(self.device)
            self.emulating = False
            self.frame()
            print("[libei] 已停止模拟(空闲保护)")

    def frame(self):
        self.lib.ei_device_frame(self.device, int(time.monotonic() * 1_000_000))

    def move_abs(self, fx, fy):
        self.lib.ei_device_pointer_motion_absolute(
            self.device,
            max(0.0, min(1.0, fx)) * self.width,
            max(0.0, min(1.0, fy)) * self.height,
        )
        self.frame()

    def button(self, code, press):
        self.lib.ei_device_button_button(self.device, code, press)
        self.frame()


# ---------------- main ----------------

def main():
    fd = get_remote_desktop_fd()
    if fd is None:
        print("portal 未成功,退出")
        return 1

    ei = Libei(fd)
    print("[libei] 等待 EIS 设备...")
    if not ei.wait_for_pointer():
        print("[libei] 等待设备超时,退出")
        return 1

    ei.start()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", UDP_PORT))
    print(f"[udp] 监听 0.0.0.0:{UDP_PORT},等待 Windows 端数据(2.5s 无包自动停手)")
    print(">>> 现在可以在 Windows 上运行发送端;Ctrl+C 结束 <<<")

    last_packet = 0.0
    injected = 0
    try:
        while True:
            ready, _, _ = select.select([sock], [], [], 0.05)
            now = time.time()
            if ready:
                data, addr = sock.recvfrom(65536)
                try:
                    msg = json.loads(data.decode("utf-8"))
                except Exception:
                    continue
                t = msg.get("t")
                if t == "m":
                    ei.start()
                    ei.move_abs(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))
                    last_packet = now
                    injected += 1
                elif t == "b":
                    ei.start()
                    ei.button(int(msg.get("b", BTN_LEFT)), bool(msg.get("p", True)))
                    last_packet = now
                    injected += 1
                elif t == "bye":
                    print("[udp] 收到 bye,停止模拟")
                    ei.stop()
                    last_packet = 0.0
                if injected and injected % 120 == 0:
                    print(f"[udp] 累计注入 {injected} 个事件(来自 {addr[0]})")
            if ei.emulating and last_packet and now - last_packet > IDLE_STOP_SECONDS:
                ei.stop()
    except KeyboardInterrupt:
        print("\n[main] Ctrl+C,退出")
    finally:
        try:
            ei.stop()
        except Exception:
            pass
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
