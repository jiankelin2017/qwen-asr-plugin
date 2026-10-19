# -*- coding: utf-8 -*-
"""常驻 ASR 服务 —— 只加载一次模型，之后反复复用。

为什么要有它
------------
resolve_bridge.py 每次识别都要 from_pretrained 两个模型（ASR + ForcedAligner），
实测 6~7 秒；而 3 分半的素材识别本身只要 30 秒。也就是说每跑一次就有
将近 20% 的时间花在"重新把模型搬进显存"上，而且第二次、第三次…一分不少。

本进程常驻，模型只加载一次，之后靠文件邮箱接任务：
    第 1 次识别：和原来一样（本地加载 or 转发给刚预热的 server）
    第 2 次起：直接复用，省掉 6~7 秒 + 一次 CUDA 初始化

协议（和本项目其它部分一致：全部走文件，不开端口）
------------------------------------------------
  rt\\asr_cmd.json   任务
      {"id": 12, "audio": "...", "lang": "Chinese", "prompt": "",
       "max_chars": 12, "no_gap": false, "no_punct": false,
       "model": "C:\\...\\Qwen3-ASR-0.6B-hf",
       "status_lua": "...\\status.lua", "status_file": "...\\status.txt",
       "log": "...\\engine.log"}
      {"id": 13, "cmd": "quit"}                    ← 退出
  rt\\asr_res.json   结果
      {"id": 12, "ok": true, "blocks": [[0.0, 2.4, "你好"], ...],
       "stats": {"duration":..., "elapsed":..., "rtf":..., "device":...},
       "err": ""}
  rt\\asr_hb.txt     心跳（JSON）
      {"t": <unix时间戳>, "ready": 0|1, "model": "<当前模型路径>",
       "pid": <进程号>, "busy": 0|1}
      resolve_bridge 靠它判断：服务在不在、模型加载完没、模型是不是我要的那个。
      ★ 必须是 JSON：模型路径可能含空格或为空，空格分隔会让字段整体错位。
      （兼容期：读方仍认旧的空格分隔格式，见 resolve_bridge.srv_state）
  rt\\asr_preload.txt  可选，启动时预热的模型路径（Lua 预热时写）

★ 降级设计（重要）：
  resolve_bridge 只把这里当"加速器"。服务不在 / 没就绪 / 模型不匹配 /
  中途崩溃 / 超时 —— 任何一种情况它都直接退回到本地加载，功能完全不受影响。
  所以这个文件出任何问题都不会让工具不可用。

空闲 IDLE_EXIT_SEC 秒没有任务就自行退出，避免长期占着显存
（0.6B + Aligner 大约 2.5 GB）。
"""
import json
import os
import signal
import sys
import threading
import time
import traceback

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from asr_engine import Engine  # noqa: E402

RT = os.path.join(_HERE, "rt")
CMD_FILE = os.path.join(RT, "asr_cmd.json")
RES_FILE = os.path.join(RT, "asr_res.json")
HB_FILE = os.path.join(RT, "asr_hb.txt")
PRELOAD_FILE = os.path.join(RT, "asr_preload.txt")
IDLE_EXIT_SEC = 20 * 60
POLL_SEC = 0.2
# 心跳间隔必须显著小于客户端判定"服务不在"的阈值（SRV_HB_FRESH=25 秒），
# 取 2 秒留足安全边际；再快也没意义，只是平白多写文件。
HEARTBEAT_SEC = 2.0


def _mkdir(p):
    try:
        if p:
            os.makedirs(p, exist_ok=True)
    except OSError:
        pass


def write_json(path, obj):
    """原子写 JSON（先 .tmp 再 replace）—— 读的一方永远看不到半截文件。"""
    _mkdir(os.path.dirname(path))
    try:
        tmp = path + ".tmp.%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


