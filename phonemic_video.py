# -*- coding: utf-8 -*-
"""PhoneMic 视频接收 + 实时预览

手机端（PhoneMic App）在 17174 端口推 H.264 码流：
  "PMV1" + u16 版本 + u32 宽 + u32 高 + u16 帧率 + u16 保留      （18 字节头）
  之后每帧：  u32 长度 + u8 是否关键帧 + Annex-B 数据

本程序两条通道，优先 USB：
  - USB : pymobiledevice3 usbmux forward 127.0.0.1:17174 -> 手机 17174
  - WiFi: 直连手机 IP:17174（IP 复用 phonemic_wifi.txt）
用 PyAV 解码、OpenCV 显示。Esc 或关窗口退出。
"""
import argparse
import ctypes
import json
import os
import socket
import struct
import subprocess
import sys
import time

import av
import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WIFI_CFG = os.path.join(HERE, "phonemic_wifi.txt")
VIEW_CFG = os.path.join(HERE, "phonemic_view.json")
PYMD = r"C:\Users\Administrator\Downloads\pmd3venv\Scripts\pymobiledevice3.exe"
UDID = "00008110-001C1882223B801E"
PORT = 17174
WIN = "PhoneMic 手机画面"


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("对端关闭连接")
        buf += chunk
    return buf


