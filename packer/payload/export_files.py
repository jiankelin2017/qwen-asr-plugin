# -*- coding: utf-8 -*-
"""把生成的字幕 / 文稿导出到用户指定的文件夹。

用法:
    export_files.py <config.json>

config (UTF-8 JSON):
{
  "srt": "C:\\HEIBA\\Qwen字幕工具\\字幕输出\\123.srt",
  "txt": "C:\\HEIBA\\Qwen字幕工具\\字幕输出\\123.txt",
  "dir": "D:\\导出",                 ← 目标文件夹（用户选的）
  "kinds": ["srt", "txt"],           ← 要导出哪些
  "open": true,                      ← 是否顺手打开目标文件夹
  "out_lua": "C:\\HEIBA\\q3\\rt\\export.lua"
}

输出 out_lua（Lua chunk）：
    return { ok=true, dir=[[...]], paths=3, names=[[a.srt\nb.txt]], err=[[]] }

★ 为什么复制这件事也交给 Python：
  1. 目标文件夹路径可能含中文 —— Lua 的 io.open 走 ANSI 接口打不开
  2. 需要创建目录、处理同名覆盖，Python 一行搞定
"""
import json
import os
import shutil
import sys
import traceback


def lua_str(s):
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
    text = (
        "return {\n"
        "  ok = %s,\n" % ("true" if d.get("ok") else "false")
        + "  paths = %d,\n" % int(d.get("paths") or 0)
        + "  dir = %s,\n" % lua_str(d.get("dir"))
        + "  names = %s,\n" % lua_str(d.get("names"))
        + "  err = %s,\n" % lua_str(d.get("err"))
        + "}\n"
    )
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
    except OSError:
        pass
    try:
        tmp = path + ".tmp.%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def main():
    res = {"ok": False, "paths": 0, "dir": "", "names": "", "err": ""}
    try:
        if len(sys.argv) < 2:
            raise RuntimeError("缺少参数：config.json")
        with open(sys.argv[1], encoding="utf-8") as f:
            cfg = json.load(f)

        dst_dir = str(cfg.get("dir") or "").strip()
        out_lua = str(cfg.get("out_lua") or "")
        kinds = cfg.get("kinds") or ["srt"]

        if not dst_dir:
            raise RuntimeError("没有指定目标文件夹")

        srcs = []
        for k in kinds:
            p = str(cfg.get(k) or "").strip()
            if not p:
                continue
            if not os.path.isfile(p):
                raise RuntimeError("文件不存在：" + p)
            srcs.append(p)

        if not srcs:
            raise RuntimeError("没有可导出的文件")

        os.makedirs(dst_dir, exist_ok=True)

        names = []
        for p in srcs:
            dst = os.path.join(dst_dir, os.path.basename(p))
            shutil.copyfile(p, dst)
            names.append(os.path.basename(p))

        res["dir"] = dst_dir
        res["names"] = "\n".join(names)
        res["paths"] = len(names)
        res["ok"] = True

        # 顺手打开目标文件夹（失败无所谓）
        if cfg.get("open"):
            try:
                os.startfile(dst_dir)  # noqa: S606  Windows only
            except Exception:
                pass

    except Exception as e:
        res["ok"] = False
        res["err"] = "%s: %s" % (type(e).__name__, e)
        traceback.print_exc()

    write_lua(out_lua, res)
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0 if res.get("ok") else 3)


if __name__ == "__main__":
    main()
