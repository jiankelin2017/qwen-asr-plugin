# -*- coding: utf-8 -*-
"""
Qwen ASR · 安装器
════════════════════════════════════════════════════════════════════════
这个 exe 只有十几 MB，里面【只有脚本】，不含 Python 环境和模型。
运行时按你选的版本把它们下载下来，装成能直接在 DaVinci Resolve 里用的样子。

安装后的目录结构（BASE = 你选的安装位置）：

    BASE\\q3\\                        引擎（Python 脚本）
    BASE\\Qwen ASR\\.venv\\            运行环境（Python 3.12 + torch 等）
    BASE\\Qwen字幕工具\\models\\...      识别模型
    BASE\\Qwen字幕工具\\字幕输出\\        字幕产物

★ 这个结构是 Lua 主脚本认的布局，别改目录名。
════════════════════════════════════════════════════════════════════════
"""

import os
import re
import sys
import json
import time
import shutil
import struct
import queue
import zipfile
import tempfile
import threading
import subprocess
import urllib.request
import urllib.error
from pathlib import Path

try:
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox
except Exception:
    tk = None

# ── 版本与地址 ────────────────────────────────────────────────────────
APP_NAME = "Qwen ASR"
PY_VER = "3.12.9"
PY_TAG = "3.12.9-amd64"

# Python 用 embeddable 版（免安装、10.6MB、不写注册表、不需要管理员权限）。
# ★ 试过完整安装器 + /quiet TargetDir=... ：实测静默安装【不生效】——
#   它会装到 %LOCALAPPDATA%\Programs\Python 而不是指定目录，退出码还是 0，
#   装完一检查目录是空的。embeddable 是纯解压，没这些坑。
# 顺序按实测连通性排：清华镜像对 embed zip 会 403（HEAD 却返回 200，很迷惑），
# 所以 npmmirror 优先，官方兜底。
# ★ 文件名是 python-3.12.9-embed-amd64.zip —— 两处都用 PY_VER。
#   曾经第二个也填了 PY_TAG(=3.12.9-amd64)，拼成
#   python-3.12.9-amd64-embed-amd64.zip → 全部 404，排查了半天。
PY_SOURCES = [
    ("npmmirror", "https://registry.npmmirror.com/-/binary/python/%s/python-%s-embed-amd64.zip" % (PY_VER, PY_VER)),
    ("官方", "https://www.python.org/ftp/python/%s/python-%s-embed-amd64.zip" % (PY_VER, PY_VER)),
    ("清华镜像", "https://mirrors.tuna.tsinghua.edu.cn/python/%s/python-%s-embed-amd64.zip" % (PY_VER, PY_VER)),
]

# torch：CPU 版 104MB，GPU(cu128) 版 2728MB
TORCH_CPU = [
    ("上海交大", "https://mirror.sjtu.edu.cn/pytorch-wheels/cpu/"),
    ("官方", "https://download.pytorch.org/whl/cpu"),
]
TORCH_GPU = [
    ("上海交大", "https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/"),
    ("官方", "https://download.pytorch.org/whl/cu128"),
]

# 其余依赖走 PyPI 镜像
PYPI = [
    ("清华", "https://pypi.tuna.tsinghua.edu.cn/simple"),
    ("阿里", "https://mirrors.aliyun.com/pypi/simple"),
    ("官方", "https://pypi.org/simple"),
]

REPO = "Qwen/Qwen3-ASR-0.6B"
MODEL_BAKES = [
    ("hf-mirror", "https://hf-mirror.com/%s/resolve/main/" % REPO),
    ("ModelScope", "https://www.modelscope.cn/models/%s/resolve/master/" % REPO),
    ("官方", "https://huggingface.co/%s/resolve/main/" % REPO),
]

# 模型文件：先下小的，再下权重。列表里不存在的（404）自动跳过。
MODEL_SMALL = [
    "config.json", "generation_config.json", "tokenizer.json",
    "tokenizer_config.json", "preprocessor_config.json", "processor_config.json",
    "chat_template.json", "chat_template.jinja", "vocab.json", "merges.txt",
    "special_tokens_map.json", "added_tokens.json",
]
MODEL_WEIGHT = "model.safetensors"

PY_DEPS = ["transformers", "numpy", "soundfile", "imageio-ffmpeg"]

UA = {"User-Agent": "Mozilla/5.0"}


# ── 基础工具 ──────────────────────────────────────────────────────────
def parse_base_arg():
    """从命令行取安装位置（Inno Setup 用）。

    Inno 的 [Run] 会把 {app} 作为第一个参数传进来 —— 那时安装目录已经
    由安装包选好并建好了，界面里就不该再问一遍。也支持 --base=路径 手动指定。
    """
    skip_next = False
    for i, a in enumerate(sys.argv[1:]):
        if skip_next:
            skip_next = False
            continue
        if a in ("--base", "/base", "-base"):
            skip_next = True
            continue
        if a.startswith(("--base=", "/base=")):
            return a.split("=", 1)[1]
        if not a.startswith(("/", "-")) and os.path.isdir(a):
            return a
    return None


