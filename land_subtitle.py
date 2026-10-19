# -*- coding: utf-8 -*-
"""把识别出的 SRT 落到 DaVinci Resolve 时间线的【字幕轨】，并导入媒体池。

用法:
    land_subtitle.py <config.json>

config (UTF-8 JSON):
{
  "srt":     "C:\\HEIBA\\Qwen字幕工具\\字幕输出\\Timeline 1.srt",
  "media":   "C:\\Users\\...\\123.mp4",     -- 可选；给了就在它旁边也放一份 srt
  "out_lua": "C:\\HEIBA\\q3\\rt\\land.lua"
}

输出 out_lua（Lua chunk，供 Resolve 侧 loadfile 读取）：
    return { ok=true, placed=121, total=121, track=1, offset=0,
             sidecar=[[...]], item=[[...]], err=[[]] }

★★★★ 血泪教训（务必保持）：
  1. 字幕媒体项给 AppendToTimeline 【绝对不能】传 startFrame / endFrame，
     也不传 mediaType —— 实测：传 startFrame/endFrame 会把 Resolve 当场打崩
     （崩过两次）；传 mediaType 则字幕直接落不上（字幕轨为空）。
     字幕只传 { mediaPoolItem, trackIndex, recordFrame }。
  2. 只删除「来源媒体项名与本文件同名」的字幕轨项，
     绝不按名字去删媒体池里任何「时间线」类型的项
     （曾因此误删用户的时间线）。

★★★ 字幕落轨位置的唯一解（本版核心，实测结论）：
  AppendToTimeline 对【字幕】是纯追加：recordFrame 被忽略，落点恒等于
  「时间线现有内容的末尾」；而且 trackIndex 也被忽略（永远落到 st1）。
  实测数据：时间线上有视频 0~12759 时，无论 trackIndex 传 1 还是 2、
  无论目标轨是否为空，字幕都落在 12764。
  更关键的是：删掉视频后 GetEndFrame 仍是 12759 —— 时间线长度一旦撑开
  就【永远不归零】（切时间线、切页面、SaveProject 都无效）。

  → 唯一能让字幕落在正确位置的办法：在【全新空时间线】上落（长度=0）。

  于是流程变成：
    ① 新建一条空时间线（不碰用户原时间线）
    ② 先落字幕（此时长度=0 → 落点 = SRT 自身时间码）★
    ③ 再用 mediaType + recordFrame 把原时间线的素材精确复制进来
       （视频 mediaType=1、音频 mediaType=2；实测这两个都能精确定位）
  顺序不能反：先放素材的话长度就不是 0 了，字幕又会跑到末尾。

  素材若不是从第 0 帧开始，则先把 SRT 时间码整体 +起始帧秒数，
  生成「偏移版 SRT」再落 —— 偏移是正向的，可行（负偏移做不到）。
"""
import json
import os
import re
import shutil
import sys
import traceback

API = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting"
# ★ 兼容更多安装位置（含 Studio 版、D 盘 Program Files），换机器也能自动找到
LIB_CANDIDATES = [
    r"D:\DaVinci Resolve\fusionscript.dll",
    r"C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll",
    r"C:\Program Files\Blackmagic Design\DaVinci Resolve\Fusion\fusionscript.dll",
    r"C:\Program Files\Blackmagic Design\DaVinci Resolve Studio\fusionscript.dll",
    r"D:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll",
]


def find_lib():
    for p in LIB_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def connect():
    """连接正在运行的 Resolve（外部脚本）。失败返回 None。"""
    lib = find_lib()
    if not lib:
        return None
    os.environ["RESOLVE_SCRIPT_API"] = API
    os.environ["RESOLVE_SCRIPT_LIB"] = lib
    mods = os.path.join(API, "Modules")
    if mods not in sys.path:
        sys.path.insert(0, mods)
    try:
        import DaVinciResolveScript as dvr
        return dvr.scriptapp("Resolve")
    except Exception:
        return None


