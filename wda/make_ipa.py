# -*- coding: utf-8 -*-
"""
从 Appium WebDriverAgent 官方 release 生成可签名的 .ipa。

为什么需要这个脚本：
  Appium WDA release 的 zip 内含 .dSYM 调试符号目录，
  直接用 Sideloadly 打包会签名失败：
      Failed to process app binary (-69) ... macho sign/edit failed (-40)
  所以必须剔除 *.dSYM / .DS_Store 后重新打包。

用法：
  python make_ipa.py                       # 自动下载最新 release 到 wda/ 并打包
  python make_ipa.py path/to/WebDriverAgentRunner.zip   # 用已下载的 zip 打包

产出：wda/WebDriverAgent.ipa（未签名，需自行用 Sideloadly / AltStore / 开发者证书签名）
"""
import os
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_IPA = HERE / "WebDriverAgent.ipa"
APP_NAME = "WebDriverAgentRunner-Runner.app"


def build_from_zip(zip_path: Path, out_ipa: Path = OUT_IPA) -> Path:
    """解压 zip -> 剔除 dSYM/.DS_Store -> 重新打包为 ipa。"""
    work = Path(tempfile.mkdtemp(prefix="wda_ipa_"))
    try:
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(work)

        # 找到 .app 包
        apps = list(work.rglob(f"{APP_NAME}"))
        if not apps:
            raise SystemExit(f"zip 里没找到 {APP_NAME}，确认这是 Appium WDA 的 release 包")
        app_dir = apps[0]
        root = app_dir.parent

        # 剔除调试符号与垃圾文件（签名失败 -69/-40 的元凶）
        removed = 0
        for pattern in ("*.dSYM", ".DS_Store"):
            for p in list(root.rglob(pattern)):
                shutil.rmtree(p) if p.is_dir() else p.unlink()
                removed += 1
        print(f"[*] 已剔除 {removed} 个 dSYM/垃圾文件")

        payload = root / "Payload"
        if payload.exists():
            shutil.rmtree(payload)
        payload.mkdir()
        shutil.move(str(app_dir), str(payload / APP_NAME))

        if out_ipa.exists():
            out_ipa.unlink()
        with zipfile.ZipFile(out_ipa, "w", zipfile.ZIP_DEFLATED) as z:
            for f in payload.rglob("*"):
                z.write(f, f.relative_to(root).as_posix())
        print(f"[+] 生成 {out_ipa}  ({out_ipa.stat().st_size/1024:.0f} KB)")
        return out_ipa
    finally:
        shutil.rmtree(work, ignore_errors=True)


def download_latest_release() -> Path:
    """从 GitHub 下载最新 Appium WDA release zip（网络不通时可用 gh-proxy 前缀）。"""
    import urllib.request
    import json

    api = "https://api.github.com/repos/appium/WebDriverAgent/releases/latest"
    mirrors = ["https://gh-proxy.com/", ""]
    with urllib.request.urlopen(api, timeout=30) as r:
        assets = json.load(r).get("assets", [])
    asset = next((a for a in assets if a["name"].lower().endswith(".zip")), None)
    if not asset:
        raise SystemExit("release 里没找到 zip 资产，请手动下载后传给本脚本")

    url = asset["browser_download_url"]
    dest = HERE / asset["name"]
    for m in mirrors:
        try:
            full = (m + url) if m else url
            print(f"[*] 下载 {full}")
            urllib.request.urlretrieve(full, dest)
            return dest
        except Exception as e:
            print(f"    失败: {e}")
    raise SystemExit("下载失败：请手动从 https://github.com/appium/WebDriverAgent/releases 下载 zip 后运行 python make_ipa.py <zip路径>")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        src = Path(sys.argv[1])
        if not src.exists():
            raise SystemExit(f"文件不存在: {src}")
        build_from_zip(src)
    else:
        cached = sorted(HERE.glob("WebDriverAgentRunner*.zip"))
        src = cached[-1] if cached else download_latest_release()
        build_from_zip(src)
    print("[i] 下一步：用 Sideloadly 用你的 Apple ID 给 WebDriverAgent.ipa 签名并安装（见 docs/02-从零部署.md）")