def payload_dir():
    """exe 里内嵌的脚本目录。开发模式下就是 ./payload"""
    base = getattr(sys, "_MEIPASS", None)
    if base:
        return os.path.join(base, "payload")
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "payload")


def human(n):
    n = float(n or 0)
    if n >= 2 ** 30:
        return "%.2f GB" % (n / 2 ** 30)
    if n >= 2 ** 20:
        return "%.1f MB" % (n / 2 ** 20)
    if n >= 2 ** 10:
        return "%.0f KB" % (n / 2 ** 10)
    return "%.0f B" % n


def http_size(url, timeout=20):
    try:
        req = urllib.request.Request(url, method="HEAD", headers=UA)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return int(r.headers.get("Content-Length") or 0)
    except Exception:
        return 0


def download(url, dst, cb=None, cancel=None, chunk=1 << 20, tries=3, log=None):
    """带断点续传的下载。cb(done, total)；返回 True/False。

    ★ 403/404 这类"源本身拒绝"的错误【不重试】，立刻换下一个源 ——
      重试 3 次只是白白等 4.5 秒。（实测清华镜像对 embed zip 就是 403，
      HEAD 却返回 200，很有迷惑性。）
    """
    dst = str(dst)
    tmp = dst + ".part"
    for attempt in range(tries):
        if cancel and cancel.is_set():
            return False
        try:
            have = os.path.getsize(tmp) if os.path.exists(tmp) else 0
            req = urllib.request.Request(url, headers=dict(UA))
            if have:
                req.add_header("Range", "bytes=%d-" % have)
            with urllib.request.urlopen(req, timeout=60) as r:
                total = int(r.headers.get("Content-Length") or 0)
                if have and r.status == 200:
                    have = 0          # 服务器不支持续传，从头来
                total = have + total if r.status == 206 else total
                mode = "ab" if have and r.status == 206 else "wb"
                done = have if mode == "ab" else 0
                with open(tmp, mode) as f:
                    while True:
                        if cancel and cancel.is_set():
                            return False
                        buf = r.read(chunk)
                        if not buf:
                            break
                        f.write(buf)
                        done += len(buf)
                        if cb:
                            cb(done, total)
            # 完整性：声明了大小就必须对得上
            if total and os.path.getsize(tmp) != total:
                raise IOError("大小不符 %d != %d" % (os.path.getsize(tmp), total))
            os.replace(tmp, dst)
            return True
        except urllib.error.HTTPError as e:
            # 4xx = 源本身拒绝（403 限流 / 404 没有这个文件），重试没意义
            if 400 <= getattr(e, "code", 0) < 500:
                if log:
                    log("    源返回 HTTP %s，换源" % e.code)
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                return False
            if log and attempt == tries - 1:
                log("    HTTP %s" % e.code)
        except Exception as e:
            if log and attempt == tries - 1:
                log("    %s: %s" % (type(e).__name__, e))
        time.sleep(1.5)
    try:
        os.remove(tmp)
    except OSError:
        pass
    return False


def run(cmd, cb=None, cancel=None, cwd=None, env=None, timeout=3600):
    """跑子进程，把输出逐行喂给 cb。返回 returncode。"""
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, encoding="utf-8", errors="replace",
                             bufsize=1,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except Exception as e:
        if cb:
            cb("启动失败: %s" % e)
        return -1
    try:
        for line in iter(p.stdout.readline, ""):
            line = line.rstrip()
            if line and cb:
                cb(line)
            if cancel and cancel.is_set():
                p.terminate()
                break
    except Exception:
        pass
    try:
        return p.wait(timeout=timeout)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass
        return -1