def lua_str(s):
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


def write_lua(path, d):
    if not path:
        return
    d = d or {}
    lines = [
        "return {",
        "  ok = %s," % ("true" if d.get("ok") else "false"),
        "  placed = %d," % int(d.get("placed") or 0),
        "  total = %d," % int(d.get("total") or 0),
        "  track = %d," % int(d.get("track") or 0),
        "  replaced = %d," % int(d.get("replaced") or 0),
        "  offset = %d," % int(d.get("offset") or 0),
        "  sidecar = %s," % lua_str(d.get("sidecar")),
        "  item = %s," % lua_str(d.get("item")),
        "  new_timeline = %s," % lua_str(d.get("new_timeline")),
        "  first = %d," % int(d.get("first") or 0),
        "  clips = %d," % int(d.get("clips") or 0),
        "  err = %s," % lua_str(d.get("err")),
        "}",
    ]
    text = "\n".join(lines) + "\n"
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
    except OSError:
        pass
    tmp = path + ".tmp.%d.tmp" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        except OSError:
            pass


def copy_sidecar(srt, media):
    """在源素材旁边放一份同名 srt，方便用户直接找到。返回目标路径或空串。"""
    if not media:
        return ""
    mdir = os.path.dirname(media)
    if not mdir or not os.path.isdir(mdir):
        return ""
    base = os.path.splitext(os.path.basename(media))[0]
    dst = os.path.join(mdir, base + ".srt")
    if os.path.abspath(dst) == os.path.abspath(srt):
        return dst
    shutil.copyfile(srt, dst)
    return dst


SUFFIX = " · 字幕"


def fmt_ts(sec):
    """秒 → SRT 时间码 HH:MM:SS,mmm"""
    if sec < 0:
        sec = 0.0
    total = int(round(sec * 1000))
    h = total // 3600000
    m = (total % 3600000) // 60000
    s = (total % 60000) // 1000
    ms = total % 1000
    return "%02d:%02d:%02d,%03d" % (h, m, s, ms)


_TS_RE = re.compile(r"(\d{2}):(\d{2}):(\d{2}),(\d{3})")


def shift_srt(src_path, dst_path, delta_sec):
    """把 SRT 的所有时间码整体平移 delta_sec 秒，写到 dst_path。

    ★ 为什么需要：字幕只能落在「空时间线」的第 0 帧起算，而素材在时间线上
      未必从第 0 帧开始。把时间码提前加上素材的起始偏移，落上去就正好对齐。
      只能加不能减（负时间码不合法），好在素材起始帧 >= 0。
    """
    with open(src_path, encoding="utf-8-sig") as f:
        text = f.read()
    if abs(delta_sec) < 1e-6:
        with open(dst_path, "w", encoding="utf-8") as f:
            f.write(text)
        return dst_path

    def parse(m):
        return (int(m.group(1)) * 3600 + int(m.group(2)) * 60
                + int(m.group(3)) + int(m.group(4)) / 1000.0)

    def repl(m):
        return fmt_ts(parse(m) + delta_sec)

    out = _TS_RE.sub(repl, text)
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(out)
    return dst_path


def collect_clips(tl):
    """收集时间线上所有视频/音频片段，供精确复制。"""
    clips = []
    for kind, mt in (("video", 1), ("audio", 2)):
        try:
            n = tl.GetTrackCount(kind) or 0
        except Exception:
            n = 0
        for i in range(1, n + 1):
            try:
                items = tl.GetItemListInTrack(kind, i) or []
            except Exception:
                items = []
            for it in items:
                try:
                    mi = it.GetMediaPoolItem()
                except Exception:
                    mi = None
                if not mi:
                    continue
                try:
                    ss = it.GetSourceStartFrame()
                except Exception:
                    ss = 0
                try:
                    se = it.GetSourceEndFrame()
                except Exception:
                    se = 0
                try:
                    st = int(round(float(it.GetStart() or 0)))
                except Exception:
                    st = 0
                try:
                    en = int(round(float(it.GetEnd() or 0)))
                except Exception:
                    en = 0
                if en <= st and se > ss:
                    en = st + (se - ss)      # GetEnd 拿不到时按源长度估
                clips.append({
                    "kind": kind, "mt": mt, "track": i, "mi": mi,
                    "ss": ss, "se": se, "start": st, "end": en,
                    "speed": _clip_speed(it),
                })
    return clips


