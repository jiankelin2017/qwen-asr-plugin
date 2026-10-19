"""从外部读取 Resolve 时间线的音频源文件信息。

由 Qwen ASR.lua 调用（第一步），输出 JSON 到指定文件：
  {
    "ok": true,
    "items": [
      {"path": "...", "name": "...", "startFrame": 0, "speed": 1.0,
       "sourceStart": 0, "sourceEnd": 5528, "altered": false}
    ],
    "timeline": "Timeline 1",
    "fps": 60.0,
    "hint": "单片段且未裁剪 → 可直接识别"
  }

为什么用 Python 而不是在 Lua 里做：
  · Lua 里 GetStartFrame 等方法名/返回结构踩过多次坑，且异常被静默吞掉
  · Python 侧异常能捕获并写进 JSON，Lua 只需读文件
  · Python 的 dict/None 判断更可靠

用法：
  python timeline_source.py <输出json路径>
"""
import json
import os
import sys

API_DIR = r"C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Developer\Scripting"

# ★ Resolve 安装路径不再写死：先探测常见位置，找不到再用默认路径。
#   这样换机器 / 换安装目录后仍能自动连接，不用手工改。
def _find_resolve_lib():
    candidates = [
        r"D:\DaVinci Resolve\fusionscript.dll",
        r"C:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll",
        r"C:\Program Files\Blackmagic Design\DaVinci Resolve\Fusion\fusionscript.dll",
        r"D:\Program Files\Blackmagic Design\DaVinci Resolve\fusionscript.dll",
        r"C:\Program Files\Blackmagic Design\DaVinci Resolve Studio\fusionscript.dll",
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    return candidates[0]   # 全部没找到时退回默认路径（由 DV 报错提示）


RESOLVE_LIB = _find_resolve_lib()


def connect():
    """连接正在运行的 Resolve。失败返回 None。"""
    os.environ["RESOLVE_SCRIPT_API"] = API_DIR
    os.environ["RESOLVE_SCRIPT_LIB"] = RESOLVE_LIB
    mods = os.path.join(API_DIR, "Modules")
    if mods not in sys.path:
        sys.path.insert(0, mods)
    import DaVinciResolveScript as dvr
    return dvr.scriptapp("Resolve")


def probe(resolve):
    out = {"ok": False, "items": [], "timeline": "", "fps": 0, "hint": ""}
    try:
        pm = resolve.GetProjectManager()
        proj = pm.GetCurrentProject() if pm else None
        if not proj:
            out["error"] = "没有打开的项目"
            return out

        tl = proj.GetCurrentTimeline()
        if not tl:
            out["error"] = "没有打开的时间线"
            return out

        out["timeline"] = str(tl.GetName() or "")
        try:
            out["fps"] = float(tl.GetSetting("timelineFrameRate") or 0)
        except Exception:
            out["fps"] = 0
        # 时间线起始帧：渲染出的 WAV 第 0 秒对应它（长直播时间线常从
        # 01:00:00 开始，起始帧 360000，换算 In/Out 秒数时要减掉它）。
        try:
            out["tl_start"] = int(tl.GetStartFrame() or 0)
        except Exception:
            out["tl_start"] = 0

        n = tl.GetTrackCount("audio") or 0
        for t in range(1, n + 1):
            for it in (tl.GetItemListInTrack("audio", t) or []):
                rec = _describe(it)
                if rec:
                    rec["track"] = t
                    out["items"].append(rec)

        if len(out["items"]) == 1 and not out["items"][0]["altered"]:
            out["hint"] = "单片段且未裁剪 → 可直接识别，无需渲染"
        elif not out["items"]:
            out["hint"] = "时间线没有音频片段"
        else:
            out["hint"] = "多片段或被剪辑过 → 需渲染导出"
        out["ok"] = True
        return out
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"
        return out


def _describe(it):
    """把一个时间线片段转成 dict，取不到源文件则返回 None。"""
    try:
        name = str(it.GetName() or "")
    except Exception:
        name = ""

    # ★ 注意：GetStart / GetSpeed 在 Studio 21.1 里是【方法】，
    #   不是 GetStartFrame（那个返回 None）。版本不同名字也不同，
    #   所以每个都try，拿到哪个用哪个。
    start = _first_int(it, ("GetStart",), 0)
    src_start = _first_int(it, ("GetSourceStartFrame",), 0)
    src_end = _first_int(it, ("GetSourceEndFrame",), 0)
    speed = _get_speed(it)

    # 被改动过→ 源文件时间轴与时间线对不上，必须走渲染
    altered = (abs(speed - 1.0) > 0.01) or (start > 1) or (src_start > 1)

    path = ""
    try:
        mp = it.GetMediaPoolItem()
        if mp:
            props = mp.GetClipProperty() or {}
            if isinstance(props, dict):
                path = props.get("File Path") or props.get("Original File Path") or ""
            path = str(path)
    except Exception:
        path = ""

    return {
        "path": path,
        "name": name,
        "startFrame": start,
        "endFrame": _tl_end_frame(start, src_start, src_end, speed),
        "speed": speed,
        "sourceStart": src_start,
        "sourceEnd": src_end,
        "altered": altered,
    }


def _tl_end_frame(start, src_start, src_end, speed):
    """片段在时间线上的结束帧 = 起始 + 源长度/速度。"""
    span = src_end - src_start
    if span <= 0:
        return start
    try:
        return start + int(round(span / (speed or 1.0)))
    except Exception:
        return start


def _first_int(obj, names, default):
    for n in names:
        f = getattr(obj, n, None)
        if callable(f):
            try:
                v = f()
                if v is not None:
                    return int(v)
            except Exception:
                continue
    return default


def _get_speed(it):
    """速度可能是 float，也可能是 {'Percentage': 100.0} 这种表。"""
    f = getattr(it, "GetSpeed", None)
    if not callable(f):
        return 1.0
    try:
        v = f()
    except Exception:
        return 1.0
    if isinstance(v, dict):
        p = v.get("Percentage")
        return float(p) / 100.0 if p else 1.0
    try:
        fv = float(v)
    except (TypeError, ValueError):
        return 1.0
    # 有些版本返回 100 表示 100%
    return fv / 100.0 if fv > 2.0 else fv


SUPPORTED = {
    ".wav", ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus",
    ".wma", ".aiff", ".mp4", ".mov", ".mkv", ".avi",
    ".webm", ".flv", ".m4v", ".mpg", ".mpeg", ".ts",
}


def refresh_model_manifest():
    r"""顺手刷新模型清单（models.txt + models.lua），供 Lua 的下拉框读取。

    ★ 放在【探测】这一步做，而不是只有识别时才刷新：
      探测是每次点「开始」都跑的第一步，这样用户新装了模型，
      下一趟打开工具就能在下拉框里看到（不必等识别跑完才刷新）。

    ★★ 必须直接调 resolve_bridge.refresh_manifest，不要在这里另写一份：
       以前两份写法格式不同（这里是纯字符串数组，那边是
       { name=.., path=.. } 表），而探测比识别先跑，写进去的总是
       字符串数组 → Lua 侧 path 全是 nil → 只能靠拼
       TOOL_ROOT\models\<名字> 碰运气。格式必须单一来源。
    """
    try:
        import resolve_bridge
        resolve_bridge.refresh_manifest()
    except Exception:
        pass


def main():
    if len(sys.argv) < 2:
        print("用法: timeline_source.py <输出json> [输出txt]")
        sys.exit(2)          # ★ 必须退出：否则下一行 argv[1] 直接 IndexError
    out_path = sys.argv[1]
    # 可选的第二个参数：纯文本路径文件
    # ★ Lua 侧用模式匹配解析 JSON 时，中文/特殊字符可能出问题，
    #   所以额外写一个"一行一个路径"的 txt，Lua 只读第一行即可。
    txt_path = sys.argv[2] if len(sys.argv) > 2 else ""
    # 第三个参数：Lua chunk（src.lua），Lua 用 loadfile 直接加载
    lua_path = sys.argv[3] if len(sys.argv) > 3 else ""

    try:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
    except OSError:
        pass

    refresh_model_manifest()

    result = {"ok": False, "items": [], "error": "未连接"}
    try:
        resolve = connect()
        if resolve is None:
            result["error"] = (
                "外部脚本访问未开启或连接失败。"
                "请到 首选项→系统→常规→外部脚本使用 设为「本地」或「网络」，"
                "然后完全退出并重启 Resolve"
            )
        else:
            result = probe(resolve)
            # 标记哪些可以直接用
            for it in result.get("items", []):
                p = it.get("path", "")
                ext = os.path.splitext(p)[1].lower()
                it["supported"] = ext in SUPPORTED
                it["usable"] = bool(p) and it["supported"] and not it["altered"]
    except Exception as e:
        result = {"ok": False, "items": [], "error": f"{type(e).__name__}: {e}"}

    # ★ txt 用 CRLF 换行；Lua 侧会 gsub 掉 \r 和 \n，两道保险
    best = ""
    for it in result.get("items", []):
        if it.get("usable"):
            best = it.get("path", "")
            break

    # ★ any = 时间线上【任意一个】有源文件的素材，不管能不能直接拿来识别。
    #   存在的意义：走渲染兜底时（素材被裁剪/变速，不可用），best 是空的，
    #   Lua 就拿不到素材路径 → 落轨时"素材旁放一份 srt"这步会静默跳过。
    #   有了 any，即使走渲染也能在原始素材旁边生成字幕副本。
    any_path = ""
    for it in result.get("items", []):
        if it.get("path"):
            any_path = it.get("path", "")
            break

    if txt_path:
        try:
            os.makedirs(os.path.dirname(txt_path), exist_ok=True)
        except OSError:
            pass
        try:
            with open(txt_path, "w", encoding="utf-8", newline="\r\n") as f:
                f.write(best + "\n")
        except OSError:
            pass

        # ★ 额外写一份 audio_path.txt —— 专门给识别引擎的参数文件用。
        #   存在的意义：素材路径是中文，不能走命令行（GBK 乱码），
        #   所以 resolve_bridge.py 从这个文件读音频路径。
        try:
            with open(os.path.join(os.path.dirname(txt_path),
                                   "audio_path.txt"),
                       "w", encoding="utf-8", newline="\r\n") as f:
                f.write(best + "\n")
        except OSError:
            pass

    # ★★ 写一份 Lua chunk（src.lua），Lua 侧用 loadfile 直接加载成 table。
    #   学自 AutoSubs 的文件邮箱：他们的 request.lua 就是一个 return {...}。
    #   好处：不需要在 Lua 里用模式匹配解析 JSON，中文/转义全交给 Lua 引擎。
    #   长字符串用 [[...]]，唯一要防的是内容里出现 "]]"（路径里几乎不可能）。
    if lua_path:
        _tmp_lua = None      # ★ 先占位：open/replace 在赋值前抛错时，except 里要判空
        try:
            def ls(v):
                s = str(v or "").replace("]]", "]] .. ']]' .. [[")
                return "[[" + s + "]]"

            hint = result.get("hint", "") or ""
            err = result.get("error", "") or ""
            name = ""
            for it in result.get("items", []):
                if it.get("usable"):
                    name = it.get("name", "")
                    break

            # ★ 原子写：worker 并发模型下 Lua 可能在 open("w") 截断之后、
            #   内容写完之前 loadfile，读到半截 → 探测偶发失败。
            _tmp_lua = lua_path + ".%d.tmp" % os.getpid()
            with open(_tmp_lua, "w", encoding="utf-8", newline="\n") as f:
                f.write("return {\n")
                f.write("  ok = %s,\n" % ("true" if result.get("ok") else "false"))
                f.write("  path = %s,\n" % ls(best))
                f.write("  any = %s,\n" % ls(any_path))
                f.write("  name = %s,\n" % ls(name))
                f.write("  hint = %s,\n" % ls(hint))
                f.write("  error = %s,\n" % ls(err))
                f.write("  items = %d,\n" % len(result.get("items", [])))
                # 帧率 / 时间线起始帧：Lua 侧播放头联动跳转的时间码换算要用
                f.write("  fps = %s,\n" % repr(float(result.get("fps") or 0)))
                f.write("  tl_start = %d,\n" % int(result.get("tl_start") or 0))
                f.write("}\n")
            os.replace(_tmp_lua, lua_path)
        except OSError:
            try:
                if _tmp_lua and os.path.exists(_tmp_lua):
                    os.remove(_tmp_lua)
            except OSError:
                pass

    try:
        _tmp_json = out_path + ".%d.tmp" % os.getpid()
        with open(_tmp_json, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
        os.replace(_tmp_json, out_path)
    except OSError as e:
        print(f"写文件失败: {e}")
        sys.exit(1)

    # stdout 保持 ASCII 安全（可能被重定向到非UTF8 环境）
    print(f"items={len(result.get('items', []))} "
          f"usable={1 if best else 0} error={result.get('error', '')}")
    sys.exit(0 if result.get("ok") else 3)


if __name__ == "__main__":
    main()