# ── 安装步骤 ──────────────────────────────────────────────────────────
class Installer:
    def __init__(self, base, gpu, mirror, log, prog, cancel):
        self.base = base.rstrip("\\/")
        self.gpu = gpu
        self.mirror = mirror
        self.log = log
        self.prog = prog          # prog(percent, stage_text)
        self.cancel = cancel

        self.q3 = os.path.join(self.base, "q3")
        self.rt_env = os.path.join(self.base, "Qwen ASR")
        self.venv = os.path.join(self.rt_env, ".venv")
        # embeddable 版直接解压到这里：.venv\Scripts\python.exe
        # —— 正好是 Lua 主脚本认的路径，不用再建一层 venv。
        self.venv_scripts = os.path.join(self.venv, "Scripts")

        # 各步骤占整体进度的 (起点, 跨度)。GPU 版 torch 2.7GB 是大头，
        # CPU 版则是模型 1.8GB 占绝对多数，所以两套权重。
        self.W = (dict(py=(0, 3), pip=(3, 3), torch=(6, 56), deps=(62, 6),
                       model=(68, 24), deploy=(92, 5), smoke=(97, 3))
                  if gpu else
                  dict(py=(0, 6), pip=(6, 4), torch=(10, 6), deps=(16, 10),
                       model=(26, 64), deploy=(90, 6), smoke=(96, 4)))
        self.tool = os.path.join(self.base, "Qwen字幕工具")
        self.models = os.path.join(self.tool, "models", "Qwen3-ASR-0.6B-hf")
        self.cache = os.path.join(tempfile.gettempdir(), "qwen3asr_dl")

        self.vpy = os.path.join(self.venv, "Scripts", "python.exe")
        self.wt = 0.0             # 当前步骤起始进度
        self.wspan = 1.0          # 当前步骤占多少

    # 进度：把 [0,1] 的子进度映射到整体区间
    def step(self, frac, text):
        self.prog(self.wt + self.wspan * max(0.0, min(1.0, frac)), text)

    def begin(self, start, span, text):
        self.wt, self.wspan = start, span
        self.step(0.0, text)

    def die(self, msg):
        raise RuntimeError(msg)

    # ── ① Python ────────────────────────────────────────────────────
    def ensure_python(self):
        self.begin(*self.W["py"], text="准备 Python 运行环境")
        os.makedirs(self.cache, exist_ok=True)
        os.makedirs(self.venv_scripts, exist_ok=True)

        exe = os.path.join(self.venv_scripts, "python.exe")
        if os.path.exists(exe):
            self.log("Python 已存在，跳过下载")
            self.step(1, "Python 已就绪")
            return

        zip_path = os.path.join(self.cache, "python-%s-embed-amd64.zip" % PY_TAG)
        srcs = PY_SOURCES if self.mirror else list(reversed(PY_SOURCES))
        ok = False
        for name, url in srcs:
            if self.cancel.is_set():
                return
            self.log("下载 Python %s（%s，免安装版）…" % (PY_VER, name))
            last = [0, 0.0]

            def cb(done, total):
                now = time.time()
                if total and (done - last[0] > 1 << 20 or now - last[1] > 0.4):
                    last[0], last[1] = done, now
                    self.step(done / total * 0.85,
                              "下载 Python %s / %s" % (human(done), human(total)))

            if download(url, zip_path, cb, self.cancel, log=self.log):
                self.log("下载完成（%s）" % human(os.path.getsize(zip_path)))
                ok = True
                break
            self.log("  %s 下载失败，换下一个源" % name)
        if not ok:
            self.die("Python 下载失败。请检查网络后重试。")

        self.step(0.9, "解压 Python")
        try:
            with zipfile.ZipFile(zip_path) as z:
                z.extractall(self.venv_scripts)
        except Exception as e:
            self.die("Python 解压失败：%s" % e)
        if not os.path.exists(exe):
            self.die("解压后找不到 python.exe")

        # embeddable 版默认关掉 site（不加载 site-packages），pip 装的东西会找不到。
        # 改 _pth 打开它 —— 少了这一步，后面 torch 装完 import 不到。
        for f in os.listdir(self.venv_scripts):
            if f.endswith("._pth"):
                p = os.path.join(self.venv_scripts, f)
                try:
                    txt = open(p, encoding="utf-8").read()
                    if "import site" not in txt.replace("#import site", ""):
                        txt = txt.replace("#import site", "import site")
                    if "Lib\\site-packages" not in txt:
                        txt = txt.replace("\nimport site",
                                          "\nLib\\site-packages\nimport site")
                    open(p, "w", encoding="utf-8").write(txt)
                except Exception:
                    pass
        os.makedirs(os.path.join(self.venv_scripts, "Lib", "site-packages"),
                    exist_ok=True)
        self.log("Python 就绪：%s" % exe)
        self.step(1, "Python 就绪")

    # ── ② pip ───────────────────────────────────────────────────────
    def make_venv(self):
        """embeddable 版没有 pip（也没有 venv 模块），这里把它装上。

        ★ get-pip.py 直接内嵌在 exe 里（2.1MB），这样装 pip 只走 PyPI 镜像，
          不用去连 bootstrap.pypa.io —— 国内网络下少一个可能卡住的环节。
        """
        self.begin(*self.W["pip"], text="安装 pip")
        rc = run([self.vpy, "-m", "pip", "--version"],
                 cb=lambda l: None, cancel=self.cancel, timeout=180)
        if rc == 0:
            self.log("pip 已存在，跳过")
            self.step(1, "pip 已就绪")
            return

        g = os.path.join(payload_dir(), "get-pip.py")
        if not os.path.isfile(g):
            self.die("安装器内部缺少 get-pip.py，请重新下载本安装器。")
        order = PYPI if self.mirror else list(reversed(PYPI))
        for name, idx in order:
            if self.cancel.is_set():
                return
            self.log("安装 pip（%s 源）…" % name)
            rc = run([self.vpy, g, "-i", idx, "--no-warn-script-location"],
                     cb=lambda l: self.log("  " + l[:160]),
                     cancel=self.cancel, timeout=900)
            if rc == 0:
                break
            self.log("  %s 失败，换下一个源" % name)
        rc = run([self.vpy, "-m", "pip", "--version"],
                 cb=lambda l: None, cancel=self.cancel, timeout=180)
        if rc != 0:
            self.die("pip 安装失败。可手动运行：%s %s" % (self.vpy, g))
        self.log("pip 就绪")
        self.step(1, "pip 就绪")

    # ── ③ 依赖 ──────────────────────────────────────────────────────
    def pip_install(self):
        self.begin(*self.W["torch"],
                   text="安装 torch（%s）" % ("GPU 版" if self.gpu else "CPU 版"))
        srcs = (TORCH_GPU if self.gpu else TORCH_CPU)
        srcs = srcs if self.mirror else list(reversed(srcs))
        ok = False
        for name, idx in srcs:
            if self.cancel.is_set():
                return
            self.log("安装 torch（%s，%s）…%s" % (
                "GPU" if self.gpu else "CPU", name,
                " 体积较大，请耐心" if self.gpu else ""))
            rc = run([self.vpy, "-m", "pip", "install", "torch",
                      "--index-url", idx,
                      "--extra-index-url", (PYPI[0][1] if self.mirror else PYPI[-1][1])],
                     cb=lambda l: self.log("  " + l[:200]),
                     cancel=self.cancel, timeout=5400)
            if rc == 0:
                ok = True
                break
            self.log("  %s 安装失败，换下一个源" % name)
        if not ok:
            self.die("torch 安装失败。可稍后重试，安装器支持断点续传的缓存。")
        self.log("torch 装好了")
        self.step(1, "torch 装好了")

        self.begin(*self.W["deps"], text="安装其余依赖（transformers / numpy 等）")
        pypi = PYPI[0][1] if self.mirror else PYPI[-1][1]
        rc = run([self.vpy, "-m", "pip", "install", "-i", pypi] + PY_DEPS,
                 cb=lambda l: self.log("  " + l[:200]),
                 cancel=self.cancel, timeout=2400)
        if rc != 0:
            # 换下一个源再试一次
            rc = run([self.vpy, "-m", "pip", "install", "-i", PYPI[1][1]] + PY_DEPS,
                     cb=lambda l: self.log("  " + l[:200]),
                     cancel=self.cancel, timeout=2400)
        if rc != 0:
            self.die("依赖安装失败（transformers / numpy / soundfile / imageio-ffmpeg）")
        self.log("依赖装好了")
        self.step(1, "依赖装好了")

    # ── ④ 模型 ──────────────────────────────────────────────────────
    def fetch_model(self):
        self.begin(*self.W["model"], text="下载识别模型")
        os.makedirs(self.models, exist_ok=True)
        bakes = MODEL_BAKES if self.mirror else list(reversed(MODEL_BAKES))
        if self.cancel.is_set():
            return

        # 小文件：每个文件都把几个源试遍。
        # ★ 不能写成"一个源试完所有文件就换源"—— 各镜像收录的文件并不一致
        #   （hf-mirror 上就没有 tokenizer.json），那样会因个别文件缺失
        #   而把整个源判死。实测 hf-mirror 还会偶发 502，必须逐文件重试。
        self.log("取模型元信息…")
        got_cfg = False
        for f in MODEL_SMALL:
            if self.cancel.is_set():
                return
            dst = os.path.join(self.models, f)
            if os.path.exists(dst) and os.path.getsize(dst) > 0:
                got_cfg = got_cfg or f == "config.json"
                continue
            for name, base in bakes:
                if download(base + f, dst, None, self.cancel, tries=2, log=self.log):
                    if f == "config.json":
                        got_cfg = True
                    self.log("  ✓ %s（%s）" % (f, name))
                    break
        if not got_cfg:
            self.die("模型配置文件下载失败（config.json）。请检查网络后重试。")

        # 权重（大头）
        dst = os.path.join(self.models, MODEL_WEIGHT)
        if os.path.exists(dst) and os.path.getsize(dst) > 100 << 20:
            self.log("模型权重已存在（%s），跳过下载" % human(os.path.getsize(dst)))
            self.step(1, "模型已就绪")
            return
        ok = False
        for name, base in bakes:
            if self.cancel.is_set():
                return
            url = base + MODEL_WEIGHT
            total = http_size(url) or 1790 * 2 ** 20
            self.log("下载模型权重 %s（%s）…这是最大的一份，慢一点正常"
                     % (human(total), name))
            last = [0, 0.0]

            def cb(done, tot):
                now = time.time()
                if done - last[0] > 4 << 20 or now - last[1] > 0.5:
                    last[0], last[1] = done, now
                    pct = done / max(1, tot or total)
                    self.step(pct, "下载模型 %s / %s（%.0f%%）"
                              % (human(done), human(tot or total), pct * 100))

            if download(url, dst, cb, self.cancel, tries=4, log=self.log):
                ok = True
                self.log("模型下载完成（%s）" % human(os.path.getsize(dst)))
                break
            self.log("  %s 下载失败，换下一个源" % name)
        if not ok:
            self.die("模型权重下载失败。若断点续传卡住，可删掉 %s 后重试。" % dst)

        # 校验：safetensors 头部必须是合法 JSON
        try:
            with open(dst, "rb") as f:
                n = struct.unpack("<Q", f.read(8))[0]
                json.loads(f.read(n))
        except Exception as e:
            self.die("模型文件损坏（%s）。请删除后重新运行安装器。" % e)
        self.step(1, "模型已就绪")

    # ── ⑤ 部署脚本 ──────────────────────────────────────────────────
    def deploy(self):
        self.begin(*self.W["deploy"], text="部署脚本")
        src = payload_dir()
        if not os.path.isdir(src):
            self.die("安装器内部缺少脚本文件（payload），请重新下载本安装器。")

        os.makedirs(self.q3, exist_ok=True)
        os.makedirs(os.path.join(self.q3, "rt"), exist_ok=True)
        os.makedirs(os.path.join(self.tool, "字幕输出"), exist_ok=True)

        for f in os.listdir(src):
            # ★ 排除 get-pip.py：它是安装时用来装 pip 的（已内嵌进 payload），
            #   不该被当成引擎脚本一起拷进 q3。
            if f.endswith(".py") and f != "get-pip.py":
                shutil.copy2(os.path.join(src, f), os.path.join(self.q3, f))
        shutil.copy2(os.path.join(src, "Qwen ASR.lua"),
                     os.path.join(self.q3, "Qwen ASR.lua"))
        # WAV 渲染预设：渲染导出靠它设格式（中文版 Resolve 上内置
        # 'Audio Only' 预设名被本地化，LoadRenderPreset 必失败）。
        # Lua 按「脚本同级 → 引擎目录」的顺序找它，两处都要放。
        if os.path.isfile(os.path.join(src, "render_to_wav.xml")):
            shutil.copy2(os.path.join(src, "render_to_wav.xml"),
                         os.path.join(self.q3, "render_to_wav.xml"))
        else:
            self.log("  ⚠ payload 里没有 render_to_wav.xml，渲染导出将走格式探测")
        self.log("引擎已部署到 %s" % self.q3)

        # Lua 主脚本要放进 DaVinci 的脚本目录，菜单里才会出现。
        # 同时把它认的引擎路径改成实际安装位置（支持装到任意目录）。
        lua_src = open(os.path.join(src, "Qwen ASR.lua"), encoding="utf-8").read()
        escaped = self.q3.replace("\\", "\\\\")   # C:\a\b -> C:\\a\\b（Lua 字符串要转义）
        if "--<<INSTALL_ROOT>>" in lua_src:
            # ★★ repl 必须用 lambda：re.sub 会把替换串里的 `\\` 当转义吃掉，
            #    直接传字符串的话 `C:\\Users` 会被写成 `C:\Users` —— `\U` 在
            #    Lua 里是非法转义，脚本一加载就报 token recognition error。
            #    （实测踩到：临时目录含 \U 时直接语法错误。）
            lua_src = re.sub(
                r'local INSTALLED_ROOT = "[^"]*"\s*--<<INSTALL_ROOT>>',
                lambda _m: 'local INSTALLED_ROOT = "%s"' % escaped,
                lua_src, count=1)
        else:
            self.log("  ⚠ Lua 里没找到 INSTALL_ROOT 标记，跳过路径改写")
        self.log("引擎路径写入 Lua：%s" % self.q3)
        # ★ 顺手把【改写过的】Lua 也写回 q3 一份：万一安装时没找到 DaVinci
        #   脚本目录，下面会提示用户手动复制 {q3}\Qwen ASR.lua —— 若那份还留着
        #   未改写的 INSTALL_ROOT，自定义安装目录时脚本按盘符也探不到引擎，
        #   复制过去照样打不开。这里直接覆盖成正确版本。
        try:
            with open(os.path.join(self.q3, "Qwen ASR.lua"), "w",
                      encoding="utf-8", newline="\n") as f:
                f.write(lua_src)
        except Exception:
            pass

        placed = []
        for d in resolve_script_dirs():
            try:
                target = os.path.join(d, "Qwen ASR")
                os.makedirs(target, exist_ok=True)
                with open(os.path.join(target, "Qwen ASR.lua"), "w",
                          encoding="utf-8", newline="\n") as f:
                    f.write(lua_src)
                # 渲染预设必须和 Lua 放同一目录（Lua 用 debug.getinfo
                # 拿脚本目录，第一候选就是这里）
                xml_src = os.path.join(src, "render_to_wav.xml")
                if os.path.isfile(xml_src):
                    shutil.copy2(xml_src,
                                 os.path.join(target, "render_to_wav.xml"))
                placed.append(target)
            except Exception as e:
                self.log("  写入 %s 失败：%s" % (d, type(e).__name__))
        if placed:
            for p in placed:
                self.log("已安装到 DaVinci 脚本目录：%s" % p)
        else:
            self.log("⚠ 没找到 DaVinci 脚本目录（DaVinci 可能没装过）。")
            self.log("  装好 DaVinci 后，把 %s\\Qwen ASR.lua 复制到：" % self.q3)
            self.log("  %%ProgramData%%\\Blackmagic Design\\DaVinci Resolve\\Fusion\\Scripts\\Utility\\Qwen ASR\\")

        # 使用说明
        try:
            shutil.copy2(os.path.join(src, "使用说明.txt"),
                         os.path.join(self.tool, "使用说明.txt"))
        except Exception:
            pass

        # 卸载清单：Inno 卸载时按它精确清理 DaVinci 脚本目录 ——
        # 只删我们真的写进去的，没部署过就一个都不碰。
        # 路径统一成正斜杠：JSON 会把反斜杠转义成 \\，Inno 的 Pascal 代码
        # 做字符串查找时对不上。
        if getattr(sys, "frozen", False):
            try:
                man = os.path.join(os.path.dirname(sys.executable), "_deployed.json")
                with open(man, "w", encoding="utf-8") as f:
                    json.dump({"resolve_dirs": [p.replace("\\", "/") for p in placed],
                               "q3": self.q3.replace("\\", "/"),
                               "tool": self.tool.replace("\\", "/")},
                              f, ensure_ascii=False, indent=1)
            except Exception:
                pass
        self.step(1, "脚本部署完成")

    # ── ⑥ 冒烟测试 ──────────────────────────────────────────────────
    def smoke(self):
        """真跑一次识别，不只是加载模型。

        ★ 两个坑都在这里踩过：
          ① 以前没传 asr_model，Engine 回退到【本机】的默认模型路径，
             于是"测试通过"其实测的是旧模型，新装的那份根本没被验证。
          ② 只 load() 不 generate()，dtype/算子那类问题暴露不出来
             （CPU 上 bf16 的坑就是这么藏住的）。
        """
        self.begin(*self.W["smoke"], text="验证能不能跑起来")
        code = (
            "import sys, math, struct, wave, tempfile, os\n"
            "sys.path.insert(0, " + repr(self.q3) + ")\n"
            "from asr_engine import Engine\n"
            "e = Engine(log=print, asr_model=" + repr(self.models) + ")\n"
            "e.load()\n"
            "print('MODEL_DIR=' + str(e.asr_path))\n"
            "sr = 16000\n"
            "p = os.path.join(tempfile.gettempdir(), 'q3_smoke.wav')\n"
            "w = wave.open(p, 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)\n"
            "w.writeframes(b''.join(struct.pack('<h', int(9000 * math.sin(2 * math.pi * 440 * i / sr)))\n"
            "                       for i in range(sr * 3)))\n"
            "w.close()\n"
            "blocks, stats = e.run(p, lang='Chinese', max_chars=12)\n"
            "print('SMOKE_OK device=' + str(e.device) + ' blocks=' + str(len(blocks)))\n"
        )
        out = []

        def cb(l):
            out.append(l)
            self.log("  " + l[:200])

        rc = run([self.vpy, "-c", code], cb=cb, cancel=self.cancel, timeout=900)
        joined = "\n".join(out)
        if rc != 0 or "SMOKE_OK" not in joined:
            self.log("⚠ 冒烟测试没通过（返回码 %d）。上面几行是原因。" % rc)
            self.log("  torch / transformers 装了，但模型或算子跑不起来。")
            self.log("  先看上面报错，或把这段日志发我。")
        elif self.models.replace("/", "\\").lower() not in joined.lower():
            self.log("⚠ 冒烟测试跑的是别处的模型，不是刚装的那份：")
            self.log("  " + (joined.split("MODEL_DIR=") + [""])[1][:160])
        else:
            self.log("✓ 冒烟测试通过：新装的模型能正常识别")
        self.step(1, "完成")

    # ── ⑦ 收尾：清掉下载缓存 ────────────────────────────────────────
    def clean_cache(self):
        """安装成功后清掉下载缓存。

        Python embed zip + torch wheel（GPU 版 2.7 GB）+ 模型分片都堆在
        %TEMP%\\qwen3asr_dl 里，装完就没用了 —— 不清的话一台机器白占几个 GB。
        这个目录在 {app} 之外，Inno 卸载器不管它（[UninstallDelete] 只管
        {app} 下的几棵子树），所以只能在这里收尾。

        ★ 只在全部步骤成功后才调：中途失败还要靠缓存续传，不能提前清。
        """
        try:
            if not os.path.isdir(self.cache):
                return
            shutil.rmtree(self.cache, ignore_errors=True)
            if os.path.isdir(self.cache):
                self.log("下载缓存没能完全清掉：%s（可手动删除）" % self.cache)
            else:
                self.log("已清理下载缓存：%s" % self.cache)
        except Exception as e:
            self.log("清理下载缓存失败（不影响使用）：%s" % e)