def spawn_forward():
    return subprocess.Popen(
        [PYMD, "usbmux", "forward", str(PORT), str(PORT), "--udid", UDID],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def wifi_ip():
    try:
        with open(WIFI_CFG, "r", encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


# ---------------- 无边框窗口（保留拖动 + 边缘缩放） ----------------
GWL_STYLE = -16
GWL_WNDPROC = -4
WS_POPUP = 0x80000000
WS_VISIBLE = 0x10000000
WS_THICKFRAME = 0x00040000
WS_MINIMIZEBOX = 0x00020000
WS_MAXIMIZEBOX = 0x00010000
SWP_NOSIZE, SWP_NOMOVE, SWP_NOZORDER, SWP_FRAMECHANGED = 0x1, 0x2, 0x4, 0x20

WM_NCCALCSIZE = 0x0083
WM_NCHITTEST = 0x0084
WM_NCMOUSEFIRST = 0x00A0
WM_NCMOUSELAST = 0x00A9
HTCAPTION = 2
HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT = 10, 11, 12, 13, 14
HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT = 15, 16, 17
RESIZE_BORDER = 8  # 四周可抓取缩放的像素宽

user32 = ctypes.windll.user32
_PTR = ctypes.c_ssize_t
WNDPROC_TYPE = ctypes.WINFUNCTYPE(_PTR, ctypes.c_void_p, ctypes.c_uint,
                                  _PTR, _PTR)
ENUMPROC_TYPE = ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p,
                                   ctypes.c_void_p)


class _RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


class _POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def make_borderless(title=None):
    """去掉标题栏，但窗口仍可拖动、四边可拉伸。失败则退回普通窗口。

    定位窗口不靠标题（OpenCV 对中文标题会存成乱码），
    而是找「本进程 + Main HighGUI class」的窗口。
    """
    try:
        user32.FindWindowW.restype = ctypes.c_void_p
        user32.EnumWindows.argtypes = [ENUMPROC_TYPE, ctypes.c_void_p]
        user32.EnumWindows.restype = ctypes.c_int
        hwnd = None
        target_pid = os.getpid()

        @ENUMPROC_TYPE
        def _enum(h, _lp):
            nonlocal hwnd
            cls = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(h, cls, 256)
            if cls.value == "Main HighGUI class":
                pid = ctypes.c_ulong()
                user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
                if pid.value == target_pid and user32.IsWindowVisible(h):
                    hwnd = h
                    return 0
            return 1

        user32.EnumWindows(_enum, 0)
        if not hwnd:
            return False
        if ctypes.sizeof(_PTR) == 8:
            get_style, set_style, set_proc = (user32.GetWindowLongPtrW,
                                              user32.SetWindowLongPtrW,
                                              user32.SetWindowLongPtrW)
        else:
            get_style, set_style, set_proc = (user32.GetWindowLongW,
                                              user32.SetWindowLongW,
                                              user32.SetWindowLongW)
        for fn in (get_style, set_style, set_proc, user32.CallWindowProcW):
            fn.restype = ctypes.c_ssize_t
        user32.CallWindowProcW.argtypes = [ctypes.c_ssize_t, ctypes.c_void_p,
                                           ctypes.c_uint, _PTR, _PTR]
        user32.DefWindowProcW.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                          _PTR, _PTR]
        user32.DefWindowProcW.restype = ctypes.c_ssize_t
        # 这些函数的原型必须钉死：类型不匹配时 ctypes 会吞掉回调里的异常，
        # 命中测试统一返回 0（HTNOWHERE），表现就是窗口拖不动、拉不动
        user32.GetClientRect.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        user32.GetClientRect.restype = ctypes.c_int
        user32.ScreenToClient.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        user32.ScreenToClient.restype = ctypes.c_int
        call_proc = user32.CallWindowProcW
        default_proc = user32.DefWindowProcW

        # 回调对象必须长期持有，否则被 GC 回收后窗口过程变野指针
        state = {"old": 0}

        def proc(hwnd, msg, wp, lp):
            if msg == WM_NCCALCSIZE and wp:
                return 0  # 吃掉整个非客户区：标题栏、白边、按钮全部消失
            if msg == WM_NCHITTEST:
                x = ctypes.c_short(lp & 0xFFFF).value
                y = ctypes.c_short((lp >> 16) & 0xFFFF).value
                pt = _POINT(x, y)
                user32.ScreenToClient(hwnd, ctypes.byref(pt))
                rc = _RECT()
                user32.GetClientRect(hwnd, ctypes.byref(rc))
                b, w, h = RESIZE_BORDER, rc.right, rc.bottom
                if pt.y < b:
                    if pt.x < b:
                        return HTTOPLEFT
                    if pt.x > w - b:
                        return HTTOPRIGHT
                    return HTTOP
                if pt.y > h - b:
                    if pt.x < b:
                        return HTBOTTOMLEFT
                    if pt.x > w - b:
                        return HTBOTTOMRIGHT
                    return HTBOTTOM
                if pt.x < b:
                    return HTLEFT
                if pt.x > w - b:
                    return HTRIGHT
                # 中间整块当标题栏：按住随便哪儿都能拖动窗口
                return HTCAPTION
            if WM_NCMOUSEFIRST <= msg <= WM_NCMOUSELAST:
                # 拖动/缩放的按键消息必须交给系统默认处理，
                # 转给 HighGUI 的窗口过程会被它吞掉，导致拖不动、拉不动
                return default_proc(hwnd, msg, wp, lp)
            return call_proc(state["old"], hwnd, msg, wp, lp)

        state["keepalive"] = WNDPROC_TYPE(proc)
        state["old"] = set_proc(hwnd, GWL_WNDPROC, state["keepalive"])
        if not state["old"]:
            return False

        style = get_style(hwnd, GWL_STYLE)
        style = (style & ~0x00C00000) | WS_POPUP | WS_THICKFRAME \
            | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_VISIBLE
        set_style(hwnd, GWL_STYLE, style)
        user32.SetWindowPos(hwnd, 0, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
                            | SWP_FRAMECHANGED)
        return True
    except Exception:
        import traceback
        traceback.print_exc()
        return False


