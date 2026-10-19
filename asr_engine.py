"""
Qwen3-ASR 字幕生成工具（独立版）
=================================
基于 Qwen3-ASR-0.6B + Qwen3-ForcedAligner-0.6B 的本地字幕生成工具。

特点：
- 不依赖 DaVinci Resolve，任何软件都能用
- 图形界面，拖拽文件即可
- GPU 加速（RTX 50 系列 / 任意 CUDA 卡）
- 全本地运行，音频不上传

技术栈：
- 语音识别：Qwen3ASRForConditionalGeneration
- 时间对齐：Qwen3ASRForTokenClassification（与 ASR 同架构）
- 语音活动检测：silero-vad（经 torch.hub）或能量阈值
"""

import os
import re
import sys
import json
import time
import threading
import subprocess
import unicodedata
import queue
import tempfile
from pathlib import Path

# ── 路径配置（按优先级依次查找）────────────────────────────────────────
# ★ 开发机：模型在「引擎目录的上一级 \models」（例如 C:\HEIBA\models）。
# ★ 安装器默认把模型放在「引擎目录的上一级 \Qwen字幕工具\models」
#   （例如 D:\HEIBA\Qwen字幕工具\models）。这两种都要认 —— 少了相对形式的
#   后一条，装到非 C 盘时 _HERE_DIR.parent 只拼得出 BASE\models，
#   模型直接找不到，识别必失败（以前只有 C:\HEIBA 的绝对兜底能救）。
# ★ 其余条目是历史布局的兜底：工具整体挪盘后仍能自动找到模型，不用改路径。
_HERE_DIR = Path(__file__).resolve().parent
_MODEL_DIRS = [
    _HERE_DIR.parent / "models",                        # ★ 开发机统一位置
    _HERE_DIR.parent / "Qwen字幕工具" / "models",       # ★ 安装器默认落点
    _HERE_DIR / "models",                               # 工具自身目录下
    Path(r"C:\HEIBA\models"),                           # 统一位置的绝对兜底
    Path(r"C:\HEIBA\Qwen字幕工具\models"),               # 旧布局（兼容）
]

# ── 是否启用 ForcedAligner 词语级时间对齐 ──────────────────────────────
# ★ 开启后，字幕时间戳由 Qwen3-ForcedAligner 做「词语级」对齐，取代原先
#   按字数比例估算的做法（distribute_timing）。
#   代价：加载多占约 2.5GB 显存、首次多 6~7 秒。
#   兼容性：只有 ALIGNER_LANGS 里列的语言能做对齐；遇到不支持的语种、
#   模型缺失、加载失败，或对齐质量不达标且重试无效时，一律自动降级回
#   按字数比例估算 —— 功能不会中断，只是精度回到老水平。
USE_ALIGNER = True

# ForcedAligner 支持的语言（对应 transformers 的 FORCED_ALIGNER_LANGUAGES）
ALIGNER_LANGS = frozenset({
    "Chinese", "English", "Cantonese", "French", "German",
    "Italian", "Japanese", "Korean", "Portuguese", "Russian", "Spanish",
})

# 界面上的「自动识别」。★ 必须规范化为 None：transformers 的
# resolve_language() 只接受语言代码或全名，传字符串 "Auto" 会直接抛
# ValueError（"Unsupported language: 'Auto'"）。
_AUTO_LANGS = frozenset({"auto", "自动", "自动识别", "自动检测"})


def normalize_language(lang):
    """把界面传来的语言值规范化；「自动识别」返回 None，交给模型自行检测。"""
    if lang is None:
        return None
    s = str(lang).strip()
    if not s or s.lower() in _AUTO_LANGS:
        return None
    return s


def _find_model(name):
    for d in _MODEL_DIRS:
        p = d / name
        if p.exists():
            return p
    return _MODEL_DIRS[0] / name


DEFAULT_ASR = "Qwen3-ASR-0.6B-hf"
DEFAULT_ALIGNER = "Qwen3-ForcedAligner-0.6B-hf"


def list_asr_models(base_dir=None):
    """列出可用的 ASR 模型目录（排除 Aligner）"""
    out = []
    dirs = [Path(base_dir)] if base_dir else _MODEL_DIRS
    seen = set()
    for d in dirs:
        if not d.exists():
            continue
        for p in sorted(d.iterdir()):
            if not p.is_dir() or p.name in seen:
                continue
            if not (p / "config.json").exists():
                continue
            low = p.name.lower()
            if "aligner" in low:
                continue
            seen.add(p.name)
            out.append(p)
    return out


def find_aligner(asr_path=None):
    """找配对的时间对齐模型：优先同目录，其次全局搜索"""
    candidates = []
    if asr_path:
        candidates.append(Path(asr_path).parent)
    candidates.extend(_MODEL_DIRS)
    for d in candidates:
        if not d.exists():
            continue
        for p in sorted(d.iterdir()):
            if p.is_dir() and "aligner" in p.name.lower() and (p / "config.json").exists():
                return p
    return _MODEL_DIRS[0] / DEFAULT_ALIGNER


def check_asr_dir(path):
    """校验「自定义模型路径」能不能用，返回 (ok, 人话原因)。

    ★ 为什么单独抽出来：以前路径不对时 resolve_models 直接【静默回退】到
      默认模型，日志一个字都不说。用户填了 D:\\models\\Qwen3-ASR-1.7B-hf，
      界面回显也显示这个路径，结果跑的其实还是 0.6B —— 跟「字数限制永远
      12」是同一类"看着生效其实没有"的坑。现在把原因说清楚。
    """
    p = (path or "").strip()
    if not p:
        return (False, "留空")
    try:
        cand = Path(p)
    except Exception:
        return (False, "路径格式不对：%s" % p)
    if not cand.exists():
        return (False, "路径不存在：%s" % p)
    if not cand.is_dir():
        return (False, "不是文件夹（要给模型目录，不是文件）：%s" % p)
    if not (cand / "config.json").exists():
        return (False, "目录里没有 config.json，不是有效的模型目录：%s" % p)
    return (True, "")