def resolve_script_dirs():
    """DaVinci 会扫描的脚本目录（按优先级）。返回存在的那些。

    全新机器上 Utility 目录要用户手动建过才存在；DaVinci 装着的时候就
    直接认 ProgramData 那处 —— 部署时 makedirs 会把它建出来（Inno 安装包
    是管理员权限，建得动；单独跑 exe 建不动时会记日志走手动兜底）。
    """
    out = []
    env = os.environ
    pd = env.get("ProgramData", r"C:\ProgramData")
    ad = env.get("APPDATA", os.path.expanduser("~"))
    cands = [
        os.path.join(pd, "Blackmagic Design", "DaVinci Resolve", "Fusion", "Scripts", "Utility"),
        os.path.join(ad, "Blackmagic Design", "DaVinci Resolve", "Support", "Fusion", "Scripts", "Utility"),
        os.path.join(env.get("ProgramFiles", r"C:\Program Files"), "Blackmagic Design",
                     "DaVinci Resolve", "Fusion", "Scripts", "Utility"),
    ]
    for c in cands:
        if os.path.isdir(c) and c not in out:
            out.append(c)
    if not out:
        dv = os.path.join(env.get("ProgramFiles", r"C:\Program Files"),
                          "Blackmagic Design", "DaVinci Resolve")
        if os.path.isdir(dv) and cands[0] not in out:
            out.append(cands[0])
    return out


