"""
Resolve 桥接入口
================
被 Qwen ASR.lua 调用：

  python resolve_bridge.py <参数文件.json>

★ 为什么用参数文件而不是命令行参数？

  **Windows 命令行按 GBK 解读参数，而 Lua 传的是 UTF-8。**
  中文路径（如 C:\\Users\\...\\直播用\\...）会被解析成乱码，
  Python 报 "can't open file"。而且 .bat 文件本身是 ANSI 编码，chcp 也救不了。

  所以：**命令行只传纯 ASCII 的参数文件路径，其余值全部从文件读。**
  JSON 用 UTF-8 写，Python 读出来完全正确（Python 内部是 Unicode）。

参数文件格式（UTF-8 JSON）：
  {
    "audio": "C:/Users/.../123.mp4",   ← 也可写 "文件:路径" 从文件读
    "audio_file": "C:\\HEIBA\\q3\\rt\\audio_path.txt",  ← 优先，从文件读路径
    "srt":    "C:/HEIBA/Qwen字幕工具/字幕输出/Timeline 1.srt",
    "lang":   "Chinese",
    "max_chars": 12,
    "no_gap": false,
    "no_punct": false,
    "prompt": "",
    "status": "C:\\HEIBA\\q3\\rt\\st.txt",
    "model":  "",
    "log":    "C:\\HEIBA\\q3\\rt\\engine.log"
  }
"""
import json
import os
import subprocess
import sys
import threading
import time
import traceback

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from asr_engine import write_srt, list_asr_models, DEFAULT_ASR, _find_model
# ★ `_find_model` 虽然带下划线，但 refresh_manifest 里"一个模型都没扫到"时
#   要用它兜底出默认模型。以前漏了导入 → 那条兜底路径抛 NameError →
#   又被 `except Exception: pass` 吞掉 → models.txt/models.lua 静默不更新，
#   恰好在"没扫到模型"这个最需要兜底的场景失效。
# ★ Engine 故意不在这里 import：它 load() 时才去拿 torch，而 torch 一旦
#   进来就占一大块显存 / 系统页面文件。走常驻服务时本进程根本用不到它，
#   顶层 import 会在不需要的时候平白多占一份资源（见 main 里的延迟导入）。

# ── TXT 文稿 ────────────────────────────────────────────────────────
# 字幕行是被「每行最多 N 字」切断的碎片，直接拿来当文稿没法读。
# 这里把它们拼回去，按句末标点切成【完整短句】，一句一行。
import re as _re

# ★ 断句：句末标点【连同紧随其后的收尾引号/括号】一起算作一句的结尾。
#   只按标点切会把 ” 甩到下一行开头（…能吃吗？ + ”我说：…），
#   反过来无条件合并又会让整段对话糊成上百字的一坨。
#   所以正确做法是切分时就吃掉后面的收尾符号。
_CLOSERS = "”’」』）】》〉］］｝}’"
_SENT_END = "。！？!?…；;，,、"
_SENT_RE = _re.compile(r"[^。！？!?…]*[。！？!?…][" + _CLOSERS + r"]*")


def _merge_broken(lines):
    """兜底：万一还有以收尾符号开头的碎片，并回上一行。"""
    out = []
    for s in lines:
        if out and s and s[0] in _CLOSERS:
            out[-1] += s
        else:
            out.append(s)
    return out


def _ffmpeg_to_wav(src, dst):
    """ffmpeg 转 16k 单声道 WAV（整段）。"""
    try:
        import imageio_ffmpeg
        exe = imageio_ffmpeg.get_ffmpeg_exe()
        cmd = [exe, "-y", "-i", str(src), "-vn", "-ac", "1", "-ar", "16000",
               str(dst)]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode == 0 and os.path.isfile(dst) \
                and os.path.getsize(dst) > 1024:
            return True
        tail = (r.stderr or b"")[-300:]
        if isinstance(tail, bytes):
            tail = tail.decode("utf-8", "replace")
        print("ffmpeg 转码失败：%s" % tail.strip(), file=sys.stderr)
    except Exception as e:
        print("ffmpeg 不可用：%s: %s" % (type(e).__name__, e),
              file=sys.stderr)
    return False


def _audio_fingerprint(path):
    """音频指纹：绝对路径 + 大小 + mtime。文件被替换/重导都算新的。"""
    import hashlib
    st = os.stat(path)
    h = hashlib.md5()
    h.update(os.path.abspath(path).encode("utf-8", "replace"))
    h.update(("%d|%d" % (st.st_size, int(st.st_mtime))).encode("ascii"))
    return h.hexdigest()[:16]


