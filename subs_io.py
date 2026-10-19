# -*- coding: utf-8 -*-
"""字幕存取桥 —— 给 Lua 侧的字幕编辑器读写 SRT。

为什么需要它：
  Lua 的 io.open 在 Windows 上走 ANSI 接口，打不开含中文的路径
  （本工程的 SRT 就放在 C:\\HEIBA\\Qwen字幕工具\\字幕输出\\）。所以
  字幕文件一律由本脚本读写，Lua 只碰纯 ASCII 的中间文件。

两种模式（都从命令行传一个 JSON 配置文件的路径）：
  {"mode": "dump", "srt": "<srt>", "out": "<subs.lua>"}
      SRT → Lua 表，供 Lua 用 loadfile 直接读
  {"mode": "save", "srt": "<srt>", "in": "<subs.json>"}
      Lua 写出的 JSON → 覆写回 SRT

★ 用「Lua 表」而不是 JSON 下发（Lua 读回结果），是因为 Lua 没有内置
  JSON 解析；反过来上行用 JSON，是因为 Lua 拼 JSON 只要转义引号即可。
  两个方向各取对方最容易解析的格式。
"""
import json
import os
import sys
import re

TS_RE = re.compile(
    r"(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})")


def ts_to_sec(h, m, s, ms):
    # ★ ms 可能是 1~3 位：",50" 是 50 毫秒，不是 500。
    #   原来的 ljust(3,"0") 会把它放大 10 倍，字幕整体提前半秒。
    #   按位数补右：1 位 → ×100，2 位 → ×10，3 位 → ×1
    ms = str(ms)
    scale = 10 ** (3 - len(ms)) if len(ms) < 3 else 1
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) * scale / 1000.0