# ── GUI ───────────────────────────────────────────────────────────────
class App:
    def __init__(self, root, base=None):
        self.root = root
        self.base_arg = base      # Inno 传来的安装目录；None = 手动选
        self.q = queue.Queue()
        self.cancel = threading.Event()
        self.worker = None
        self.done = False

        root.title("%s · 安装器" % APP_NAME)
        root.geometry("720x560")
        root.resizable(False, False)

        pad = {"padx": 12, "pady": 6}
        frm = ttk.Frame(root)
        frm.pack(fill="both", expand=True)

        ttk.Label(frm, text="%s 安装器" % APP_NAME,
                  font=("Microsoft YaHei UI", 14, "bold")).pack(anchor="w", **pad)
        ttk.Label(frm, text="本安装器只含脚本。运行环境与模型在下面选择后下载。",
                  foreground="#666").pack(anchor="w", padx=12)

        # 安装位置
        row = ttk.Frame(frm)
        row.pack(fill="x", **pad)
        ttk.Label(row, text="安装位置", width=10).pack(side="left")
        self.var_base = tk.StringVar(value=base or r"C:\HEIBA")
        ent = ttk.Entry(row, textvariable=self.var_base)
        ent.pack(side="left", fill="x", expand=True, padx=6)
        if base:
            # 安装包已经选好位置并建好目录，锁掉不让改（改了会和卸载清单对不上）
            ent.config(state="readonly")
            ttk.Label(row, text="由安装包指定", foreground="#888").pack(side="left")
        else:
            ttk.Button(row, text="浏览…", width=8,
                       command=self.pick_dir).pack(side="left")

        # 版本
        row2 = ttk.Frame(frm)
        row2.pack(fill="x", **pad)
        ttk.Label(row2, text="运行版本", width=10).pack(side="left")
        self.var_gpu = tk.BooleanVar(value=False)
        ttk.Radiobutton(row2, text="CPU 版（下载约 1.8 GB，普通电脑都能用）",
                        variable=self.var_gpu, value=False,
                        command=self.refresh_tip).pack(anchor="w")
        ttk.Radiobutton(row2, text="GPU 版（下载约 4.4 GB，需 NVIDIA 显卡，快约 3 倍）",
                        variable=self.var_gpu, value=True,
                        command=self.refresh_tip).pack(anchor="w")

        # 下载源
        row3 = ttk.Frame(frm)
        row3.pack(fill="x", **pad)
        ttk.Label(row3, text="下载源", width=10).pack(side="left")
        self.var_mirror = tk.BooleanVar(value=True)
        ttk.Radiobutton(row3, text="国内镜像（推荐）", variable=self.var_mirror,
                        value=True).pack(side="left")
        ttk.Radiobutton(row3, text="官方源", variable=self.var_mirror,
                        value=False).pack(side="left", padx=12)

        self.lbl_tip = ttk.Label(frm, text="", foreground="#1D9E75")
        self.lbl_tip.pack(anchor="w", padx=12, pady=2)

        # 进度
        pf = ttk.Frame(frm)
        pf.pack(fill="x", padx=12, pady=(10, 2))
        self.var_stage = tk.StringVar(value="就绪")
        ttk.Label(pf, textvariable=self.var_stage).pack(anchor="w")
        self.bar = ttk.Progressbar(pf, mode="determinate", maximum=100)
        self.bar.pack(fill="x", pady=2)

        # 日志
        lf = ttk.Frame(frm)
        lf.pack(fill="both", expand=True, padx=12, pady=6)
        self.txt = tk.Text(lf, height=12, wrap="word", font=("Consolas", 9))
        sb = ttk.Scrollbar(lf, command=self.txt.yview)
        self.txt.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.txt.pack(side="left", fill="both", expand=True)

        # 按钮
        bf = ttk.Frame(frm)
        bf.pack(fill="x", padx=12, pady=(0, 10))
        self.btn_go = ttk.Button(bf, text="开始安装", command=self.go)
        self.btn_go.pack(side="left")
        self.btn_cancel = ttk.Button(bf, text="取消", command=self.do_cancel,
                                     state="disabled")
        self.btn_cancel.pack(side="left", padx=8)
        ttk.Button(bf, text="退出", command=root.destroy).pack(side="right")

        self.refresh_tip()
        self.root.after(80, self.pump)

    def refresh_tip(self):
        if self.var_gpu.get():
            self.lbl_tip.config(text="将下载约 4.4 GB：torch GPU 版 2.7 GB + 模型 1.8 GB + Python 与其它 0.2 GB")
        else:
            self.lbl_tip.config(text="将下载约 1.8 GB：模型 1.8 GB + torch CPU 版 0.1 GB + Python 与其它 0.2 GB")

    def pick_dir(self):
        d = filedialog.askdirectory(initialdir=self.var_base.get() or "C:\\")
        if d:
            self.var_base.set(d.replace("/", "\\"))

    def say(self, msg):
        self.q.put(("log", msg))

    def prog(self, pct, text):
        self.q.put(("prog", (max(0, min(100, pct)), text)))

    def pump(self):
        try:
            while True:
                kind, val = self.q.get_nowait()
                if kind == "log":
                    self.txt.insert("end", val + "\n")
                    self.txt.see("end")
                elif kind == "prog":
                    self.bar["value"] = val[0]
                    self.var_stage.set(val[1])
                elif kind == "end":
                    self.finish(val)
        except queue.Empty:
            pass
        self.root.after(80, self.pump)

    def finish(self, ok_msg):
        self.btn_go.config(state="normal")
        self.btn_cancel.config(state="disabled")
        self.done = True
        if ok_msg is True:
            self.bar["value"] = 100
            self.var_stage.set("安装完成")
            messagebox.showinfo("完成",
                                "安装完成。\n\n打开 DaVinci Resolve → 顶部菜单「工作区」→「脚本」，"
                                "就能看到「Qwen ASR」。\n\n如果菜单里没有，重启一下 Resolve。")
        elif ok_msg == "cancelled":
            self.var_stage.set("已取消")
        else:
            self.var_stage.set("安装失败")
            messagebox.showerror("安装失败", str(ok_msg)[:400])

    def go(self):
        base = self.var_base.get().strip()
        if not base:
            messagebox.showwarning("缺少信息", "请选择安装位置")
            return
        # 提前探一下能不能写，避免下载完了才发现装不进去
        try:
            os.makedirs(base, exist_ok=True)
            probe = os.path.join(base, ".write_test")
            with open(probe, "w") as f:
                f.write("x")
            os.remove(probe)
        except Exception as e:
            messagebox.showerror("装不了", "无法写入 %s\n%s\n\n请换一个位置（如 D:\\HEIBA），"
                                           "或以管理员身份运行。" % (base, e))
            return

        self.txt.delete("1.0", "end")
        self.btn_go.config(state="disabled")
        self.btn_cancel.config(state="normal")
        self.cancel.clear()
        gpu = self.var_gpu.get()
        mirror = self.var_mirror.get()

        def work():
            try:
                inst = Installer(base, gpu, mirror,
                                 self.say, self.prog, self.cancel)
                self.say("安装位置：%s" % base)
                self.say("版本：%s　下载源：%s" % ("GPU" if gpu else "CPU",
                                                  "国内镜像" if mirror else "官方"))
                inst.ensure_python()
                if self.cancel.is_set():
                    self.q.put(("end", "cancelled")); return
                inst.make_venv()
                if self.cancel.is_set():
                    self.q.put(("end", "cancelled")); return
                inst.pip_install()
                if self.cancel.is_set():
                    self.q.put(("end", "cancelled")); return
                inst.fetch_model()
                if self.cancel.is_set():
                    self.q.put(("end", "cancelled")); return
                inst.deploy()
                inst.smoke()
                inst.clean_cache()
                self.say("全部完成。")
                self.q.put(("end", True))
            except Exception as e:
                self.say("出错：%s: %s" % (type(e).__name__, e))
                self.q.put(("end", str(e)))

        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()

    def do_cancel(self):
        self.cancel.set()
        self.say("正在取消（当前步骤结束后停止）…")
        self.btn_cancel.config(state="disabled")


def main():
    if tk is None:
        print("缺少 tkinter，无法启动界面"); return 1
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    base = parse_base_arg()
    root = tk.Tk()
    try:
        from ctypes import windll
        windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    App(root, base=base)
    root.mainloop()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        import traceback
        p = os.path.join(tempfile.gettempdir(), "qwen3asr_installer_crash.txt")
        try:
            open(p, "w", encoding="utf-8").write(traceback.format_exc())
        except Exception:
            pass
        raise