def _clip_speed(it):
    """片段速度（1.0 = 常速）。区间裁剪换算源帧偏移要用。"""
    try:
        v = it.GetSpeed()
    except Exception:
        return 1.0
    if isinstance(v, dict):
        p = v.get("Percentage")
        return float(p) / 100.0 if p else 1.0
    try:
        fv = float(v)
    except (TypeError, ValueError):
        return 1.0
    return fv / 100.0 if fv > 2.0 else fv


def ensure_tracks(tl, kind, need, cache=None):
    """确保时间线有 need 条 kind 轨。

    ★ cache：GetTrackCount 是一次跨进程 API 调用，复制几十个片段时
      每个片段都查一遍会明显拖慢落轨。这里把"确认过已有 N 条"记下来，
      同一个 kind 只查一次，之后靠自己累加。
    """
    if cache is None:
        cache = {}
    have = cache.get(kind)
    if have is None:
        try:
            have = tl.GetTrackCount(kind) or 0
        except Exception:
            have = 0
    for _ in range(need - have):
        try:
            if not tl.AddTrack(kind):
                break
            have += 1
        except Exception:
            break
    cache[kind] = have
    return have


def find_offset(tl, media):
    """让字幕跟时间线上的素材对齐 —— 取该素材在时间线上的【起始帧】。

    为什么要这个：SRT 内部时间是从 0 开始的。如果素材不是从时间线第 0 帧
    开始（比如前面还有别的片段），直接按 recordFrame=0 落轨就会整体偏掉。
    用素材自己的起始帧当落轨位置，字幕就和音频严格同步。

    ★ 只在 video / audio 轨里找，字幕轨/生成器轨一律不碰。
    ★ 21.1 上没有 GetStartFrame，只有 GetStart()（返回 float 帧号）。
    """
    base = ""
    if media:
        base = os.path.splitext(os.path.basename(media))[0].lower()

    fallback = 0
    for kind in ("video", "audio"):
        try:
            n = tl.GetTrackCount(kind) or 0
        except Exception:
            n = 0
        for i in range(1, n + 1):
            try:
                items = tl.GetItemListInTrack(kind, i) or []
            except Exception:
                items = []
            for it in items:
                try:
                    mi = it.GetMediaPoolItem()
                except Exception:
                    mi = None
                if not mi:
                    continue
                try:
                    nm = (mi.GetName() or "").lower()
                except Exception:
                    nm = ""
                try:
                    fp = (mi.GetClipProperty() or {}).get("File Path") or ""
                except Exception:
                    fp = ""
                fn = os.path.basename(fp).lower()
                # ★ 子串匹配是坑：素材 123.mp4 会命中 1234.mp4 / my123.mp4 /
                #   123_bak.mov，取到错误片段的起始帧 → 整条字幕时间轴整体
                #   偏移，而且完全不报错。所以分两轮：
                #   第一轮只认精确同名（先扫 video 再扫 audio），
                #   扫不到再拿子串兜底，且取时间线上【最早】出现的那个。
                if base and (base == nm or base == fn):
                    try:
                        st = it.GetStart()
                    except Exception:
                        st = 0
                    try:
                        return int(round(float(st or 0)))
                    except Exception:
                        return 0
                if base and not fallback and (base in nm or base in fn):
                    try:
                        st = it.GetStart()
                    except Exception:
                        st = 0
                    try:
                        fallback = int(round(float(st or 0)))
                    except Exception:
                        fallback = 0
    return fallback


