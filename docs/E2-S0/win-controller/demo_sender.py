#!/usr/bin/env python3
"""E-2 演示:Windows 鼠标状态 -> UDP 发送给 Ubuntu(由 demo_receiver.py 注入)。

用法: python demo_sender.py [--target 192.168.1.5:53319] [--seconds 0]
热键: F8 = 开始/暂停镜像(默认开启);Ctrl+C 退出并发送 bye。
注意:镜像包含左右键点击 —— 运行期间在 Windows 上的点击会在 Ubuntu 同位置也点一下!
"""

import argparse
import ctypes
import ctypes.wintypes
import json
import socket
import sys
import time

user32 = ctypes.windll.user32
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.GetSystemMetrics.restype = ctypes.c_int

VK_LBUTTON = 0x01
VK_RBUTTON = 0x02
VK_F8 = 0x77
BTN_LEFT = 0x110
BTN_RIGHT = 0x111


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="192.168.1.5:53319")
    ap.add_argument("--seconds", type=float, default=0.0, help="0 = 一直跑直到 Ctrl+C")
    args = ap.parse_args()

    host, port = args.target.split(":")
    port = int(port)

    screen_w = user32.GetSystemMetrics(0)
    screen_h = user32.GetSystemMetrics(1)
    print(f"[win] 屏幕 {screen_w}x{screen_h} -> {host}:{port}")
    print("[win] F8 暂停/恢复镜像;Ctrl+C 退出(退出时停止 Ubuntu 端模拟)")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    pt = ctypes.wintypes.POINT()

    streaming = True
    prev_pos = None
    prev_btn = {1: False, 2: False}
    prev_f8 = False

    print("[win] 3 秒后开始镜像(请先在 Ubuntu 上确认已点「允许」)")
    time.sleep(3)

    start = time.time()
    moves = clicks = 0
    try:
        while True:
            if args.seconds and time.time() - start > args.seconds:
                break

            f8 = bool(user32.GetAsyncKeyState(VK_F8) & 0x8000)
            if f8 and not prev_f8:
                streaming = not streaming
                print(f"[win] 镜像{'已恢复' if streaming else '已暂停'}(F8)")
            prev_f8 = f8

            if streaming:
                user32.GetCursorPos(ctypes.byref(pt))
                nx = pt.x / max(1, screen_w - 1)
                ny = pt.y / max(1, screen_h - 1)
                if prev_pos != (nx, ny):
                    sock.sendto(json.dumps({"t": "m", "x": nx, "y": ny}).encode(), (host, port))
                    prev_pos = (nx, ny)
                    moves += 1

                for vk, code in ((VK_LBUTTON, BTN_LEFT), (VK_RBUTTON, BTN_RIGHT)):
                    pressed = bool(user32.GetAsyncKeyState(vk) & 0x8000)
                    if pressed != prev_btn[vk]:
                        sock.sendto(json.dumps({"t": "b", "b": code, "p": pressed}).encode(), (host, port))
                        prev_btn[vk] = pressed
                        clicks += 1
            else:
                prev_pos = None

            time.sleep(1 / 60)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            sock.sendto(json.dumps({"t": "bye"}).encode(), (host, port))
        except Exception:
            pass
        print(f"[win] 结束:发送 {moves} 个移动,{clicks} 个按键事件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