def _prune_cache(cache_dir, log, keep=12, max_bytes=4 << 30):
    """缓存上限：最多 keep 个 / max_bytes 字节，超了删最旧的。"""
    try:
        files = []
        total = 0
        for n in os.listdir(cache_dir):
            p = os.path.join(cache_dir, n)
            try:
                if not os.path.isfile(p):
                    continue
                sz = os.path.getsize(p)
                files.append((os.path.getmtime(p), sz, p))
                total += sz
            except OSError:
                continue
        files.sort()
        while (len(files) > keep or total > max_bytes) and files:
            _, sz, p = files.pop(0)
            try:
                os.remove(p)
                total -= sz
            except OSError:
                break
    except OSError:
        pass


def _prepare_audio(src, cfg, work, log):
    """按需把音频料理成 16k 单声道 WAV，并缓存复用。

    · 源是 wav → 原样返回（soundfile 直读，没有 ffmpeg 开销）
    · 源是视频 → ffmpeg 出 16k WAV，按指纹缓存：
      重复识别同一素材（改改每行字数再跑一次）不再重复抽音频。
    """
    if os.path.splitext(src)[1].lower() == ".wav":
        return src

    try:
        fp = _audio_fingerprint(src)
    except OSError:
        return src
    cache_dir = os.path.join(work, "cache")
    dst = os.path.join(cache_dir, fp + ".wav")
    if os.path.isfile(dst) and os.path.getsize(dst) > 1024:
        log("音频缓存命中：%s" % os.path.basename(dst))
        return dst
    try:
        os.makedirs(cache_dir, exist_ok=True)
    except OSError:
        return src
    # ★ 临时名必须保留 .wav 后缀：ffmpeg 按扩展名猜封装格式，
    #   "<name>.wav.123.tmp" 会被当成未知格式直接报 Invalid argument。
    tmp = dst[:-4] + ".%d.tmp.wav" % os.getpid()
    ok = _ffmpeg_to_wav(src, tmp)
    if not ok:
        try:
            os.remove(tmp)
        except OSError:
            pass
        log("音频预处理失败，按原文件识别")
        return src
    try:
        os.replace(tmp, dst)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return src
    _prune_cache(cache_dir, log)
    log("音频已缓存：%s" % os.path.basename(dst))
    return dst