# ★ Type 是【本地化字符串】：中文 Resolve 上是「字幕」，英文上是「Subtitle」。
#   只认中文的话，英文版上永远匹配不到 → 每次导入都往媒体池里堆一个新项，
#   跑几趟之后媒体池一屏同名字幕。这里两套判据都上。
_SUBTITLE_TYPES = {"字幕", "字幕文件", "subtitle", "subtitles", "caption"}


def _is_subtitle_clip(c, srt_path):
    """媒体池里的这一项，是不是"我们要替换掉的旧字幕"。"""
    try:
        props = c.GetClipProperty() or {}
    except Exception:
        props = {}
    if not isinstance(props, dict):
        props = {}
    t = str(props.get("Type") or props.get("type") or "").strip().lower()
    if t and (t in _SUBTITLE_TYPES or "subtitle" in t or t in ("字幕",)):
        return True
    # 跟语言无关的判据：来源文件就是这个 SRT
    fp = str(props.get("File Path") or props.get("Original File Path") or "")
    if fp and srt_path:
        try:
            return os.path.abspath(fp) == os.path.abspath(srt_path)
        except OSError:
            return False
    return False


def import_to_pool(mp, srt_path):
    """把 SRT 导入媒体池，返回媒体项。

    ★ 删旧项时必须同时匹配【名字】和【字幕类型】——
      只按名字删会误删同名的时间线（时间线在媒体池里也是一个项，吃过亏）。
    """
    base = os.path.splitext(os.path.basename(srt_path))[0]
    root = mp.GetRootFolder()
    stale = []
    # ★ 要连子文件夹一起扫：只在根文件夹里找旧字幕的话，
    #   用户把字幕拖进过某个 bin，再次导入就会在根目录再堆一份同名的，
    #   媒体池里出现两个"123.srt"，导入时间线时还不知道会挑哪个。
    folders = [root]
    try:
        # ★ 方法名必须是 GetSubFolderList()：Resolve 的 Folder 对象没有
        #   GetSubFolders()，写错会抛异常、被下面的 except 吞掉，
        #   于是"连子文件夹一起扫"静默失效（子文件夹里的字幕扫不到）。
        for sub in (root.GetSubFolderList() or []):
            if sub is not None:
                folders.append(sub)
    except Exception:
        pass
    for fd in folders:
        try:
            clips = fd.GetClipList() or []
        except Exception:
            continue
        for c in clips:
            try:
                if (c.GetName() or "").strip() == base \
                        and _is_subtitle_clip(c, srt_path):
                    stale.append(c)
            except Exception:
                pass
    if stale:
        try:
            mp.DeleteClips(stale)
        except Exception:
            pass

    lst = mp.ImportMedia([srt_path])
    item = lst[0] if lst else None
    if not item:
        raise RuntimeError("导入字幕到媒体池失败")
    return item, base