def sec_to_ts(x):
    # 按总毫秒算：先拆时/分/秒再各自进位会在 59.9997 这类值上
    # 产出 "HH:MM:60,000"（非法时间码）。总毫秒法除到位，不会出现 60。
    total = int(round(max(0.0, float(x)) * 1000))
    h, rem = divmod(total, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return "%02d:%02d:%02d,%03d" % (h, m, s, ms)


def parse_srt(text):
    """解析 SRT → [{"s": 开始秒, "e": 结束秒, "t": 文本}, ...]"""
    text = text.replace("\ufeff", "").replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for block in re.split(r"\n\s*\n", text):
        lines = [ln for ln in block.split("\n") if ln.strip() != ""]
        if not lines:
            continue
        # 首行可能是序号，也可能直接是时间行
        ti = 0
        if not TS_RE.search(lines[0]) and len(lines) > 1:
            ti = 1
        if ti >= len(lines):
            continue
        m = TS_RE.search(lines[ti])
        if not m:
            continue
        g = m.groups()
        st = ts_to_sec(g[0], g[1], g[2], g[3])
        en = ts_to_sec(g[4], g[5], g[6], g[7])
        body = "\n".join(lines[ti + 1:]).strip()
        if body:
            out.append({"s": st, "e": en, "t": body})
    return out


def lua_quote(s):
    out = []
    for ch in str(s):
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
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def write_lua_table(blocks, path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    parts = ["return {\n"]
    for b in blocks:
        parts.append("  { s = %.3f, e = %.3f, t = %s },\n"
                     % (b["s"], b["e"], lua_quote(b["t"])))
    parts.append("}\n")
    tmp = path + ".%d.tmp" % os.getpid()
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(parts))
    os.replace(tmp, path)


def write_srt(blocks, path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    parts = []
    n = 0
    for b in blocks:
        text = str(b["t"]).strip()
        # ★ 文本为空的行直接跳过：编辑时把整行删空是常见动作，
        #   不能让它变成一条"有时间轴、没内容"的空字幕写进 SRT。
        #   条目编号也跟着重排，保证 SRT 序号连续。
        if not text:
            continue
        n += 1
        parts.append("%d\n%s --> %s\n%s\n\n"
                     % (n, sec_to_ts(b["s"]), sec_to_ts(b["e"]), text))
    tmp = path + ".%d.tmp" % os.getpid()
    with open(tmp, "w", encoding="utf-8-sig", newline="\n") as f:
        f.write("".join(parts))
    os.replace(tmp, path)


_SENT_CLOSERS = "”’」』）】》〉］］｝}’"
_SENT_END = "。！？!?…；;，,、"
_SENT_RE = re.compile(
    r"[^。！？!?…]*[。！？!?…][" + _SENT_CLOSERS + r"]*")


def write_txt(blocks, path):
    """把字幕拼成带标点的完整文稿，一句一行。

    ★ 为什么要在这里重写一份而不是复用识别阶段生成的 txt：
      识别时生成的 txt 只反映当时的识别结果；用户在字幕编辑器里
      改过之后，如果还拿那份旧文件去导出，导出的就是修改前的内容。
      所以每次保存字幕，文稿都必须跟着重新生成，两边才不会脱节。
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    joined = "".join(str(b.get("t") or "") for b in blocks)
    joined = joined.replace("\n", "").replace("\r", "")

    lines, pos = [], 0
    for m in _SENT_RE.finditer(joined):
        s = m.group().strip()
        pos = m.end()
        if s:
            lines.append(s)
    tail = joined[pos:].strip()
    if tail:
        if lines and lines[-1][-1] in _SENT_END:
            lines.append(tail)
        elif lines:
            lines[-1] = lines[-1] + tail
        else:
            lines.append(tail)

    # 句末没标点就补一个（勾了「去除标点符号」时会出现）
    fixed = []
    for s in lines:
        if s and s[-1] not in _SENT_END and s[-1] not in _SENT_CLOSERS:
            s += "。"
        fixed.append(s)

    if not fixed and joined.strip():
        fixed = [joined.strip()]

    tmp = path + ".%d.tmp" % os.getpid()
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(fixed) + "\n")
    os.replace(tmp, path)
    return len(fixed)


def read_text_any(path):
    for enc in ("utf-8-sig", "utf-8", "gbk", "latin-1"):
        try:
            with open(path, "r", encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError:
            continue
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    if len(sys.argv) < 2:
        print("usage: subs_io.py <config.json>")
        return 2
    with open(sys.argv[1], "r", encoding="utf-8-sig") as f:
        cfg = json.load(f)

    mode = cfg.get("mode") or "dump"
    srt = cfg.get("srt") or ""

    if mode == "dump":
        if not srt or not os.path.isfile(srt):
            print("ERR srt not found: %s" % srt)
            write_lua_table([], cfg.get("out") or "")
            return 1
        blocks = parse_srt(read_text_any(srt))
        # ★ 和 save 分支一样修正 e<s：编辑器收到负时长条目时
        #   时间列会算出负数，用户看到 "-1.20 → 3.40" 这种鬼东西。
        for b in blocks:
            try:
                if float(b.get("e") or 0.0) < float(b.get("s") or 0.0):
                    b["e"] = b["s"]
            except (TypeError, ValueError):
                b["e"] = b.get("s") or 0.0
        write_lua_table(blocks, cfg.get("out") or "")
        print("OK dump %d blocks" % len(blocks))
        return 0

    if mode == "save":
        src = cfg.get("in") or ""
        if not src or not os.path.isfile(src):
            print("ERR json not found: %s" % src)
            return 1
        with open(src, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        blocks = []
        for b in data.get("blocks") or []:
            t = str(b.get("t") or "").strip()
            if not t:
                continue
            try:
                s = float(b.get("s") or 0.0)
                e = float(b.get("e") or 0.0)
            except (TypeError, ValueError):
                continue
            if e < s:
                e = s
            blocks.append({"s": s, "e": e, "t": t})
        write_srt(blocks, srt)
        # ★ 文稿必须和字幕同步重生成，否则「导出 TXT」给出的是修改前的旧稿。
        #   给了 txt 路径就写；写失败不影响字幕本身。
        n_txt = 0
        txt = cfg.get("txt") or ""
        if txt:
            try:
                n_txt = write_txt(blocks, txt)
            except Exception as e:
                print("WARN txt not written: %s" % e)
        print("OK save %d blocks -> %s (txt=%d)" % (len(blocks), srt, n_txt))
        return 0

    if mode == "totxt":
        # 只按当前字幕重新生成文稿，不碰 SRT。
        # 「导出 TXT」在复制之前会先跑这一步，保证导出的是修改过的最新版本。
        src = cfg.get("in") or ""
        txt = cfg.get("txt") or ""
        if not src or not os.path.isfile(src):
            print("ERR json not found: %s" % src)
            return 1
        if not txt:
            print("ERR txt path empty")
            return 1
        with open(src, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        blocks = []
        for b in data.get("blocks") or []:
            t = str(b.get("t") or "").strip()
            if not t:
                continue
            # ★ 和 save 分支保持一致：脏 JSON 不该让整个脚本崩掉，
            #   坏条目跳过、能用的照常用。
            try:
                s = float(b.get("s") or 0.0)
                e = float(b.get("e") or 0.0)
            except (TypeError, ValueError):
                continue
            blocks.append({"s": s, "e": e, "t": t})
        n = write_txt(blocks, txt)
        print("OK totxt %d lines -> %s" % (n, txt))
        return 0

    print("ERR unknown mode: %s" % mode)
    return 2


if __name__ == "__main__":
    sys.exit(main())