def resolve_models(asr_override=None):
    """解析出实际使用的 (ASR 模型, Aligner 模型)

    自定义路径无效时**回退默认模型**。是否回退由 check_asr_dir() 判定，
    调用方（Engine / bridge）负责把它讲给用户听。
    """
    asr = None
    if asr_override:
        ok, _why = check_asr_dir(asr_override)
        if ok:
            asr = Path(asr_override)
    if asr is None:
        asr = _find_model(DEFAULT_ASR)
    return asr, find_aligner(asr)


ASR_MODEL = _find_model(DEFAULT_ASR)
ALIGNER_MODEL = _find_model(DEFAULT_ALIGNER)

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mkv", ".avi", ".flv", ".wmv", ".mpg", ".mpeg", ".webm", ".ts"}

LANGUAGES = {
    "Chinese": "中文", "English": "English", "Auto": "自动识别",
    "Cantonese": "粤语", "Japanese": "日语", "Korean": "韩语",
    "French": "Français", "German": "Deutsch", "Spanish": "Español",
    "Russian": "Русский", "Italian": "Italiano", "Portuguese": "Português",
}


# ── 音频加载 ────────────────────────────────────────────────────────────
def extract_audio(path, sr=16000):
    """从视频/音频提取单声道 16k 波形"""
    import soundfile as sf
    import numpy as np

    ext = Path(path).suffix.lower()
    if ext in VIDEO_EXT or ext not in {".wav", ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus"}:
        try:
            import imageio_ffmpeg
            exe = imageio_ffmpeg.get_ffmpeg_exe()
            tmp = Path(tempfile.gettempdir()) / f"qwen3asr_{os.getpid()}.wav"
            subprocess.run(
                [exe, "-y", "-i", str(path), "-vn", "-ac", "1", "-ar", str(sr), str(tmp)],
                capture_output=True, check=True
            )
            # ★ try/finally：sf.read 失败时（文件损坏/磁盘满）
            #   以前会把临时 wav 留在 %TEMP% 里，每次失败漏一个，
            #   几十 GB 的音频漏几次就把临时目录撑满。
            try:
                data, _ = sf.read(str(tmp), dtype="float32")
            finally:
                try:
                    tmp.unlink()
                except OSError:
                    pass
            return data, sr
        except subprocess.CalledProcessError as e:
            # ★ 原来是 except: pass，然后 fallthrough 去 sf.read(视频文件)，
            #   报出来的是"soundfile 打不开 .mp4"这种误导信息。真实原因
            #   （ffmpeg 不在 / 解码失败 / 磁盘满）必须带到上层。
            tail = (e.stderr or b"")[-400:]
            if isinstance(tail, bytes):
                tail = tail.decode("utf-8", "replace")
            raise RuntimeError("ffmpeg 提取音频失败：%s\n%s" % (path, tail.strip()))
        except Exception as e:
            # imageio_ffmpeg 缺失之类：也别静默，明确失败原因
            raise RuntimeError("音频提取失败（%s）：%s: %s"
                               % (path, type(e).__name__, e))

    data, file_sr = sf.read(str(path), dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    if file_sr != sr:
        import numpy as np
        n = int(round(len(data) * sr / file_sr))
        data = np.interp(
            np.linspace(0, len(data) - 1, n, dtype=np.float64),
            np.arange(len(data), dtype=np.float64),
            data
        ).astype("float32")
    return data, sr


# ── 语音活动检测（能量 + 过零率，无需额外依赖）────────────────────────────
def _valley_cut(energy, voiced, lo, hi, ideal, win, search=3.0, min_seg=2.0):
    """在 ideal ± search 秒内找「谷点」下刀，返回切点秒数；找不到返回 ideal

    为什么不在 ideal 处硬切：理想切点往往落在词语中间，硬切会把一个词
    拦腰截断，后半窗识别出来是个残词。谷点（能量局部最小、且最好落在
    非语音帧上）基本都在词间停顿里，切过去前后两窗都能识别完整。
    """
    import numpy as np

    a = max(int((lo + min_seg) / win), int((ideal - search) / win), 0)
    b = min(int((hi - min_seg) / win), int((ideal + search) / win),
            len(energy) - 1)
    if b <= a:
        return ideal
    seg_e = energy[a:b + 1]
    unvoiced = np.where(~voiced[a:b + 1])[0]
    # 非语音帧里挑能量最低的；一个都没有（整窗都在说话）就挑全局最低
    cand = unvoiced if len(unvoiced) else np.arange(len(seg_e))
    best = cand[int(np.argmin(seg_e[cand]))]
    pos = (a + best) * win
    return min(max(pos, lo + min_seg), hi - min_seg)


def detect_speech(audio, sr, win_ms=30, thresh_ratio=0.08, min_speech=0.6,
                  min_gap=0.6, pad=0.5, max_len=35.0):
    """基于短时能量的 VAD，返回 [(start_sec, end_sec), ...]

    参数偏保守：宁可把静音也包进来，也不要把一句话切断
    （Qwen3-ASR 需要足够上下文，断得太碎识别质量会下降）。

    ★ 超长片段不再按 max_len 硬切，而是在理想切点附近找【谷点】下刀
      （见 _valley_cut）；pad 0.15→0.5s、上限 25→35s，给模型更多上下文。
    """
    import numpy as np

    win = int(sr * win_ms / 1000)
    if len(audio) < win:
        return [(0.0, len(audio) / sr)]

    n = len(audio) // win
    frames = audio[: n * win].reshape(n, win)
    energy = np.sqrt((frames ** 2).mean(axis=1) + 1e-12)

    peak = np.percentile(energy, 95)
    if peak <= 1e-6:
        return [(0.0, len(audio) / sr)]
    thresh = max(peak * thresh_ratio, 1e-4)
    voiced = energy > thresh

    segs, i = [], 0
    while i < n:
        if voiced[i]:
            j = i
            while j < n and voiced[j]:
                j += 1
            segs.append([i * win / sr, j * win / sr])
            i = j
        else:
            i += 1

    merged = []
    for s in segs:
        if merged and s[0] - merged[-1][1] < min_gap:
            merged[-1][1] = s[1]
        else:
            merged.append(s)

    # 超长片段再切开：谷点切分（保留 pad 重叠上下文，避免边界截词）
    final = []
    for s, e in merged:
        if e - s <= max_len:
            final.append((max(0.0, s - pad), min(len(audio) / sr, e + pad)))
            continue
        cur = s
        while cur < e:
            nxt = min(e, cur + max_len)
            if nxt < e:   # 尾巴上不足一个窗长时剩下的全拿走，不再找谷点
                nxt = _valley_cut(energy, voiced, cur, e, nxt, win)
            final.append((max(0.0, cur - pad), min(len(audio) / sr, nxt + pad)))
            cur = nxt

    out = [(s, e) for s, e in final if e - s >= min_speech]
    return out or [(0.0, len(audio) / sr)]


# ── 断句（按标点和长度切分文本）─────────────────────────────────────────
END_PUNCT = "。！？!?；;…"
PAUSE_PUNCT = "，,、：:"
# 收尾引号 / 括号 —— 口语里常用引号或书名号把整句包起来，
# 句末标点之后往往还剩一个收尾符号，去标点时要连带吃掉。
CLOSERS = "”’」』）】》〉」\"']"
TRAIL_PUNCT = END_PUNCT + PAUSE_PUNCT + CLOSERS


def _dw(s):
    """显示宽度：CJK 全角字符算 2 列，其余算 1 列

    字幕行宽要看【占多少列】而不是【多少个字符】：同样 12 个单位，
    汉字占 24 列、英文只占 12 列。界面上的「每行最多 12 字」按
    12 个汉字的视觉宽度理解，英文因此能放约 24 个字符。
    """
    w = 0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
    return w


def _is_wide(ch):
    """单个字符是不是全角（CJK 等）。用于判断合并两段时要不要补空格。"""
    return unicodedata.east_asian_width(ch) in ("F", "W")


# 数字 + 常见量词视为整体，断行时不允许拆开（"3.14" 不能变成 "3." + "14"，
# "12 个" 不能变成 "12" + "个"）。单位表覆盖字幕口语里 95% 的场合。
_NUM_UNIT_RE = re.compile(
    r"\d+(?:[.,]\d+)+"                      # 3.14 / 1,000.50
    r"|\d+\s*(?:个|种|条|只|份|秒|分钟|小时|点|次|位|名|块|片|句|字|行"
    r"|年|月|日|天|号|版|集|章|节|段|台|部|首|幅|张|把|件|套|双|对"
    r"|群|批|堆|串|滴|帧|万|亿|元|块|米|公里|斤|公斤|升|度|折)"
    r"|\d+")


def _spans(s):
    """把字符串切成原子：标点 / 数字单位整体 / 其余单字。

    只有原子【边界】才是合法断点，原子内部不断 —— 这是数字保护的实现。
    """
    spans, i, n = [], 0, len(s)
    while i < n:
        ch = s[i]
        if ch in END_PUNCT or ch in PAUSE_PUNCT or ch in CLOSERS:
            spans.append((i, i + 1))
            i += 1
            continue
        m = _NUM_UNIT_RE.match(s, i)
        if m:
            spans.append((i, m.end()))
            i = m.end()
            continue
        spans.append((i, i + 1))
        i += 1
    return spans


def _allowed_cuts(s):
    """合法断点集合：每个原子边界 + 每个标点之后"""
    spans = _spans(s)
    cuts = set()
    for k, (a, b) in enumerate(spans):
        if s[a] in END_PUNCT or s[a] in PAUSE_PUNCT or s[a] in CLOSERS:
            cuts.add(b)
        if k + 1 < len(spans):
            cuts.add(spans[k + 1][0])
    return cuts


def _wrap_line(s, limit):
    """按显示宽度把一行折到 limit 列以内，尽量在标点/原子边界断"""
    if _dw(s) <= limit:
        return [s]
    cuts = _allowed_cuts(s)
    lines, start, w, i, n = [], 0, 0, 0, len(s)
    while i < n:
        cw = _dw(s[i])
        if w + cw > limit:
            p = i
            while p > start and p not in cuts:
                p -= 1
            if p <= start:            # 一个断点都没有 → 硬切
                # ★ 必须保证 p > start：否则 start 原地不动、s[i] 也不消费，
                #   下一轮状态完全一样 → 死循环、lines 无限增长。
                #   limit >= 2 时 i 必然 > start（w 累加过才会超限），
                #   但 limit <= 0 时第一轮就 i == start，这里兜一下。
                p = max(i, start + 1)
            lines.append(s[start:p].strip())
            start, w = p, 0
            continue                 # s[i] 不消费，下一行重新计宽
        w += cw
        i += 1
    if start < n:
        lines.append(s[start:].strip())
    return [x for x in lines if x]


def split_sentences(text, max_chars=12, min_chars=None):
    """把文本切成字幕行，按【显示宽度】严格不超过 max_chars×2 列

    策略：
      1. 按句末标点断句
      2. 超宽的行按显示宽度折行（优先在标点/原子边界断，数字单位不拆）
      3. 过窄的行与下一行合并 —— 合并后仍不得超宽
    """
    # ★ 先夹住 max_chars：limit = max_chars*2 一旦 <= 0，_wrap_line 里
    #   每个字符的宽度都 > limit，会一路走进"一个断点都没有"的硬切分支，
    #   而那个分支原来不保证指针前进 → 死循环 + lines 无限增长（内存爆掉）。
    #   Lua 的「开始」路径已把字数夹在 4~200，但命令行参数
    #   （`int(argv[4]) if argv[4].isdigit()` 会把 "0" 传成 0）和
    #   args.json 等入口没有夹，这里做最后一道防线。
    try:
        max_chars = max(1, int(max_chars))
    except (TypeError, ValueError):
        max_chars = 12
    if min_chars is None:
        min_chars = max(4, max_chars // 2)
    limit = max_chars * 2
    min_w = min_chars * 2

    # 1) 按句末标点初步断句（超长行也先粗断，交给第 2 步细折）
    raw, buf = [], ""
    for ch in text:
        buf += ch
        if ch in END_PUNCT:
            raw.append(buf.strip())
            buf = ""
        elif _dw(buf) >= limit * 2:
            raw.append(buf.strip())
            buf = ""
    if buf.strip():
        raw.append(buf.strip())

    # 2) 超宽行按显示宽度折行
    chunks = []
    for s in raw:
        chunks.extend(_wrap_line(s, limit))

    # 3) 过窄的合并（合并后仍不得超过 limit）
    merged = []
    for s in chunks:
        if merged:
            prev = merged[-1]
            # ★ 空格分词语言相接时要补一个空格：前面各步都做过 .strip()，
            #   直接相加会把词间空格吃掉 —— "OK." + "Go now." 变成
            #   "OK.Go now."。中文/日文之间不需要空格，所以只在【两侧
            #   都不是全角字符】时才补（全角判定与 _dw 同一套标准）。
            sep = " " if (prev and s
                          and not _is_wide(prev[-1])
                          and not _is_wide(s[0])) else ""
            if _dw(prev) < min_w and _dw(prev) + _dw(sep) + _dw(s) <= limit:
                merged[-1] = prev + sep + s
                continue
        merged.append(s)

    # 4) 去掉行首标点（硬切容易把逗号甩到下一行开头）
    cleaned = []
    for s in merged:
        s = s.lstrip(PAUSE_PUNCT)
        s = s.strip()
        if s:
            cleaned.append(s)

    return cleaned


def strip_tail_punct(sents):
    """把每句【行尾】的标点连同收尾引号一起去掉，空句直接丢弃。"""
    out = []
    for s in sents:
        s = s.rstrip(TRAIL_PUNCT).strip()
        if s:
            out.append(s)
    return out


# 去标点用的完整集合：句末 + 停顿 + 收尾引号，再加上成对符号与连接符。
# 只在"去除标点符号"开关打开时使用（会把行内标点也删掉）。
# ★ 引号必须【左右都收】。CLOSERS 里只有右引号（” ’ 等），左引号 “ ‘ 不在
#   任何一张表里 —— 实测结果就是「去除标点符号」勾上以后，SRT 里仍残留
#   `“我用人参能吃吗` 这种以左引号开头的行（右引号被删掉了，只剩半边）。
ALL_PUNCT = (TRAIL_PUNCT
             + "“”‘’〝〞﹁﹂｢｣"          # 中英文引号：左右都要
             + "（）()「」『』《》〈〉【】〔〕［］[]{}"
             + "—－–~～·・…、／/\\|`^&*#@$%+=<>￥$")
_DROP_TABLE = str.maketrans("", "", ALL_PUNCT)


def drop_all_punct(sents):
    """把行内行尾的标点全部删掉（保留空格与字母数字）。

    ★ 断句仍然在标点上做（split_sentences 先切好），这里只是最后把标点抹掉，
    所以不会把一整段话糊成一行。
    """
    out = []
    for s in sents:
        s = s.translate(_DROP_TABLE).strip()
        if s:
            out.append(s)
    return out


# 无间隙时，最多把一条字幕往后延长多少秒。
# 遇到超长静音（比如中场休息 30 秒）就不硬撑 —— 否则一个字幕会在屏幕上
# 挂很久。正常口播的句间空档都远小于这个值，所以效果依然是"没有空隙"。
GAP_MAX_EXTEND = 6.0


def fill_gaps(blocks, min_dur=0.04, max_extend=GAP_MAX_EXTEND):
    """字幕无间隙：把每条的【结束时间】延长到下一条开始之前。

    ★★★ 绝对不能移动【开始时间】！早先的实现是把整条字幕往前挤，
    总时长被压缩（实测 158 条字幕从 212.6 秒被压到 185.9 秒），
    于是越往后偏得越多 —— 用户看到的就是"字幕和音频完全对不上"。
    现在只动结束时间：字幕始终跟着音频走，只是中途不消失。
    """
    out = []
    n = len(blocks)
    for i, (st, en, tx) in enumerate(blocks):
        if i + 1 < n:
            nxt = blocks[i + 1][0]
            # 留 0.04 秒的极短间隔：两段完全首尾相接（尤其是时间戳相同）
            # 在某些播放器/轨道上会被当成重叠处理。
            if nxt - 0.04 > en and (nxt - en) <= max_extend:
                en = nxt - 0.04
        if en < st + min_dur:
            en = st + min_dur
        out.append((st, en, tx))
    return out


# ── 时间戳估算（按字数比例分配）─────────────────────────────────────────
def distribute_timing(sentences, seg_start, seg_end, gap=0.08):
    """在片段内按字数比例分配时间戳（降级路径）

    ★ ForcedAligner 可用且对齐合格时不会走这里；只有语种不支持、模型
      缺失、加载失败或对齐质量不达标时才退回本函数。
    """
    if not sentences:
        return []
    weights = [max(1, len(re.sub(r"[^\w\u4e00-\u9fff]", "", s))) for s in sentences]
    total = sum(weights)
    span = max(0.1, seg_end - seg_start - gap * (len(sentences) - 1))

    out, t = [], seg_start
    for s, w in zip(sentences, weights):
        dur = span * w / total
        out.append((t, t + dur, s))
        t += dur + gap
    return out


# ── 词语级对齐（ForcedAligner）───────────────────────────────────────────
# 对齐质量判定的两个阈值：覆盖率下限、允许的最大词间空洞（秒）
ALIGN_MIN_COVERAGE = 0.35
ALIGN_MAX_GAP = 3.0


def parse_asr_output(processor, raw):
    """解析识别原始输出 → (纯文本, 检测到的语言或 None)

    Qwen3-ASR 的输出格式是 `language <LANG><asr_text>转写文本`：
      · 手动指定语言时，语言前缀由 processor 预填，模型只生成转写文本；
      · 自动检测时（language=None），前缀由模型自己生成，必须剥掉 ——
        否则会把 "language Chinese" 这类内容原样写进字幕。
    这里直接调用 processor 自带的官方解析，避免自己造轮子出错。
    """
    if not raw:
        return "", None
    try:
        parsed = processor.parse_output(raw)
    except Exception:
        return raw.strip(), None
    if isinstance(parsed, list):
        parsed = parsed[0] if parsed else {}
    if not isinstance(parsed, dict):
        return raw.strip(), None
    text = (parsed.get("transcription") or "").strip()
    lang = parsed.get("language") or None
    # ★ 解析成功就以解析结果为准。模型遇到空音频会输出
    #   `language None<asr_text>`，官方解析给出的是空转写；此处绝不能
    #   回退成原文，否则这句标记会被当成字幕写进 SRT。
    return text, lang


def check_alignment(words, dur):
    """检查对齐质量 → (合格?, 原因)

    三类问题判为不合格，触发「拆分重试」，重试仍不合格才降级为比例估算：
      · 时间戳异常（非有限值 / 结束早于开始）—— 模型偶发乱序
      · 覆盖率过低 —— 说明整体漂移，开头或结尾没对上
      · 出现过大空洞 —— 说明中间一段没对齐上
    """
    import math

    if not words:
        return False, "没有对齐结果"
    for _t, s, e in words:
        if not (math.isfinite(s) and math.isfinite(e)) or e < s:
            return False, "时间戳异常"
    covered = words[-1][2] - words[0][1]
    if dur > 0 and covered < dur * ALIGN_MIN_COVERAGE:
        return False, "覆盖率仅 %.0f%%" % (covered / dur * 100)
    worst = 0.0
    for i in range(len(words) - 1):
        worst = max(worst, words[i + 1][1] - words[i][2])
    if worst > ALIGN_MAX_GAP:
        return False, "存在 %.1f 秒空洞" % worst
    return True, ""


def enforce_monotonic(blocks, min_gap=0.0):
    """保证时间戳单调不减，避免相邻字幕行时间倒退。"""
    out, prev_end = [], -1.0
    for st, en, tx in blocks:
        if st < prev_end + min_gap:
            st = prev_end + min_gap
        if en < st + 0.04:
            en = st + 0.04
        out.append((st, en, tx))
        prev_end = en
    return out


def assign_times_by_words(sentences, words, seg_start):
    """把词语级时间戳分配到字幕行

    sentences 是已经切好行的文本，words 是
    [(词, 相对开始秒, 相对结束秒), ...]（时间相对本片段）。
    做法：把每行的字符区间按比例映射到词序列上，取覆盖该行的第一个词
    的开始时间与最后一个词的结束时间。用「按比例映射」而不是精确字符
    对齐，是因为切行时会去掉标点/空格，行长与词长不可能完全一致；比例
    映射对这点差异是容忍的，而得到的时间戳仍来自真实的音频对齐。
    """
    if not sentences:
        return []
    if not words:
        return []

    line_lens = [max(1, len(s)) for s in sentences]
    word_lens = [max(1, len(w[0])) for w in words]
    total_line = float(sum(line_lens))
    total_word = float(sum(word_lens))

    bounds, acc = [], 0.0
    for L in word_lens:
        bounds.append((acc, acc + L))
        acc += L

    def index_at(ratio):
        target = ratio * total_word
        for i, (_a, b) in enumerate(bounds):
            if target <= b or i == len(bounds) - 1:
                return i
        return len(bounds) - 1

    out, cum = [], 0.0
    for s, L in zip(sentences, line_lens):
        a = cum / total_line
        cum += L
        b = cum / total_line
        i0, i1 = index_at(a), index_at(b)
        if i1 < i0:
            i1 = i0
        st = seg_start + words[i0][1]
        en = seg_start + words[i1][2]
        if en < st + 0.04:
            en = st + 0.04
        out.append((st, en, s))
    return enforce_monotonic(out)


# ── SRT 输出 ────────────────────────────────────────────────────────────
def fmt_ts(x):
    """秒 → SRT 时间码 HH:MM:SS,mmm

    ★ 按【总毫秒】算，不要先拆时/分/秒再各自进位：
      x=59.9997 时拆法会得到 s=59, ms=1000 → 只把秒+1 变成 60，
      输出 "HH:MM:60,000" —— 非法时间码，部分播放器和 Resolve 直接解析失败。
      总毫秒法一次除到位，天然不会出现 60。
    """
    total = int(round(max(0.0, float(x)) * 1000))
    h, rem = divmod(total, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write_srt(blocks, path):
    p = Path(path)
    if p.parent and not p.parent.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for i, (st, en, tx) in enumerate(blocks, 1):
        lines.append(f"{i}\n{fmt_ts(st)} --> {fmt_ts(en)}\n{tx}\n")
    # ★ 必须原子写：识别还在写 SRT 时，subs_io / land_subtitle 可能已经在读
    #   （worker 用 Popen 拉起脚本，彼此不等待）—— 直接 write_text 会让
    #   对方读到半截文件，导入一堆残句。和 subs_io / worker 的写法保持一致。
    tmp = p.with_name(p.name + ".%d.tmp" % os.getpid())
    tmp.write_text("\n".join(lines), encoding="utf-8-sig")
    os.replace(tmp, p)


# ── 复读 / 异常输出防御 ────────────────────────────────────────────────
class _RepeatStopper:
    """transformers stopping_criteria：盯生成 token 的「周期重复」

    复读是 Qwen3-ASR 在长静音/纯噪声段的典型崩溃模式（"呃呃呃呃…" 一路
    生成到 1024 token 上限，白白烧掉几十秒）。每 32 个新 token 检查一次：
    最近 2p 个 token 若与更早的 p 个完全相同（p∈[8,64]），判定复读，
    立即停生成。纯 Python，不依赖 transformers 的 StoppingCriteria 基类，
    老版本 transformers 也能用（callable 即可）。
    """

    def __init__(self, min_new=96, check_every=32,
                 min_period=8, max_period=64):
        self.min_new = min_new
        self.check_every = check_every
        self.min_period = min_period
        self.max_period = max_period
        self._base = None
        self._ticks = 0

    def __call__(self, input_ids, scores, **kw):
        n = input_ids.shape[-1]
        if self._base is None:
            self._base = n
        self._ticks += 1
        if n - self._base < self.min_new or self._ticks % self.check_every:
            return False
        seq = input_ids[0].tolist()
        for p in range(self.min_period, min(self.max_period, n // 2) + 1):
            if seq[-2 * p:-p] == seq[-p:]:
                return True
        return False


def _looks_anomalous(text):
    """识别结果异常检测：复读残渣 / 协议标记泄漏 / 单字符统治

    transcribe_segment 解码后先过这一关；命中就作废本段（返回空），
    由 _process_segment 走拆分重试，而不是把 "啊啊啊啊啊" 写进字幕。
    """
    t = text.strip()
    if not t:
        return True
    if "asr_text" in t or "<|" in t or "|>" in t:
        return True
    body = t.replace(" ", "").replace("　", "")
    if len(body) < 2:
        return True
    from collections import Counter
    top, cnt = Counter(body).most_common(1)[0]
    if cnt / len(body) >= 0.9:
        return True
    for i in range(len(body) - 9):
        unit = body[i:i + 2]
        if body[i:i + 10] == unit * 5:   # 同一 2 字串连续 5 遍
            return True
    return False


# ── 核心引擎 ────────────────────────────────────────────────────────────
class Engine:
    def __init__(self, log=print, asr_model=None):
        self.log = log
        self.asr_proc = None
        self.asr_model = None
        self.align_proc = None
        self.align_model = None
        self.align_timestamp_token_id = 0
        self.device = "cpu"
        self.dtype = None          # load() 里按 cuda/cpu 定；float32 兜底
        self.asr_path, self.aligner_path = resolve_models(asr_model)

        # 对齐统计：跑完在日志里报一次，便于判断对齐到底有没有生效
        self.aligned_segments = 0   # 成功走词语级对齐的片段数
        self.retried_segments = 0   # 因质量不合格触发拆分重试的片段数
        self.fallback_segments = 0  # 最终降级为按字数比例估算的片段数

        # ★ 实际用的是哪个模型、以及为什么 —— 一路带回给界面。
        #   自定义路径无效时这里会记下原因，bridge 把它写进状态文件，
        #   用户就能看见"我填的路径没用上，实际跑的是 XXX"，而不是干瞪眼。
        self.model_note = ""
        if (asr_model or "").strip():
            ok, why = check_asr_dir(asr_model)
            if ok:
                self.model_note = str(self.asr_path)
            else:
                self.model_note = ("⚠ 自定义模型路径无效（%s），已改用默认 %s"
                                   % (why, self.asr_path.name))

    def load(self):
        import torch
        from transformers import (
            AutoProcessor,
            Qwen3ASRForConditionalGeneration,
            Qwen3ASRForTokenClassification,
        )

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        # ★ dtype 必须存下来给 _to_device 用。以前那里【硬编码 bfloat16】，
        #   CPU 上大量算子不支持 bf16，generate() 直接 RuntimeError ——
        #   实测 CPU 模式 5 个片段全挂、0 条字幕。CUDA 才用 bf16。
        self.dtype = torch.bfloat16 if self.device == "cuda" else torch.float32
        dtype = self.dtype
        self.log(f"设备: {self.device.upper()}" +
                 (f"  {torch.cuda.get_device_name(0)}" if self.device == "cuda" else ""))

        self.log("识别模型: %s" % self.asr_path.name)
        self.log("模型目录: %s" % self.asr_path)
        if self.model_note:
            self.log(self.model_note)
        t0 = time.time()
        self.asr_proc = AutoProcessor.from_pretrained(str(self.asr_path))
        self.asr_model = Qwen3ASRForConditionalGeneration.from_pretrained(
            str(self.asr_path), dtype=dtype).to(self.device).eval()
        self.log(f"  完成 ({time.time() - t0:.1f}s)")

        # ★ 时间对齐模型：字幕时间戳由它做词语级对齐（见文件顶部 USE_ALIGNER）。
        #   加载失败会自动跳过，run() 里退回按字数比例估算，功能不中断。
        self.align_model = None
        if USE_ALIGNER:
            self.log(f"对齐模型: {self.aligner_path.name}")
            t0 = time.time()
            try:
                self.align_proc = AutoProcessor.from_pretrained(str(self.aligner_path))
                self.align_model = Qwen3ASRForTokenClassification.from_pretrained(
                    str(self.aligner_path), dtype=dtype).to(self.device).eval()
                # 解时间戳要用到；不同版本可能取不到该字段，取不到就留 0
                self.align_timestamp_token_id = int(
                    getattr(self.align_model.config, "timestamp_token_id", 0) or 0)
                self.log(f"  完成 ({time.time() - t0:.1f}s)")
            except Exception as e:
                self.align_model = None
                self.log(f"  跳过（将用比例估算时间轴）: {type(e).__name__}")
        else:
            self.log("对齐模型: 已关闭（按字数比例估算时间轴）")

    def _to_device(self, inputs):
        import torch
        # ★ 用 load() 定下的 dtype，不能写死 bfloat16（CPU 上会 RuntimeError）
        dtype = getattr(self, "dtype", None) or torch.float32
        out = {}
        for k, v in inputs.items():
            if hasattr(v, "to"):
                out[k] = v.to(self.device, dtype) if v.is_floating_point() else v.to(self.device)
            else:
                out[k] = v
        return out

    def transcribe_segment(self, audio, sr, lang, prompt=""):
        """识别一个片段 → (纯文本, 检测到的语言或 None)

        ★ lang 先过 normalize_language()：界面上的「自动识别」在这里变成
          None —— 这才是 transformers 认可的自动检测写法（传 "Auto" 会抛
          ValueError: Unsupported language: 'Auto'）。
        ★ 自动检测时模型会自己输出 `language XXX<asr_text>` 前缀，用官方
          parse_output() 剥掉，否则前缀会被原样写进字幕。
        """
        language = normalize_language(lang)
        inputs = self.asr_proc.apply_transcription_request(
            audio=audio, language=[language], prompt=[prompt])
        inputs = self._to_device(inputs)
        stopper = _RepeatStopper()
        try:
            out = self.asr_model.generate(**inputs, max_new_tokens=1024,
                                          stopping_criteria=[stopper])
        except TypeError:
            # 老版本 transformers 不认 stopping_criteria 关键字时的退路
            out = self.asr_model.generate(**inputs, max_new_tokens=1024)
        gen = out[:, inputs["input_ids"].shape[1]:]
        texts = self.asr_proc.tokenizer.batch_decode(gen, skip_special_tokens=True)
        raw = (texts[0] if texts else "").strip()
        if _looks_anomalous(raw):
            self.log("  检测到复读/异常输出（%s…），本段作废" % raw[:24])
            return "", None
        return parse_asr_output(self.asr_proc, raw)

    def align_segment(self, audio, text, lang):
        """对本片段做词语级对齐 → [(词, 开始秒, 结束秒), ...]；失败返回 None

        走官方三步：prepare_forced_aligner_inputs → 模型 forward →
        decode_forced_alignment。返回的时间是【相对本片段】的秒数。
        """
        if self.align_model is None or self.align_proc is None:
            return None
        if not text.strip() or lang not in ALIGNER_LANGS:
            return None
        import torch
        try:
            with torch.inference_mode():
                inputs, word_lists = self.align_proc.prepare_forced_aligner_inputs(
                    audio=audio, transcript=text, language=lang)
                inputs = self._to_device(inputs)
                out = self.align_model(**inputs)
            logits = out.logits if hasattr(out, "logits") else out[0]
            items = self.align_proc.decode_forced_alignment(
                logits, inputs["input_ids"], word_lists,
                timestamp_token_id=self.align_timestamp_token_id)
            words = items[0] if items else []
            return [(w.get("text", ""), float(w["start_time"]), float(w["end_time"]))
                    for w in words
                    if "start_time" in w and "end_time" in w]
        except Exception as e:
            self.log("  对齐失败（本段改用比例估算）: %s: %s"
                     % (type(e).__name__, str(e)[:160]))
            return None

    def _process_segment(self, audio, sr, st, en, lang, prompt, max_chars,
                         strip_all_punct, trim_punct, depth=0):
        """处理单个语音片段 → 字幕块列表

        优先走 ForcedAligner 词语级对齐。对齐质量不合格时，把片段
        【一分为二】重新识别并对齐（即「空洞检测重试」，只重试一层），
        两半都拿不到合格结果才降级为按字数比例估算。
        """
        seg = audio[int(st * sr): int(en * sr)]
        if len(seg) < sr * 0.1:
            return []
        seg_dur = len(seg) / sr

        text, detected = self.transcribe_segment(seg, sr, lang, prompt)
        if not text:
            # 空结果（含复读/异常作废）：也走一次拆分重试 —— 两半各自
            # 有机会出正常结果；重试仍空才真正放弃这个片段。
            if depth == 0 and (en - st) >= 1.0:
                self.retried_segments += 1
                self.log("  片段 %.1f~%.1fs 无有效文本，拆分重试" % (st, en))
                mid = (st + en) / 2.0
                parts = []
                for a, b in ((st, mid), (mid, en)):
                    parts.extend(self._process_segment(
                        audio, sr, a, b, lang, prompt, max_chars,
                        strip_all_punct, trim_punct, depth + 1))
                return parts
            return []

        # 对齐用的语言：自动检测时以模型报出来的为准（它才准）
        align_lang = normalize_language(lang)
        if detected in ALIGNER_LANGS:
            align_lang = detected

        sents = split_sentences(text, max_chars)
        if strip_all_punct:
            sents = drop_all_punct(sents)
        elif trim_punct:
            sents = strip_tail_punct(sents)
        if not sents:
            return []

        if USE_ALIGNER and align_lang in ALIGNER_LANGS:
            words = self.align_segment(seg, text, align_lang)
            ok, why = check_alignment(words, seg_dur) if words else (False, "没有结果")
            if ok:
                self.aligned_segments += 1
                return assign_times_by_words(sents, words, st)

            # ── 空洞检测重试：一分为二，各自重新识别 + 对齐 ──
            if depth == 0 and (en - st) >= 1.0:
                self.retried_segments += 1
                self.log("  片段 %.1f~%.1fs 对齐不合格（%s），拆分重试" % (st, en, why))
                mid = (st + en) / 2.0
                parts = []
                for a, b in ((st, mid), (mid, en)):
                    parts.extend(self._process_segment(
                        audio, sr, a, b, lang, prompt, max_chars,
                        strip_all_punct, trim_punct, depth + 1))
                if parts:
                    return parts
            else:
                self.log("  片段 %.1f~%.1fs 对齐不合格（%s），改用比例估算" % (st, en, why))

        self.fallback_segments += 1
        return distribute_timing(sents, st, en)

    def run(self, path, lang="Chinese", prompt="", max_chars=12,
            remove_gaps=False, trim_punct=False, strip_all_punct=False,
            progress=None):
        import torch

        t_start = time.time()
        audio, sr = extract_audio(path)
        dur = len(audio) / sr
        self.log(f"音频时长 {dur:.1f} 秒")

        segs = detect_speech(audio, sr)
        self.log(f"检测到 {len(segs)} 个语音片段")

        blocks = []
        ctx = ""          # 跨窗上下文粘滞：前一窗已接受文本的尾部
        CTX_CHARS = 120
        for idx, (st, en) in enumerate(segs, 1):
            if progress:
                progress(idx, len(segs))
            # 把上一窗的文本尾部拼进 prompt：模型看到前文，跨窗处的用词、
            # 人名、数字写法才能保持一致（否则同一名字在两窗里两种写法）。
            seg_prompt = prompt
            if ctx:
                seg_prompt = (prompt + " " if prompt else "") + ctx
            try:
                blocks.extend(self._process_segment(
                    audio, sr, st, en, lang, seg_prompt, max_chars,
                    strip_all_punct, trim_punct))
            except Exception as e:
                # ★ 只打 type(e).__name__ 会把真正的错误信息吞掉。
                #   CPU 上 5 个片段全挂时只显示"RuntimeError"，根本没法排查。
                self.log(f"  片段 {idx} 失败: {type(e).__name__}: {e}"[:300])
                continue
            # 更新粘滞上下文（失败片段沿用上一窗的，不更新）
            if blocks:
                ctx = str(blocks[-1][2]).strip()[-CTX_CHARS:]

        if USE_ALIGNER:
            self.log("对齐结果：%d 段词语级对齐，%d 段拆分重试，%d 段降级为比例估算"
                     % (self.aligned_segments, self.retried_segments,
                        self.fallback_segments))

        # ★ 兜底：绝不能出现空字幕块（Resolve 里会显示一个空的字幕 Box）。
        #   极短片段偶尔会被识别成一串纯标点，切完句就被清掉了，但时间戳已经
        #   排好 —— 实测 121 条里就有 2 条这种空块，一起写进 SRT 会造成脏数据。
        bad = [b for b in blocks if not str(b[2]).strip()]
        if bad:
            self.log("丢弃 %d 个空字幕块（原始文本只剩标点）" % len(bad))
            blocks = [b for b in blocks if str(b[2]).strip()]

        if remove_gaps and blocks:
            # ★★ 以前这里写成 `for b in blocks: b = (...)` —— 循环变量 b 只是
            #    元组的一个副本，改完丢掉，blocks 一行没动 ⇒ "字幕无间隙"
            #    勾了等于没勾。改成真正重建列表。
            # ★★★ 但"重建"必须是【延长结束时间】，不能是【前移开始时间】：
            #    后者把总时长压短（212.6s → 185.9s），越往后偏得越多。
            before = blocks[-1][1]
            shown = sum(e - s for s, e, _ in blocks)
            blocks = fill_gaps(blocks)
            self.log(
                "无间隙：显示区间 %.1fs → %.1fs，末尾 %.1fs 未变"
                "（只拉长结束时间，开始时间一律不动 → 始终与音频同步）"
                % (shown, sum(e - s for s, e, _ in blocks), before))

        elapsed = time.time() - t_start
        rtf = elapsed / dur if dur > 0 else 0
        self.log(f"完成 {len(blocks)} 条字幕，耗时 {elapsed:.1f}s（实时系数 {rtf:.2f}）")
        return blocks, {"duration": dur, "elapsed": elapsed, "rtf": rtf,
                        "device": self.device, "segments": len(segs)}