def main():
    out_lua = ""
    res = {"ok": False, "placed": 0, "total": 0, "track": 0, "replaced": 0,
           "offset": 0, "sidecar": "", "item": "", "err": "",
           "new_timeline": "", "first": 0, "clips": 0}
    try:
        if len(sys.argv) < 2:
            raise RuntimeError("缺少参数：config.json")
        with open(sys.argv[1], encoding="utf-8") as f:
            cfg = json.load(f)

        srt = str(cfg.get("srt") or "")
        media = str(cfg.get("media") or "")
        out_lua = str(cfg.get("out_lua") or "")
        # ★ mode = media  → 只导入媒体池 + 素材旁副本（识别完自动做）
        #   mode = timeline → 完整落轨：新建时间线 + 挂字幕轨（点按钮才做）
        mode = str(cfg.get("mode") or "timeline").lower()

        if not srt or not os.path.exists(srt):
            raise RuntimeError("找不到字幕文件：" + srt)

        # ── ① 在源素材旁边放一份（失败不影响主流程）──────────────
        try:
            res["sidecar"] = copy_sidecar(srt, media)
        except Exception as e:
            res["err"] = "旁边副本失败：%s" % e

        # ── ② 连接 Resolve ──────────────────────────────────────
        r = connect()
        if not r:
            raise RuntimeError(
                "无法连接 DaVinci Resolve。请确认 Resolve 正在运行，且 "
                "首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络")

        proj = r.GetProjectManager().GetCurrentProject()
        if not proj:
            raise RuntimeError("取不到当前工程")
        mp = proj.GetMediaPool()

        # ── ②b 只导媒体池（识别完成就自动做，不动时间线）──────────
        # ★ 放在取时间线【之前】：这一步根本不需要时间线，
        #   以前放在后面，用户停在媒体池/其它页面时会平白报
        #   "当前没有打开的时间线"，自动入库直接失败。
        if mode == "media":
            item, base = import_to_pool(mp, srt)
            res["item"] = (item.GetName() or base).strip()
            res["placed"] = 0
            res["ok"] = True
            write_lua(out_lua, res)
            print(json.dumps(res, ensure_ascii=False))
            sys.exit(0)

        tl = proj.GetCurrentTimeline()
        if not tl:
            raise RuntimeError("当前没有打开的时间线")

        # ── ③ 选定目标时间线 ────────────────────────────────────
        #   ★ 时间线长度不为 0 时，字幕必然被追加到末尾（不可控），
        #     所以必须换一条全新的空时间线。原时间线全程不动。
        src_tl = tl
        try:
            end_frame = int(tl.GetEndFrame() or 0)
        except Exception:
            end_frame = 0

        dst = tl
        new_name = ""
        clips = []
        if end_frame > 0:
            # ★ 去掉已有后缀再拼，否则重复点击会变成
            #   "Timeline 1 · 字幕" → "Timeline 1 · 字幕 · 字幕" ...
            cur_name = tl.GetName() or "Timeline"
            base_name = cur_name
            while base_name.endswith(SUFFIX):
                base_name = base_name[: -len(SUFFIX)]

            # ★ 源时间线要取【原始】那条（不带后缀的），这样即使当前已经停在
            #   字幕版时间线上，重复点击也仍然基于原素材重建，结果稳定。
            src_tl = tl
            try:
                for i in range(1, proj.GetTimelineCount() + 1):
                    t = proj.GetTimelineByIndex(i)
                    if t is not None and t.GetName() == base_name:
                        src_tl = t
                        break
            except Exception:
                pass

            new_name = base_name + SUFFIX
            # 收集原片段（要在切走之前收）
            clips = collect_clips(src_tl)
            # 删掉上一次生成的同名时间线（精确匹配名字，不动别的）
            try:
                for i in range(proj.GetTimelineCount(), 0, -1):
                    t = proj.GetTimelineByIndex(i)
                    if t is not None and t.GetName() == new_name:
                        mp.DeleteTimelines([t])
            except Exception:
                pass
            dst = mp.CreateEmptyTimeline(new_name)
            if not dst:
                raise RuntimeError("创建字幕时间线失败")
            proj.SetCurrentTimeline(dst)
            try:
                dst.SetSetting("timelineFrameRate",
                               tl.GetSetting("timelineFrameRate"))
            except Exception:
                pass
        res["new_timeline"] = new_name

        # ── ④ 素材在源时间线上的起始帧 → 字幕整体后移这么多 ──────
        offset = find_offset(src_tl, media)
        res["offset"] = offset

        # ── ⑤ 生成偏移版 SRT 并导入媒体池 ───────────────────────
        base = os.path.splitext(os.path.basename(srt))[0]
        work = os.path.dirname(out_lua) or "."
        fps = 60.0
        try:
            fps = float(dst.GetSetting("timelineFrameRate") or 60) or 60.0
        except Exception:
            pass
        land_srt = srt
        if offset > 0:
            land_srt = os.path.join(work, base + ".srt")
            shift_srt(srt, land_srt, offset / fps)

        item, base = import_to_pool(mp, land_srt)
        res["item"] = (item.GetName() or base).strip()

        # ── ⑥ 落字幕 ★★ 必须在放素材之前（此时时间线长度还是 0）──
        if (dst.GetTrackCount("subtitle") or 0) == 0:
            dst.AddTrack("subtitle")
        track = 1
        res["track"] = track

        old = dst.GetItemListInTrack("subtitle", track) or []
        if old:
            try:
                dst.DeleteClips(old, False)
                res["replaced"] = len(old)
            except Exception:
                pass

        # ★ 只传这三个键：多传 startFrame/endFrame 会崩，多传 mediaType 落不上
        #   recordFrame = 0：SRT 时间从 0 开始，偏移已由上面的 land_srt 处理
        mp.AppendToTimeline([{
            "mediaPoolItem": item,
            "trackIndex": track,
            "recordFrame": 0,
        }])

        # ── ⑦ 再把原时间线的素材精确复制进来 ────────────────────
        #   视频 mediaType=1、音频 mediaType=2 —— 这两个 recordFrame 都生效。
        if clips:
            tcache = {}
            for c in clips:
                ensure_tracks(dst, c["kind"], c["track"], tcache)

            def _clip_item(c):
                return {
                    "mediaPoolItem": c["mi"],
                    "mediaType": c["mt"],
                    "startFrame": c["ss"],
                    "endFrame": c["se"],
                    "recordFrame": c["start"],
                    "trackIndex": c["track"],
                }

            copied, failed = 0, 0
            # ★ 先试一次批量 AppendToTimeline（单次 IPC）：几百个片段时
            #   逐条调用每条都是一次跨进程往返，批量能把落轨从几十秒压到几秒。
            #   批量里任何一条参数不轨都会整体失败，所以用 try 包住，
            #   失败自动回退逐条（老路数，稳）。
            try:
                mp.AppendToTimeline([_clip_item(c) for c in clips])
                copied, failed = len(clips), 0
                res["batch"] = True
                # 批量成功也要回读数条数：AppendToTimeline 的返回值不反映
                # 实际落了几条，静默丢片段的话字幕会和画面对不上。
                try:
                    got = 0
                    for kind in ("video", "audio"):
                        for ti in range(1, (dst.GetTrackCount(kind) or 0) + 1):
                            got += len(dst.GetItemListInTrack(kind, ti) or [])
                    if got != len(clips):
                        res["clips_missing"] = len(clips) - got
                except Exception:
                    pass
            except Exception as e:
                res["batch"] = False
                res["batch_err"] = type(e).__name__
                for c in clips:
                    try:
                        mp.AppendToTimeline([_clip_item(c)])
                        copied += 1
                    except Exception as e2:
                        # ★ 不能再 except: pass —— 素材少复制几条，
                        #   字幕就和画面对不上，而回读只校验字幕轨，
                        #   用户看到"成功"却不知道素材丢了。
                        failed += 1
                        if failed <= 3:
                            res["clip_err"] = (res.get("clip_err", "")
                                               + "%s; " % type(e2).__name__)
            res["clips"] = copied
            res["clips_failed"] = failed
            if failed:
                res["err"] = "有 %d/%d 个素材片段没能复制过去" % (failed, len(clips))

        # ── ⑧ 回读确认（AppendToTimeline 的返回值不反映实际条数）──
        after = dst.GetItemListInTrack("subtitle", track) or []
        if not after:
            raise RuntimeError("字幕轨上没有出现字幕，落轨失败")
        res["placed"] = len(after)
        res["total"] = len(after)
        res["first"] = int(after[0].GetStart() or 0)
        res["ok"] = True

    except Exception as e:
        res["ok"] = False
        res["err"] = "%s: %s" % (type(e).__name__, e)
        res["trace"] = traceback.format_exc()[-600:]

    write_lua(out_lua, res)
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0 if res.get("ok") else 3)


if __name__ == "__main__":
    main()