class Preview:
    """解码 + 显示，负责丢帧保实时"""

    def __init__(self, fit="cover", flip=None):
        self.fit = fit
        self.flip = bool(load_view_cfg().get("flip", False)) if flip is None else flip
        self.codec = av.CodecContext.create("h264", "r")
        self.codec.thread_type = "AUTO"
        self.frames = 0
        self.bytes = 0
        self.last = time.time()
        self.fps = 0.0
        self.kbps = 0.0
        self.size = None
        self.aspect = 0.0
        self.window_ready = False
        self.frameless = False
        self.frameless_tried = False
        self.show_stats = False
        self.quit = False
        self.wait_window = False
        self.wait_text = "Connecting to phone..."

    def show_waiting(self, hint=None):
        """还没收到画面时先开个窗，让人看得出程序在跑、卡在哪一步。

        和视频复用同一个窗口名，免得无边框那段按类名找句柄时找错窗。
        """
        if hint is not None:
            self.wait_text = hint
        img = np.full((540, 960, 3), 26, np.uint8)
        cv2.putText(img, "PhoneMic", (56, 236), cv2.FONT_HERSHEY_SIMPLEX,
                    1.5, (235, 235, 235), 3, cv2.LINE_AA)
        cv2.putText(img, self.wait_text, (56, 300), cv2.FONT_HERSHEY_SIMPLEX,
                    0.85, (140, 200, 255), 2, cv2.LINE_AA)
        cv2.putText(img, "Esc to quit", (56, 470), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (130, 130, 130), 1, cv2.LINE_AA)
        if not self.wait_window:
            cv2.namedWindow(WIN, cv2.WINDOW_NORMAL)
            cv2.resizeWindow(WIN, 960, 540)
            self.wait_window = True
        cv2.imshow(WIN, img)
        if not self.frameless_tried:
            self.frameless_tried = True
            self.frameless = make_borderless(WIN)
        if (cv2.waitKey(1) & 0xFF) == 27:
            self.quit = True

    def feed(self, payload, is_key):
        self.bytes += len(payload)
        for packet in self.codec.parse(payload):
            for frame in self.codec.decode(packet):
                img = frame.to_ndarray(format="bgr24")
                if not img.flags["C_CONTIGUOUS"]:
                    img = np.ascontiguousarray(img)
                h, w = img.shape[:2]
                if self.flip:
                    img = cv2.flip(img, 1)  # 水平镜像，按 M 切换
                aspect = w / float(h)
                if not self.window_ready:
                    cv2.namedWindow(WIN, cv2.WINDOW_NORMAL)
                    cv2.resizeWindow(WIN, *self.initial_size(w, h))
                    self.window_ready = True
                    self.aspect = aspect
                elif abs(aspect - self.aspect) > 0.02:
                    # 手机转了方向：把窗口调成匹配的新形状（画面会跟着重新铺满）
                    self.aspect = aspect
                    cv2.resizeWindow(WIN, *self.initial_size(w, h))
                self.size = (w, h)
                out = self.present(img)
                if self.show_stats:
                    text = "%dx%d  %.0ffps  %.0fkbps" % (w, h, self.fps, self.kbps)
                    cv2.putText(out, text, (13, 30), cv2.FONT_HERSHEY_SIMPLEX,
                                0.7, (0, 0, 0), 3, cv2.LINE_AA)
                    cv2.putText(out, text, (13, 30), cv2.FONT_HERSHEY_SIMPLEX,
                                0.7, (255, 255, 255), 1, cv2.LINE_AA)
                cv2.imshow(WIN, out)
                if not self.frameless_tried:
                    # 窗口要真正显示出来才能拿到句柄，所以放在第一次 imshow 之后
                    self.frameless_tried = True
                    self.frameless = make_borderless(WIN)
                    if not self.frameless:
                        log("无边框设置失败，保留普通标题栏")
                key = cv2.waitKey(1) & 0xFF
                if key == 27:
                    self.quit = True
                elif key in (ord("h"), ord("H")):
                    self.show_stats = not self.show_stats
                elif key in (ord("m"), ord("M")):
                    self.flip = not self.flip
                    cfg = load_view_cfg()
                    cfg["flip"] = self.flip
                    save_view_cfg(cfg)
                    log("画面镜像：%s（已记住）" % ("开" if self.flip else "关"))
                try:
                    if cv2.getWindowProperty(WIN, cv2.WND_PROP_VISIBLE) < 1:
                        self.quit = True
                except cv2.error:
                    self.quit = True
                self.frames += 1
                self.tick()

    @staticmethod
    def initial_size(w, h):
        """开窗/手机转向时给个不超出屏幕的初始尺寸，保持视频比例"""
        max_w, max_h = 1280, 860
        try:
            u = ctypes.windll.user32
            sw, sh = u.GetSystemMetrics(0), u.GetSystemMetrics(1)
            if sw > 320 and sh > 240:
                max_w = min(max_w, int(sw * 0.78))
                max_h = min(max_h, sh - 150)
        except Exception:
            pass
        s = min(max_w / float(w), max_h / float(h), 1.0)
        return max(1, int(round(w * s))), max(1, int(round(h * s)))

    def present(self, img):
        """把画面铺进窗口，比例永远不变、不留黑边。

        默认 cover：等比放大到刚好盖住窗口，多出来的部分居中裁掉。
        --fit contain 时退回老行为（等比缩到窗口内 + 补黑边）。
        """
        h, w = img.shape[:2]
        try:
            _, _, ww, wh = cv2.getWindowImageRect(WIN)
        except cv2.error:
            return img
        if ww <= 0 or wh <= 0:
            return img
        if ww == w and wh == h:
            return img

        if self.fit == "contain":
            s = min(ww / float(w), wh / float(h))
        else:
            s = max(ww / float(w), wh / float(h))

        # 用 ceil 保证缩放后两个方向都不小于窗口，裁切才不会露边
        nw = max(1, int(np.ceil(w * s - 1e-6)))
        nh = max(1, int(np.ceil(h * s - 1e-6)))
        interp = cv2.INTER_AREA if s < 1.0 else cv2.INTER_LINEAR
        resized = cv2.resize(img, (nw, nh), interpolation=interp)
        if (nw, nh) == (ww, wh):
            return resized

        x0 = max(0, (nw - ww) // 2)
        y0 = max(0, (nh - wh) // 2)
        out = resized[y0:y0 + wh, x0:x0 + ww]
        if out.shape[0] != wh or out.shape[1] != ww:
            # 浮点取整的极端兜底，理论上走不到
            out = cv2.resize(out, (ww, wh), interpolation=interp)
        return np.ascontiguousarray(out)

    def tick(self):
        now = time.time()
        dt = now - self.last
        if dt < 2.0:
            return
        self.fps = self.frames / dt
        self.kbps = self.bytes * 8.0 / 1000.0 / dt
        self.frames = 0
        self.bytes = 0
        self.last = now
        # 标题栏没了，统计信息改打在命令行
        w, h = self.size or (0, 0)
        log("%dx%d  %.0ffps  %.0fkbps" % (w, h, self.fps, self.kbps))


def stream_once(host, tag, preview):
    conn = socket.create_connection((host, PORT), timeout=3)
    conn.settimeout(8.0)
    log("已连接 %s %s:%d" % (tag, host, PORT))
    try:
        head = recv_exact(conn, 18)
        if head[:4] != b"PMV1":
            raise ValueError("头部不对: %r" % head[:8])
        ver, w, h, fps, _ = struct.unpack("<HIIHH", head[4:18])
        log("[%s] 视频参数: %dx%d @%dfps (v%d)" % (tag, w, h, fps, ver))
        preview.codec = av.CodecContext.create("h264", "r")
        preview.size = (w, h)
        while not preview.quit:
            try:
                packet_head = recv_exact(conn, 5)
            except socket.timeout:
                log("[%s] 连上了但一直收不到画面：手机上的相机可能被系统暂停了，"
                    "在 App 里点一次「停止推流」再「开始推流」" % tag)
                raise
            size = struct.unpack("<I", packet_head[:4])[0]
            if size == 0 or size > 4_000_000:
                raise ValueError("帧长度异常: %d" % size)
            is_key = packet_head[4] == 1
            payload = recv_exact(conn, size)
            preview.feed(payload, is_key)
    finally:
        try:
            conn.close()
        except OSError:
            pass


def save_wifi_ip(ip):
    try:
        with open(WIFI_CFG, "w", encoding="utf-8") as f:
            f.write(ip + "\n")
    except OSError:
        pass


def load_view_cfg():
    try:
        with open(VIEW_CFG, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_view_cfg(cfg):
    try:
        with open(VIEW_CFG, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
    except OSError:
        pass


def local_ipv4():
    """本机默认出口 IP，用来推断所在 /24 网段"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("223.5.5.5", 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


BEACON_PORT = 17175


def listen_beacon(timeout=1.5):
    """手机推流时每 2 秒广播一次「PHONEMIC-HERE <ip>」。

    比扫网段快得多，IP 被 DHCP 换掉也不影响。
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", BEACON_PORT))
        s.settimeout(max(0.2, timeout))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, addr = s.recvfrom(256)
            except socket.timeout:
                break
            text = data.decode("ascii", "ignore").strip()
            if not text.startswith("PHONEMIC-HERE"):
                continue
            parts = text.split()
            if len(parts) >= 2 and parts[1].count(".") == 3:
                return parts[1]
            return addr[0]
    except OSError:
        return None
    finally:
        s.close()
    return None


def arp_hosts():
    """系统邻居表里当前在线的主机（不靠端口探测，IP 变了也认得出）"""
    hosts = []
    try:
        r = subprocess.run(["arp", "-a"], capture_output=True, timeout=6,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        text = r.stdout.decode("gbk", "ignore")
    except Exception:
        return hosts
    import ipaddress
    import re
    seen = set()
    for m in re.finditer(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})",
                         text):
        ip, mac = m.group(1), m.group(2).lower()
        if mac.startswith("00-00-00") or mac.startswith("ff-ff-ff"):
            continue  # 未解析 / 广播
        try:
            a = ipaddress.IPv4Address(ip)
        except ValueError:
            continue
        if a.is_multicast or a.is_link_local or a.is_unspecified:
            continue  # 组播、链路本地不算「在线主机」
        if ip in seen:
            continue
        seen.add(ip)
        hosts.append(ip)
    return hosts


def scan_phone_ip(timeout=0.35, workers=96):
    """扫局域网找正在推流的手机（不插线时 IP 可能变）。

    返回 (手机IP or None, 在线但没开推流端口的设备列表)。
    先扫邻居表里确实在线的设备，快且准；找不到再兜底全 /24 段。
    """
    import concurrent.futures

    me = local_ipv4()
    if not me:
        return None, []
    subnet = me.rsplit(".", 1)[0]

    def probe(ip):
        try:
            with socket.create_connection((ip, PORT), timeout=timeout) as s:
                s.settimeout(1.5)
                return ip if s.recv(4) == b"PMV1" else None
        except OSError:
            return None

    online = [h for h in arp_hosts() if h != me]

    heard = listen_beacon(1.2)
    if heard:
        return heard, online

    if online:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(online)) as ex:
            for r in ex.map(probe, online):
                if r:
                    return r, online
        # 邻居表里没有能推流的：这几台在线设备就是「手机在线但没开推流」的嫌疑

    hosts = ["%s.%d" % (subnet, i) for i in range(1, 255)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for r in ex.map(probe, hosts):
            if r:
                return r, online
    return None, online


def report_no_stream(online):
    """连不上时分清是「手机没推流」还是「手机根本不在这个网」"""
    if online:
        log("这些设备在线但没有一个在推流：%s" % "、".join(online))
        log("→ 手机若在其中：打开 PhoneMic 点「开始推流」")
        log("→ 都不是：手机换 WiFi 了，或和电脑不在同一个网段")
    else:
        log("局域网里几乎看不到别的设备：手机大概没连这个 WiFi")


_LOCK_FP = None  # 进程存活期间必须一直持有，否则文件锁会被释放


def single_instance_or_exit():
    """手机端一个端口只允许一个客户端，两个进程会互相把连接踢掉（实测过）。

    用文件锁而不是互斥量：同一毫秒内被双击两次也能可靠拦住。
    """
    global _LOCK_FP
    import msvcrt
    path = os.path.join(HERE, ".preview.lock")
    try:
        fp = open(path, "a+")
        fp.seek(0, os.SEEK_END)
        if fp.tell() == 0:
            fp.write("x")
            fp.flush()
        fp.seek(0)
        msvcrt.locking(fp.fileno(), msvcrt.LK_NBLCK, 1)
        _LOCK_FP = fp
        return
    except OSError:
        print("已经有一个预览窗口在运行了，本次直接退出")
        sys.exit(0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wifi", action="store_true", help="只走 WiFi")
    ap.add_argument("--usb", action="store_true", help="只走 USB")
    ap.add_argument("--ip", default=None, help="手机局域网 IP")
    ap.add_argument("--scan", action="store_true",
                    help="先扫一遍局域网找手机（IP 变了的时候用）")
    ap.add_argument("--fit", choices=("cover", "contain"), default="cover",
                    help="cover=铺满窗口并裁掉溢出（默认）；contain=整幅可见留黑边")
    args = ap.parse_args()
    single_instance_or_exit()

    preview = Preview(fit=args.fit)
    fwd = None
    use_usb = not args.wifi
    use_wifi = not args.usb
    wifi_fail = 0

    log("PhoneMic 视频预览启动（Esc 退出 | 拖画面=移动 | 边缘=改大小 | M=镜像 | H=帧率）")
    preview.show_waiting()
    while not preview.quit:
        preview.show_waiting()
        if preview.quit:
            break
        try:
            if use_usb:
                if fwd is None or fwd.poll() is not None:
                    fwd = spawn_forward()
                    time.sleep(1.2)
                try:
                    preview.wait_text = "Connecting over USB..."
                    stream_once("127.0.0.1", "USB", preview)
                    wifi_fail = 0
                    continue
                except (OSError, ConnectionError) as e:
                    log("USB 通道不通（%s），转 WiFi" % e)
                    preview.wait_text = "USB not found - trying Wi-Fi..."
                    use_usb = False
                    if fwd is not None and fwd.poll() is None:
                        fwd.terminate()
                        fwd = None
                    continue

            if not use_wifi:
                log("USB 通道断开，等待重试…")
                time.sleep(2)
                use_usb = not args.wifi
                continue

            ip = args.ip or wifi_ip()
            heard = listen_beacon(0.6)
            if heard:
                if heard != ip:
                    log("收到手机广播：%s" % heard)
                    save_wifi_ip(heard)
                ip = heard
            # 没配 IP、或刚连失败过，就扫一遍局域网（IP 被 DHCP 换掉时很常见）
            if (args.scan or not ip or wifi_fail >= 1) and not heard:
                log("扫描局域网查找手机…")
                preview.show_waiting("Scanning Wi-Fi for phone...")
                found, online = scan_phone_ip()
                args.scan = False
                if found:
                    ip = found
                    save_wifi_ip(found)
                    wifi_fail = 0
                    log("发现手机 %s（已记到 phonemic_wifi.txt）" % ip)
                elif not ip:
                    report_no_stream(online)
                    preview.show_waiting("Phone not streaming - open PhoneMic, tap START")
                    time.sleep(5)
                    continue
                else:
                    log("没扫到推流中的手机，继续试 %s" % ip)
                    report_no_stream(online)
                    preview.wait_text = "Phone not streaming - open PhoneMic, tap START"
            stream_once(ip, "WiFi", preview)
            wifi_fail = 0
        except KeyboardInterrupt:
            break
        except Exception as e:
            log("中断: %s" % e)
            wifi_fail += 1
            # 下一轮重新尝试 USB（除非指定 --wifi），避免一次失败就永远走 WiFi
            use_usb = not args.wifi
            time.sleep(2)

    if fwd is not None and fwd.poll() is None:
        fwd.terminate()
    cv2.destroyAllWindows()
    log("退出")


if __name__ == "__main__":
    main()