def write_hb(model, ready, busy=False):
    try:
        tmp = HB_FILE + ".tmp.%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            # ★★ 用 JSON，不要用空格分隔！
            #   老格式 "%d %d %s %d %d" 把模型路径放在第 3 段，而模型路径
            #   ① 可能含空格（用户自定义路径，如 D:\My Models\X）
            #   ② 加载前后会被写成空串（见下方 write_hb("", False) 调用点）
            #   读方 split() 后字段整体错位 → int(parts[3]) 失败 → pid=0
            #   → 客户端判"进程已死" → 删心跳 → 常驻服务被静默废掉，
            #   每次都退化成 6~7 秒本地加载；极端情况还会误杀无关进程。
            #   JSON 没有分隔符歧义，路径含空格/为空都安全。
            json.dump({
                "t": int(time.time()),
                "ready": 1 if ready else 0,
                "model": model or "",
                "pid": os.getpid(),
                "busy": 1 if busy else 0,
            }, f)
        os.replace(tmp, HB_FILE)
    except Exception:
        # ★ 必须拦下所有异常，不只是 OSError：这个线程一旦死掉，
        #   客户端就会判定服务不在，正在跑的任务白白被回退。
        pass


def cmd_signature():
    try:
        st = os.stat(CMD_FILE)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