def write_txt(blocks, path):
    """把所有字幕文本拼成带标点的完整句子，一句一行写到 path。

    ★ 为什么要这个：导出字幕之外，用户常要一份「文稿」用于改稿/存档。
      字幕行本身是被 max_chars 切断的，直接连起来又不分段 ——
      所以先整体拼接，再按句末标点断句。
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    joined = "".join(str(t or "") for (_, _, t) in blocks)
    joined = joined.replace("\n", "").replace("\r", "")

    lines = []
    pos = 0
    for m in _SENT_RE.finditer(joined):
        s = m.group().strip()
        pos = m.end()
        if s:
            lines.append(s)
    tail = joined[pos:].strip()
    if tail:
        # 结尾没有句末标点的残余
        if lines and lines[-1][-1] in _SENT_END:
            lines.append(tail)
        else:
            lines[-1] = (lines[-1] + tail) if lines else tail

    # 句末没标点就补一个（勾选了「句末无标点」时会出现）
    fixed = []
    for s in lines:
        if s and s[-1] not in _SENT_END and s[-1] not in _CLOSERS:
            s += "。"
        fixed.append(s)
    lines = _merge_broken(fixed)

    if not lines and joined.strip():
        lines = [joined.strip()]

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)

LANG_MAP = {
    "Chinese": "Chinese", "English": "English", "Cantonese": "Cantonese",
    "Japanese": "Japanese", "Korean": "Korean", "Auto": "Auto",
}

# 模型清单文件：给 Lua 界面读取用（Lua 无法列目录，避免弹 CMD 窗口）
# ★★ 必须放在【纯 ASCII】目录（_HERE = C:\HEIBA\q3）。
#    原来 Lua 读的是工具安装目录（C:\HEIBA\Qwen字幕工具\models.txt）：
#    ① 那不是 Python 写清单的地方（Python 写 _HERE）→ 两边根本不是同一个文件
#    ② 就算放对了，Windows 的 Lua io.open 走 ANSI 接口，中文路径打不开
#    → 结果就是模型下拉框永远只有硬编码的默认值，用户装了新模型也看不到。
MANIFEST = os.path.join(_HERE, "models.txt")
# ★ 再写一份 Lua chunk：Lua 侧优先 loadfile 它，连 io.open 都不用。
MANIFEST_LUA = os.path.join(_HERE, "models.lua")


def refresh_manifest():
    """把当前可用的模型写成清单文件，供 Lua 读取。

    ★ 必须带【完整路径】：模型可能装在 _MODEL_DIRS 里的任意一个目录，
      只给名字的话 Lua 只能拿它去拼 TOOL_ROOT\\models\\<名字>，拼错就
      静默回退默认模型（用户以为换了模型，其实没换）。
    """
    try:
        items = list_asr_models()
        if not items:
            items = [_find_model(DEFAULT_ASR)]
        names = [p.name for p in items]
        with open(MANIFEST, "w", encoding="utf-8") as f:
            f.write("\n".join(names) + "\n")

        def _q(s):
            return '"%s"' % str(s).replace("\\", "\\\\").replace('"', '\\"')

        # return { { name = "X", path = "C:\\...\\X" }, ... }
        body = ", ".join('{ name = %s, path = %s }' % (_q(p.name), _q(p))
                         for p in items)
        _write_lua_chunk(MANIFEST_LUA, body)
    except Exception:
        pass


def _read_path_from_file(p):
    """从 UTF-8 文本文件读第一行作为路径（避开命令行编码问题）。"""
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.readline().replace("\r", "").replace("\n", "").strip()
    except OSError:
        return ""


# 实际跑起来的模型说明（由 main 填，report 回带到界面）。
# 自定义路径无效时会变成"⚠ …已改用默认 XXX"。
MODEL_NOTE = ""


def _lua_str(s):
    """转成安全的 Lua 字符串字面量（UTF-8 原样写出，Lua 按字节处理）。"""
    out = []
    for ch in str(s if s is not None else ""):
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20:
            out.append("\\%d" % o)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _write_lua_chunk(path, body):
    """把 `return { <body> }` 写成 Lua chunk，原子替换。

    ★ 为什么不用纯文本 / JSON？
      Lua 侧读文件只有 loadfile 是可靠的：
        · io.open 在 Windows 上走 ANSI 接口，中文路径打不开；
          而且 Resolve 的 Lua 沙箱里 io 可能是 nil。
        · loadfile 实测一定可用（AutoSubs 也是用这个"文件邮箱"传数据）。
      格式交给 Lua 引擎自己解析，中文/转义全部不用管。

    ★ 为什么要原子替换（先写 .tmp 再 rename）？
      否则 Lua 可能正好读到写了一半的文件 → loadfile 失败。
    """
    if not path:
        return
    try:
        tmp = path + ".tmp.%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("return {" + body + "}\n")
        os.replace(tmp, path)
    except OSError:
        pass


def load_args(argv):
    """支持两种模式：
       ① python resolve_bridge.py <参数.json>       ← 推荐（Lua 用这个）
       ② python resolve_bridge.py <音频> <srt> ...  ← 兼容旧的命令行方式
    """
    if len(argv) >= 2 and argv[1].lower().endswith(".json"):
        with open(argv[1], "r", encoding="utf-8") as f:
            cfg = json.load(f)
    elif len(argv) >= 9:
        cfg = {
            "audio": argv[1], "srt": argv[2], "lang": argv[3],
            "max_chars": int(argv[4]) if argv[4].isdigit() else 12,
            "no_gap": argv[5] == "1", "no_punct": argv[6] == "1",
            "prompt": argv[7], "status": argv[8],
            "model": argv[9] if len(argv) > 9 else "",
        }
    else:
        raise SystemExit("参数不足：需要 <参数.json> 或旧的 9 参数命令行方式")

    # audio_file 优先（路径从文件读，绕开命令行编码）
    af = cfg.get("audio_file")
    if af and os.path.exists(af):
        real = _read_path_from_file(af)
        if real:
            cfg["audio"] = real
    return cfg


# ══════════════════════════════════════════════════════════════════
# 常驻 ASR 服务（asr_server.py）的客户端
#
# ★ 为什么：模型加载（ASR + Aligner）每次要 6~7 秒。服务常驻后复用，
#   第二次起直接省掉这笔开销。
#
# ★★ 这里只把它当【加速器】：服务不在 / 没就绪 / 中途崩 / 超时，
#    一律返回 None，main() 会照原样在本地加载模型 —— 功能完全不受影响。
# ══════════════════════════════════════════════════════════════════
SRV_WAIT_MAX = 1800      # 单个任务最多等多久（秒）
SRV_HB_FRESH = 25.0      # 心跳超过这么久没更新 = 服务不在
SRV_HB_STALE = 120.0     # 跑到一半心跳断了这么久 = 判定服务已死，回退本地
SRV_ACCEPT_SEC = 90.0    # 下发后超过这么久还没开始干活 = 服务没接住活
SRV_BUSY_WAIT = 120.0    # 服务正忙时最多等它多久（秒），等不到就本地加载
SRV_STUCK_SEC = 600.0    # 干活中但这么久没有一次进度更新 = 卡死

import subprocess as _sp


def srv_state(hb_path):
    """读服务心跳，返回 (ready, model, pid, busy)。

    当前格式（asr_server.write_hb 写的，JSON）：
        {"t": <unix时间戳>, "ready": 0|1, "model": "<路径>",
         "pid": <进程号>, "busy": 0|1}
    ★ 为什么改成 JSON：旧格式是空格分隔的
        <unix时间戳> <ready 0|1> <模型路径> <pid> <busy 0|1>
      而模型路径 ① 可能含空格（用户自定义路径）② 加载前后会被写成空串。
      两种情况都会让 split() 出来的字段整体错位 → int(parts[3]) 失败 →
      pid 变成 0 → 下面 try_server 里的 srv_pid_alive(0) 判"进程已死" →
      删心跳 → 常驻服务被静默废掉，每次都退化成本地加载。
    这里保留旧格式的解析分支，方便新老版本混跑时平滑过渡。
    服务不在（文件没有 / 心跳过期）时返回 (False, None, 0, False)。
    """
    try:
        with open(hb_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
        if raw.startswith("{"):
            d = json.loads(raw)
            t = int(d.get("t") or 0)
            ready = bool(d.get("ready"))
            model = str(d.get("model") or "")
            pid = int(d.get("pid") or 0)
            busy = bool(d.get("busy"))
        else:
            # ── 旧格式（空格分隔），仅用于兼容过渡 ──
            parts = raw.split(None, 4)
            t = int(parts[0])
            ready = len(parts) > 1 and parts[1] == "1"
            model = parts[2].strip() if len(parts) > 2 else ""
            try:
                pid = int(parts[3]) if len(parts) > 3 else 0
            except ValueError:
                pid = 0
            busy = len(parts) > 4 and parts[4].strip().startswith("1")
        if time.time() - t > SRV_HB_FRESH:
            return (False, None, pid, False)
        return (ready, model, pid, busy)
    except Exception:
        return (False, None, 0, False)


def srv_pid_alive(pid, timeout=6.0):
    """进程还在不在。

    ★ 只在【心跳已经停了】之后才调用。正常路径一律不碰它 ——
      tasklist 要启一个子进程，放在每 0.25 秒一轮的轮询里太重了。
    """
    if not pid:
        return False
    try:
        out = _sp.run(["tasklist", "/FI", "PID eq %d" % pid],
                      stdout=_sp.PIPE, stderr=_sp.DEVNULL, timeout=timeout)
        return str(pid) in (out.stdout or b"").decode("utf-8", "replace")
    except Exception:
        return False


def srv_kill(pid, log, wait=12.0):
    """把常驻服务杀掉，并等它真的退出。

    ★★ 这是【必须】的一步，不是可选优化：
        服务的 torch/CUDA 上下文占着一大块显存和系统页面文件。
        不先把它杀干净就回退本地加载，本地这份 torch 连 DLL 都加载不了：
          OSError: [WinError 1455] 页面文件太小 ... cublas64_12.dll
        实测在这种机器上 100% 复现。所以回退 = 先杀服 + 等它释放，再加载。
    """
    if not pid:
        return False
    dead = False
    try:
        _sp.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                stdout=_sp.DEVNULL, stderr=_sp.DEVNULL, timeout=15)
    except Exception:
        pass
    end = time.time() + wait
    while time.time() < end:
        alive = False
        try:
            out = _sp.run(["tasklist", "/FI", "PID eq %d" % pid],
                          stdout=_sp.PIPE, stderr=_sp.DEVNULL, timeout=10)
            alive = str(pid) in (out.stdout or b"").decode("utf-8", "replace")
        except Exception:
            alive = False
        if not alive:
            dead = True
            break
        time.sleep(0.3)
    log("（常驻服务）已停止 pid=%s%s" % (pid, "" if dead else "（未能确认退出）"))
    return dead


def try_server(work, cfg, status_lua, status_file, log):
    """把识别交给常驻服务。成功返回 (blocks, stats)；不可用/失败返回 None。"""
    cmd_path = os.path.join(work, "asr_cmd.json")
    res_path = os.path.join(work, "asr_res.json")
    hb_path = os.path.join(work, "asr_hb.txt")

    # ★★ 上一次的 pid 必须留着：等会儿万一要回退本地加载，
    #    得先用它把服务杀掉释放显存，否则两份 torch 会打架（见 srv_kill）。
    ready, _model, srv_pid, busy = srv_state(hb_path)
    if _model is None and not ready and not srv_pid:
        return None          # 服务压根不在（心跳没有或已过期）

    if not ready:
        # 服务在，但模型还在加载（多半是刚预热完就立刻开始了下一次）。
        # 等它一下 —— 否则本地也要装一份模型，两份一起占显存，
        # 小显存的卡可能直接 OOM。等不到就照旧本地加载。
        dl = time.time() + 15
        while time.time() < dl:
            time.sleep(0.3)
            ready, _m, p, b = srv_state(hb_path)
            if p:
                srv_pid = p
            if ready:
                break
            if not ready and not p:
                break        # 服务没了
        if not ready:
            return None

    # ★★ 进程必须真的活着才能交任务。
    #    服务被 terminate / 崩溃强杀时来不及删心跳文件，会留下一条
    #    「时间戳很新但进程已经没了」的假心跳 —— 认了它就是把任务发给
    #    一个死进程，要干等 SRV_ACCEPT_SEC(90s) 才被超时兜住（实测
    #    多花 90 秒）。一次 tasklist 的代价远比这 90 秒便宜。
    if not srv_pid_alive(srv_pid):
        log("（常驻服务）心跳是旧的（pid=%s 已不存在），改用本地加载"
            % srv_pid)
        try:
            os.remove(hb_path)
        except OSError:
            pass
        return None

    # ★ 服务正忙着（上一次的任务还没跑完）时，【不能】直接覆盖
    #   asr_cmd.json：服务会把新命令当成下一次任务，而旧任务还在跑，
    #   表现为"我点了停止，它还在识别"。
    #   这里等它闲下来（上限 SRV_BUSY_WAIT 秒），等不到就本地加载 ——
    #   本地会另装一份模型占显存，但总比把正在跑的任务顶掉好。
    if busy:
        log("（常驻服务）正忙，等它跑完上一个任务…")
        dl = time.time() + SRV_BUSY_WAIT
        while time.time() < dl:
            time.sleep(0.5)
            r2, _m2, p2, b2 = srv_state(hb_path)
            if not p2 or not srv_pid_alive(p2):
                break                      # 服务没了，走本地
            if not b2:
                break                      # 闲下来了
        else:
            return None
        r3, _m3, p3, b3 = srv_state(hb_path)
        if b3 or not p3:
            log("（常驻服务）等了 %d 秒还在忙，改用本地加载" % SRV_BUSY_WAIT)
            return None

    jid = int(time.time() * 1000) % 1000000000
    job = {
        "id": jid,
        "audio": cfg.get("audio", ""),
        "lang": cfg.get("lang", "Chinese"),
        "prompt": cfg.get("prompt", ""),
        "max_chars": cfg.get("max_chars", 12),
        "no_gap": cfg.get("no_gap", False),
        "no_punct": cfg.get("no_punct", False),
        "strip_all_punct": cfg.get("strip_all_punct", False),
        "model": cfg.get("model", ""),
        "status_lua": status_lua,
        "status_file": status_file,
    }
    try:
        # 先清掉上一次的结果，否则可能读到旧数据直接"秒完成"
        if os.path.exists(res_path):
            os.remove(res_path)
        tmp = cmd_path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(job, f, ensure_ascii=False)
        os.replace(tmp, cmd_path)
    except OSError as e:
        log("（常驻服务）下发任务失败，改用本地加载：%s" % e)
        return None

    log("（常驻服务）已下发任务，复用已加载的模型")
    deadline = time.time() + SRV_WAIT_MAX
    last_hb = time.time()
    sent_at = time.time()
    accepted = False        # 服务有没有真的开始干活（busy=1）
    last_progress = None    # 上一次看到的进度时间戳（status.lua 里的 t）
    last_progress_at = sent_at

    while time.time() < deadline:
        try:
            if os.path.exists(res_path):
                with open(res_path, "r", encoding="utf-8") as f:
                    res = json.load(f)
                if int(res.get("id") or 0) != jid:
                    # 上一个任务的残留，继续等
                    time.sleep(0.2)
                    continue
                if res.get("ok"):
                    global MODEL_NOTE
                    _mn = str(res.get("model_note") or "")
                    if _mn:
                        MODEL_NOTE = _mn
                    blocks = [(float(a), float(b), str(t))
                              for a, b, t in res.get("blocks") or []]
                    return blocks, res.get("stats") or {}
                log("（常驻服务）返回失败：%s —— 改用本地加载"
                    % res.get("err", ""))
                # 服务端自己报错（多半是模型没装好）也要先把它杀掉：
                # 它虽然没干活，但 torch 已经 import 过，显存照样占着。
                srv_kill(srv_pid, log)
                return None
        except (OSError, ValueError, TypeError):
            # 可能正被写（半截 JSON）—— 下轮再读
            pass

        rd, _, p, busy = srv_state(hb_path)
        if p:
            srv_pid = p
        if rd:
            last_hb = time.time()
        elif time.time() - last_hb > SRV_HB_STALE:
            # 心跳彻底停了 —— 先用 pid 分清「真死了」和「活着但停摆」：
            #   进程没了 → 崩了，直接回退
            #   进程还在 → 卡死/换页中，【必须】先杀掉它再回退，
            #              否则本地这份 torch 抢不到显存，注定二次失败
            #              （WinError 1455 就是这么来的）
            if srv_pid_alive(srv_pid):
                log("（常驻服务）进程还在（pid=%s）但心跳已停 %.0fs，判定卡死"
                    % (srv_pid, SRV_HB_STALE))
                srv_kill(srv_pid, log)
            else:
                log("（常驻服务）进程已退出，改用本地加载")
            return None

        if busy:
            accepted = True

        # ── 卡死判定 ─────────────────────────────────────────────
        #  服务的 heartbeat 是独立线程写的，哪怕识别跑飞了它也照跳，
        #  所以【心跳活着 ≠ 任务在推进】。真正要看的是它写进 status.lua
        #  的进度时间戳 t 有没有往前走。
        try:
            if status_lua and os.path.exists(status_lua):
                _m = _re.search(r"\bt\s*=\s*(\d+)",
                                open(status_lua, encoding="utf-8").read())
                if _m and _m.group(1) != last_progress:
                    last_progress = _m.group(1)
                    last_progress_at = time.time()
                    accepted = True
        except OSError:
            pass

        _stall = time.time() - last_progress_at
        if not accepted and _stall > SRV_ACCEPT_SEC:
            log("（常驻服务）下发后 %.0fs 没有开始干活，改用本地加载" % _stall)
            srv_kill(srv_pid, log)
            return None
        if accepted and _stall > SRV_STUCK_SEC:
            log("（常驻服务）%.0fs 没有任何进度更新（疑似卡死），改用本地加载"
                % _stall)
            srv_kill(srv_pid, log)
            return None

        time.sleep(0.25)

    log("（常驻服务）等待超时，改用本地加载")
    srv_kill(srv_pid, log)
    return None


def friendly_error(e):
    """把用户看不懂的底层异常翻成能照着做的中文提示。

    ★ 界面上只有一行状态文字，直接甩 NVIDIA CUDA driver to be installed
      这类原文，用户除了重启电脑没别的事可做。这两类错是实测真出现过的。
    """
    name = type(e).__name__
    raw = "%s: %s" % (name, e)
    msg = str(e)

    if "1455" in msg or "页面文件太小" in msg:
        return ("系统虚拟内存不足，CUDA 加载失败（WinError 1455）。\n"
                "① 关掉占内存的软件后重试；\n"
                "② 或增大虚拟内存：此电脑→属性→高级系统设置→性能【设置】"
                "→高级→虚拟内存【更改】，改到 16GB 以上\n"
                "③ 也可以在字幕工具里改用 smaller 模型降低占用")
    if "out of memory" in msg.lower() and "cuda" in msg.lower():
        return ("显存不足（CUDA out of memory）。\n"
                "先关掉其它占显存的程序，或改用更小的模型后重试")
    if "no cuda" in msg.lower() or "driver" in msg.lower():
        return ("CUDA 不可用：%s\n"
                "请更新 NVIDIA 驱动，或在设置里改用 CPU 模式" % msg)
    if isinstance(e, MemoryError):
        return "系统内存不足，请关掉其它程序后重试"
    return raw


def main():
    if len(sys.argv) < 2:
        print("usage: resolve_bridge.py <args.json>")
        sys.exit(2)

    cfg = load_args(sys.argv)

    audio = str(cfg.get("audio", ""))
    out_srt = str(cfg.get("srt", ""))
    # TXT 文稿路径：不给或为空就不产出（老配置兼容）
    out_txt = str(cfg.get("txt", "") or "").strip()
    if not out_txt and out_srt:
        out_txt = os.path.splitext(out_srt)[0] + ".txt"
    lang = LANG_MAP.get(cfg.get("lang", "Chinese"), "Chinese")
    try:
        max_chars = int(cfg.get("max_chars", 12))
    except (TypeError, ValueError):
        max_chars = 12
    no_gap = bool(cfg.get("no_gap", False))
    no_punct = bool(cfg.get("no_punct", False))
    all_punct = bool(cfg.get("strip_all_punct", False))
    prompt = str(cfg.get("prompt", "") or "")
    status_file = str(cfg.get("status", ""))
    model_path = str(cfg.get("model", "") or "").strip()
    log_file = str(cfg.get("log", "") or "")

    # 进度 / 心跳的 Lua chunk 路径（Lua 侧用 loadfile 读）
    _work = os.path.dirname(status_file) or _HERE
    status_lua = str(cfg.get("status_lua", "") or "") or os.path.join(_work, "status.lua")
    hb_lua = str(cfg.get("hb", "") or "") or os.path.join(_work, "hb.lua")

    def report(pct, count=0, err=""):
        """写进度供 Lua 轮询。

        ★ 两个通道同时写：
          · status.lua → `return {pct=.., count=.., t=..}`，Lua 用 loadfile 读
          · status.txt → "百分比%|条数"，兜底 + 人肉排查用
        ★ 条数也由这里写 —— Lua 打不开中文路径的 srt，没法自己数行。

        ★★★ 血泪教训（务必保持）：
          **识别【中途】的进度绝对不能报 100！**
          原来进度回调是 report(cur*100/tot)，cur 到 tot 时就等于 100，
          而此时 count 还是 0 → Lua 看到 pct=100 就调 Finish()，
          count=0 → 界面显示"未生成字幕"，后续挂字幕轨也永远不会执行。
          所以：
            · 进度一律钳到 99，只有真正写完 SRT 才报 100 + 条数
            · 失败时写 err，让 Lua 能区分"失败"和"没识别到内容"
        """
        pct = int(pct)
        count = int(count)
        body = f"pct = {pct}, count = {count}, t = {int(time.time())}"
        if err:
            body += ", err = " + _lua_str(str(err)[:300])
        # ★ 实际跑的模型（可能和用户填的不一样——路径无效会回退），
        #   带回界面让用户一眼看到，别出现"填了 A 实际跑 B"还蒙在鼓里。
        if MODEL_NOTE:
            body += ", model = " + _lua_str(MODEL_NOTE[:300])
        _write_lua_chunk(status_lua, body)
        if not status_file:
            return
        try:
            with open(status_file, "w", encoding="utf-8") as f:
                f.write(f"{pct}%|{count}")
        except OSError:
            pass

    # ── 心跳：独立线程每 2 秒写一次时间戳 ──
    #   ★ 为什么需要：Lua 侧要判断"引擎是否还活着"。
    #     原来用 io.popen('tasklist') 查进程 —— 既阻塞界面，
    #     又因为脚本是 pythonw 启动的而永远查不到 → 误报"进程已退出"。
    #     心跳是独立线程，模型加载/识别的任何阶段都在跳。
    _hb_stop = threading.Event()

    def _heartbeat():
        while not _hb_stop.is_set():
            _write_lua_chunk(hb_lua, f"t = {int(time.time())}")
            _hb_stop.wait(2.0)

    _write_lua_chunk(hb_lua, f"t = {int(time.time())}")
    threading.Thread(target=_heartbeat, daemon=True).start()

    # 日志同时写文件（Lua 侧看不到 stdout）
    logf = None
    if log_file:
        try:
            os.makedirs(os.path.dirname(log_file), exist_ok=True)
            logf = open(log_file, "a", encoding="utf-8")
        except OSError:
            logf = None

    def log(msg):
        line = str(msg)
        print(line, flush=True)
        if logf:
            try:
                logf.write(line + "\n")
                logf.flush()
            except OSError:
                pass

    try:
        if not audio or not os.path.isfile(audio):
            log(f"错误：找不到音频 {audio}")
            report(100, 0, "找不到音频文件：" + audio)
            sys.exit(3)

        # ── 音频缓存（统一入口）──────────────────────────────────
        #   渲染路径产出的本来就是 wav → 原样进引擎；快速路径的视频素材
        #   在这里抽成 16k WAV 并按指纹缓存，重复识别不再抽。
        audio = _prepare_audio(audio, cfg, _work, log)

        log(f"音频: {audio}")
        # ★ 参数回显：选项"看着没效果"时，先看这行确认值有没有传到引擎。
        log(f"参数: 语言={lang} 每行最多 {max_chars} 字 "
            f"无间隙={'开' if no_gap else '关'} "
            f"去标点={'全部' if all_punct else ('句末' if no_punct else '关')}")
        report(0)
        refresh_manifest()

        # ── ① 优先走常驻服务（模型已加载 → 省掉 6~7 秒）──────────────
        #    不在线 / 没就绪 / 崩了 / 超时 → try_server 返回 None，
        #    自动退回下面的本地加载，结果完全一样，只是慢一点。
        got = None
        try:
            got = try_server(_work, {
                "audio": audio, "lang": lang, "prompt": prompt,
                "max_chars": max_chars, "no_gap": no_gap,
                "no_punct": no_punct, "strip_all_punct": all_punct,
                "model": model_path,
            }, status_lua, status_file, log)
        except Exception as e:
            log(f"（常驻服务）不可用，改用本地加载：{type(e).__name__}: {e}")

        if got is not None:
            blocks, stats = got
        else:
            # ── ② 本地加载（老路径，永远可用）─────────────────────────
            # ★ 延迟 import：torch 只有在这里才需要。走常驻服务时本进程
            #   完全不碰 CUDA —— 少占一份显存，也少一次 DLL 加载失败的机会。
            try:
                from asr_engine import Engine as _Engine
            except Exception as _e:
                log("导入识别引擎失败：%s: %s" % (type(_e).__name__, _e))
                report(100, 0, "导入识别引擎失败：%s" % _e)
                sys.exit(6)

            engine = _Engine(log=log, asr_model=(model_path or None))
            engine.load()
            # 回传实际模型（自定义路径无效时这里会带上 ⚠ 说明）
            if getattr(engine, "model_note", ""):
                global MODEL_NOTE
                MODEL_NOTE = engine.model_note

            blocks, stats = engine.run(
                audio, lang=lang, prompt=prompt, max_chars=max_chars,
                remove_gaps=no_gap, trim_punct=no_punct,
                strip_all_punct=all_punct,
                # ★ 钳到 99：中途绝不允许报 100（否则 Lua 会在 SRT 写出来之前
                #   就判"完成"，count 还是 0 → 显示"未生成字幕"，也不会去挂字幕轨）
                progress=lambda cur, tot: report(
                    min(99, int(cur * 100 / max(1, tot))) if tot else 0)
            )

        if not blocks:
            log("未识别到语音内容")
            report(100, 0, "未识别到语音内容（时间线可能没有声音）")
            sys.exit(0)

        write_srt(blocks, out_srt)

        # ★ 同时产出一份【纯文本文稿】（带标点的完整短句，一句一行）
        #   失败不影响主流程 —— 字幕是主产物，文稿是附赠。
        n_lines = 0
        if out_txt:
            try:
                n_lines = write_txt(blocks, out_txt)
                log(f"文稿：{n_lines} 句 -> {out_txt}")
            except Exception as e:
                log(f"文稿写出失败（不影响字幕）：{type(e).__name__}: {e}")

        report(100, len(blocks))
        log(f"完成：{len(blocks)} 条字幕-> {out_srt}")
        # 常驻服务返回的 stats 可能缺字段，用 .get 兜住，别让日志本身抛异常
        _g = (stats or {}).get
        log("耗时 %.1fs / 音频 %.1fs (RTF %.2f, %s)" % (
            float(_g("elapsed") or 0), float(_g("duration") or 0),
            float(_g("rtf") or 0), _g("device") or "-"))

        # ── 诊断快照（rt\last_run.lua，供「关于」弹窗展示/复制）────
        #   排查"识别怎么又慢了/掉字了"时，先看这里，不用去翻日志文件。
        try:
            _diag = (
                "t = %d, blocks = %d, duration = %.1f, elapsed = %.1f, "
                "rtf = %.2f, device = %s, model = %s, lang = %s, "
                "max_chars = %d, cached = %s"
                % (int(time.time()), len(blocks),
                   float(_g("duration") or 0), float(_g("elapsed") or 0),
                   float(_g("rtf") or 0), _lua_str(str(_g("device") or "-")),
                   _lua_str(MODEL_NOTE or model_path or "默认模型"),
                   _lua_str(str(lang)), int(max_chars),
                   "true" if os.path.dirname(audio) == os.path.join(
                       _work, "cache") else "false"))
            _write_lua_chunk(os.path.join(_work, "last_run.lua"), _diag)
        except Exception:
            pass
        sys.exit(0)

    except SystemExit:
        raise
    except Exception as e:
        log("异常：")
        log(traceback.format_exc())
        try:
            report(100, 0, "识别异常：%s" % friendly_error(e))
        except Exception:
            pass
        sys.exit(1)
    finally:
        try:
            _hb_stop.set()
        except Exception:
            pass
        if logf:
            try:
                logf.close()
            except OSError:
                pass


if __name__ == "__main__":
    main()