class Server:
    def __init__(self):
        self.engine = None
        self.model = ""
        self.ready = False
        self.busy = False
        self.stop_evt = threading.Event()

    # ── 心跳（独立线程）────────────────────────────────────────
    # ★★ 这是整个常驻服务最容易踩的坑：识别一个任务是【同步阻塞】的，
    #    3 分半的素材要跑 25~145 秒。如果心跳写在主循环里，这段时间
    #    心跳就完全停了 —— 客户端会以为服务死了，回退到本地再加载一份
    #    torch，结果是两份 CUDA 上下文抢显存 / 页面文件：
    #      OSError: [WinError 1455] 页面文件太小 ... cublas64_12.dll
    #    实测就是这么翻的车。所以心跳必须独立线程，跟任务跑不跑无关。
    def hb_loop(self):
        while not self.stop_evt.wait(HEARTBEAT_SEC):
            write_hb(self.model, self.ready, self.busy)

    # ── 收摊 ──────────────────────────────────────────────────
    def install_signals(self):
        """对接 os.kill(pid, SIGTERM) —— worker 的「停止按钮」就是这么杀的。

        ★ 不做这个会有个很阴的问题：Python 收到 SIGTERM 后直接死，
          来不及删心跳文件，于是 rt\\asr_hb.txt 上留着一条【时间戳很新
          但进程已经没了】的假心跳。客户端信了它，把任务发给一个死进程，
          只能干等到超时才回退本地 —— 用户白等一分半。
        """
        def _handler(signum, frame):
            self.stop_evt.set()
            self.ready = False
            write_hb("", False)
            try:
                os.remove(HB_FILE)
            except OSError:
                pass
            sys.exit(0)

        for sig_name in ("SIGTERM", "SIGINT", "SIGBREAK"):
            sig = getattr(signal, sig_name, None)
            if sig is None:
                continue
            try:
                signal.signal(sig, _handler)
            except (ValueError, OSError):
                pass        # 主线程之外注册不了就算了，不影响功能

    # ── 模型 ──────────────────────────────────────────────────
    def ensure_model(self, model_path, log):
        """模型没变就直接复用；变了/还没加载才真正 load()。"""
        want = (model_path or "").strip()
        if self.ready and self.engine is not None and want == self.model:
            return True
        try:
            self.ready = False
            write_hb(want, False)
            self.engine = Engine(log=log, asr_model=(want or None))
            self.engine.load()
            self.model = want
            self.ready = True
            write_hb(want, True)
            return True
        except Exception:
            self.engine = None
            self.ready = False
            self.model = ""
            log("模型加载失败：\n" + traceback.format_exc())
            write_hb("", False)
            return False

    # ── 跑一个任务 ────────────────────────────────────────────
    def run_job(self, cfg, log):
        jid = int(cfg.get("id") or 0)
        status_lua = str(cfg.get("status_lua") or "")
        status_file = str(cfg.get("status_file") or "")

        def report(pct, count=0, err=""):
            """进度写 status.lua / status.txt —— 和本地模式完全同一套文件，
            所以 Lua 那边的轮询逻辑一个字都不用改。"""
            pct = int(pct)
            if status_lua:
                body = "pct = %d, count = %d, t = %d" % (pct, int(count),
                                                         int(time.time()))
                try:
                    tmp = status_lua + ".tmp.%d.tmp" % os.getpid()
                    with open(tmp, "w", encoding="utf-8") as f:
                        f.write("return {" + body + "}\n")
                    os.replace(tmp, status_lua)
                except OSError:
                    pass
            if status_file:
                try:
                    with open(status_file, "w", encoding="utf-8") as f:
                        f.write("%d%%|%d" % (pct, int(count)))
                except OSError:
                    pass

        self.busy = True
        try:
            audio = str(cfg.get("audio") or "")
            if not audio or not os.path.isfile(audio):
                write_json(RES_FILE, {"id": jid, "ok": False, "blocks": [],
                                      "err": "找不到音频：" + audio})
                return

            log("（常驻服务）音频: %s" % audio)
            report(0)

            if not self.ensure_model(str(cfg.get("model") or ""), log):
                write_json(RES_FILE, {"id": jid, "ok": False, "blocks": [],
                                      "err": "常驻服务加载模型失败"})
                return

            max_chars = int(cfg.get("max_chars") or 12)
            blocks, stats = self.engine.run(
                audio,
                lang=str(cfg.get("lang") or "Chinese"),
                prompt=str(cfg.get("prompt") or ""),
                max_chars=max_chars,
                remove_gaps=bool(cfg.get("no_gap")),
                trim_punct=bool(cfg.get("no_punct")),
                strip_all_punct=bool(cfg.get("strip_all_punct")),
                # ★ 同样钳到 99：中途报 100 会让 Lua 提前判"完成"
                progress=lambda cur, tot: report(
                    min(99, int(cur * 100 / max(1, tot))) if tot else 0),
            )
            write_json(RES_FILE, {
                "id": jid,
                "ok": True,
                "blocks": [[float(a), float(b), str(t)] for (a, b, t) in blocks],
                "stats": {k: (float(v) if isinstance(v, (int, float)) else v)
                          for k, v in (stats or {}).items()},
                "err": "",
                # ★ 实际跑的模型。走常驻服务时模型是在【服务端】加载的，
                #   用户填的自定义路径无效时回退也发生在那边 —— 不带回来的话
                #   界面就永远显示用户填的那个路径，看不出其实没用上。
                "model_note": getattr(self.engine, "model_note", ""),
            })
            log("（常驻服务）完成 %d 条" % len(blocks))
        except Exception as e:
            log("常驻服务异常：\n" + traceback.format_exc())
            write_json(RES_FILE, {"id": jid, "ok": False, "blocks": [],
                                  "err": "%s: %s" % (type(e).__name__, e)})
        finally:
            self.busy = False
            # ★★ 这里【绝对不能】删 status.lua —— 之前这么做踩了竞态：
            #    任务一写完结果，bridge 那边就立刻读走、写 SRT、然后报告
            #    100%。两边几乎同时动同一个文件，服务的删除可能正好落在
            #    bridge 写完 100% 之后 → 完成信号被抹掉，界面永远停在 99%，
            #    最后判定"识别进程已退出"。实测两轮复现。
            #
            #    不删也不会串到下一轮：bridge 每次开场都会先 report(0)
            #    把进度归零，而且最后一个进度被钳在 99（真·完成要等
            #    bridge 把 SRT 落盘后才报 100），本来就不会提前误判完成。

    # ── 主循环 ────────────────────────────────────────────────
    def loop(self):
        _mkdir(RT)
        write_hb("", False)
        def log(msg):
            # 日志路径每个任务都不一样，统一追加到 engine.log 方便排查
            try:
                with open(os.path.join(RT, "engine.log"), "a",
                          encoding="utf-8") as f:
                    f.write(str(msg) + "\n")
            except OSError:
                pass

        log("=== ASR 常驻服务启动 pid=%d ===" % os.getpid())
        self.install_signals()

        # ★ 心跳交给独立线程。daemon=True：主循环一 return，线程随之结束，
        #   不需要 join，也不会拖住退出。
        _hb = threading.Thread(target=self.hb_loop, daemon=True)
        _hb.start()
        self._hb_thread = _hb

        # 可选预热：Lua 在预热时写好模型路径，这里直接装好，
        # 这样用户下一次点"开始"时服务已经是 ready 状态。
        try:
            if os.path.exists(PRELOAD_FILE):
                with open(PRELOAD_FILE, "r", encoding="utf-8") as f:
                    pre = f.read().strip()
                if pre:
                    log("预热模型: %s" % pre)
                    self.ensure_model(pre, log)
        except OSError:
            pass

        last_key = None
        # ★★ 基线必须是【启动那一刻的文件签名】，不能是 None！
        #   写成 None 的话，loop 第一轮 `sig is not None and sig != last_sig`
        #   立刻成立 —— 于是把启动前就躺在 rt\asr_cmd.json 里的
        #   【上一次任务的残留命令】当成新命令重跑一遍。后果：
        #     ① 白跑一次完整识别（几十秒 GPU），且用旧任务的 report()
        #        反复写 status.lua / status.txt，界面进度乱跳；
        #     ② 若重放耗时超过客户端 SRV_BUSY_WAIT(120s)，客户端会判
        #        "服务太忙" → 回退本地加载 → 两份 torch 抢显存/页面文件，
        #        正是本文件开头警告过的 WinError 1455 cublas64_12.dll 崩溃。
        #   worker.py 的同构循环一直有这个基线（它的 last_sig），这里漏了。
        last_sig = cmd_signature()
        last_job_at = time.time()

        while True:
            now = time.time()

            sig = cmd_signature()
            if sig is not None and sig != last_sig:
                cmd = None
                try:
                    with open(CMD_FILE, "r", encoding="utf-8") as f:
                        cmd = json.load(f)
                    # ★ 只在【读成功】之后才确认基线（与 worker.py 的同构循环
                    #   一致）。原先是先更新 last_sig 再读文件 —— 一旦读失败
                    #   （文件被占用 / 半截 JSON），这条命令会被永久跳过，
                    #   客户端只能干等 SRV_ACCEPT_SEC 再回退本地加载。
                    last_sig = sig
                except Exception:
                    pass
                if isinstance(cmd, dict):
                    jid = int(cmd.get("id") or 0)
                    key = jid
                    if key != last_key:
                        last_key = key
                        last_job_at = now
                        if str(cmd.get("cmd") or "") == "quit":
                            write_json(RES_FILE, {"id": jid, "ok": True,
                                                  "quit": True})
                            log("收到 quit，退出")
                            return self.shutdown()
                        self.run_job(cmd, log)
                        last_job_at = time.time()

            if now - last_job_at > IDLE_EXIT_SEC:
                log("空闲超时，退出（释放显存）")
                return self.shutdown()

            time.sleep(POLL_SEC)

    def shutdown(self):
        """收摊：先掐掉心跳线程，再删心跳文件。

        ★ 顺序不能反 —— 线程每 2 秒写一次心跳，先删文件的话它可能
          立刻又写回去，客户端会以为服务还活着，回退本地加载时照样撞车。
        """
        self.stop_evt.set()
        try:
            t = getattr(self, "_hb_thread", None)
            if t is not None and t.is_alive():
                t.join(timeout=5)
        except Exception:
            pass
        try:
            os.remove(HB_FILE)
        except OSError:
            pass
        self.ready = False
        self.busy = False
        return 0


if __name__ == "__main__":
    try:
        sys.exit(Server().loop())
    except Exception:
        try:
            with open(os.path.join(RT, "asr_server_crash.log"), "w",
                      encoding="utf-8") as f:
                f.write(traceback.format_exc())
        except OSError:
            pass
        sys.exit(1)
