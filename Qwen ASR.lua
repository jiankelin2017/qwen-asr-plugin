--[[
    Qwen ASR — DaVinci Resolve 集成脚本
    ==========================================
    基于 Qwen3-ASR-0.6B 的本地 AI 字幕生成

    全异步架构（不阻塞界面）：
      1. AddRenderJob + StartRendering 导出时间线音频
      2. 轮询渲染状态，完成后启动 Python 引擎
      3. 轮询进度文件，完成后导入媒体池

    UI API 模式：
      resolve:Fusion().UIManager
        → bmd.UIDispatcher(ui)
        → dispatcher:AddWindow{...}
        → dispatcher.On.Timeout + RunLoop
]]

-- ══════════════════════════════════════════════════════════════════
-- 路径解析
-- ----------------------------------------------------------------
-- ★ 本工具跟 DaVinci 装在哪个盘【没有关系】：
--   它自己找的是引擎目录（q3）、运行环境（q3\.venv）、模型目录，
--   这三处都是独立于 DaVinci 安装位置的。
--   唯一要求：把本脚本文件放进 DaVinci 的 Scripts\Utility\ 里，
--   菜单里才会出现（见「关于」弹窗里的说明）。
--
-- ★ 但工具【自己】可能被搬到别的盘（C:\HEIBA → D:\HEIBA）。
--   所以下面按盘符顺序探测，第一个找到引擎的盘就用它；
--   全都找不到才退回 C 盘（保持老行为，不会因为探测失败就跑不起来）。
--   探测用 resolve_bridge.py 当路标 —— 它是 ASCII 路径，Lua 读得动；
--   中文目录（模型目录）Lua 在 Windows 上打不开，探不了，只能按
--   同级的兄弟目录推导。
-- ══════════════════════════════════════════════════════════════════

-- 文件存在性探测（此处不能复用下面的 exists()，它定义在后面）
--   bmd.fileexists 优先，io.open 兜底 —— 顶层执行时 bmd 有可能还没注入。
local function _fileOk(p)
    if type(bmd) == "table" and type(bmd.fileexists) == "function" then
        local ok, r = pcall(bmd.fileexists, p)
        if ok and r == true then return true end
    end
    if io ~= nil then
        local f = io.open(p, "r")
        if f then f:close() return true end
    end
    return false
end

-- 纯 ASCII 路径判定：含任何非 ASCII 字节（中文/日文/emoji…）返回 false。
--   ★ 为什么必须有它：Lua 的 io.open / os.execute 在 Windows 上走 ANSI 接口，
--     中文路径会变成乱码（"Qwen瀛楀箷宸ュ叿"）而打不开。而安装器允许用户
--     自选安装位置，完全可能选到 D:\软件\Qwen ASR 这种目录 —— 那样整个插件
--     会以"任务超时"这种和真因无关的方式静默坏掉，极难排查。
--     所以：中文路径一律弃用，退回去按盘符探测（候选 \HEIBA\q3 全是 ASCII）。
local function _isAsciiPath(s)
    if type(s) ~= "string" or s == "" then return false end
    return s:find("[\128-\255]") == nil
end

-- 按盘符找带路标的目录，返回第一个命中的完整路径；都没命中返回 nil
local function _probeRoot(tail, marker)
    for _, d in ipairs({ "C:", "D:", "E:", "F:", "G:", "H:" }) do
        local root = d .. tail
        if _fileOk(root .. "\\" .. marker) then return root end
    end
    return nil
end

-- 引擎目录（纯 ASCII，可探测）
-- ★ 安装器（Qwen ASR 安装器.exe）会把下面这行的路径替换成用户自己选的
--   目录，所以装到 D:\\MyTools 之类的地方也能直接用。
--   若这个目录后来被删掉/搬走了，会自动回退到按盘符探测（老行为）。
-- ★ 中文安装路径直接弃用（见 _isAsciiPath 的说明），不让它带着乱码往下跑。
local INSTALLED_ROOT = "C:\\HEIBA\\q3"  --<<INSTALL_ROOT>>
local ASCII_ROOT = INSTALLED_ROOT
if not _isAsciiPath(ASCII_ROOT)
   or not _fileOk(ASCII_ROOT .. "\\resolve_bridge.py") then
    ASCII_ROOT = _probeRoot("\\HEIBA\\q3", "resolve_bridge.py")
                 or "C:\\HEIBA\\q3"
end

-- 三者共同的父目录（例 C:\HEIBA 或 D:\HEIBA）—— 用来推导另两处
local BASE_DIR = ASCII_ROOT:match("^(.*)\\[^\\]+$") or "C:\\HEIBA"

-- ── 自带 WAV 渲染预设（render_to_wav.xml）──────────────────────
-- ★ 为什么需要它：Resolve 内置的 'Audio Only' 预设在非英文版上名字是
--   本地化的（中文版叫"仅音频"），LoadRenderPreset 按显示名找 → 必失败；
--   而格式设不上时渲染作业会"成功"结束却零产出（实测：报一句
--   "未生成音频文件"，和真因八竿子打不着）。
--   官方 DaVinci ASR 的做法是 ImportRenderPreset 导入自带 XML，
--   格式写死在文件里，不依赖任何本地化名字 —— 照做。
-- 按顺序找：脚本所在目录（安装目录）→ 引擎目录 → 安装目录的常见位置。
local function _scriptDir()
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and type(info) == "table" and type(info.source) == "string" then
        local s = info.source
        if s:sub(1, 1) == "@" then s = s:sub(2) end
        local d = s:match("^(.*)[\\/][^\\/]*$")
        if d then return d end
    end
    return ""
end

local RENDER_PRESET_XML = ""
do
    local cands = {
        _scriptDir() ~= "" and (_scriptDir() .. "\\render_to_wav.xml") or nil,
        ASCII_ROOT .. "\\render_to_wav.xml",
        BASE_DIR .. "\\Qwen ASR\\render_to_wav.xml",
        "C:\\HEIBA\\q3\\render_to_wav.xml",
    }
    for _, p in ipairs(cands) do
        if p and _fileOk(p) then RENDER_PRESET_XML = p break end
    end
    -- 注意：此刻 ELog 还没定义（在 300 多行），这里不能调它
end

-- ══════════════════════════════════════════════════════════════
-- 运行环境（Python 解释器）解析
--
-- ★★ 独立性：绝不能被别的插件的安装/卸载带着一起坏。
--    早期版本曾共享过 DaVinci ASR 插件的 venv —— 对方一卸，
--    本插件所有按钮都失效，而且报的是"任务超时"这种误导信息。
--    现在运行环境完全自持：就在引擎目录下（q3\.venv）。
--
-- 解析顺序（第一个存在的就用）：
--   1) rt\settings.lua 里用户手动指定的（最高优先，永久记住）
--   2) 本插件自带的 venv：引擎目录 q3\.venv（当前默认）；
--      全新安装则由安装器装在 安装位置\Qwen ASR\.venv
--   3) 系统 Python 3.8~3.13（最后保障）
-- 全都不存在时 PYTHON = ""，各处给出明确错误而不是静默失败。
-- worker.py 里有一份同顺序的探测，两边保持一致。
-- ══════════════════════════════════════════════════════════════
local SETTINGS_FILE = ASCII_ROOT .. "\\rt\\settings.lua"

-- 从 settings.lua 里读 python 路径。
-- ★ 这里【不能】用后面的 loadLuaTable（定义在 300 行之后，此刻还是 nil），
--   所以用最笨的正则抠一行 —— 文件格式是我们自己写的，够用了。
-- ★ 反斜杠要归一化：我们自己写文件时用单反斜杠，但用户手改时很可能会
--   按 Lua 字符串的规矩写成 "\\HEIBA"（双反斜杠）。两种都要认，
--   否则用户明明填对了路径却"不生效"，极难排查。
local function readPySetting()
    if io == nil then return "" end
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return "" end
    local d = f:read("*all") or ""
    f:close()
    local p = d:match('python%s*=%s*"([^"]+)"')
    if not p then p = d:match("python%s*=%s*'([^']+)'") end
    if not p then return "" end
    if not _fileOk(p) then
        local flat = p:gsub("\\\\", "\\")
        if flat ~= p and _fileOk(flat) then return flat end
    end
    return p
end

local function pyCandidates()
    local out, seen = {}, {}
    local function add(p)
        if p and p ~= "" and not seen[p] then
            seen[p] = true
            out[#out + 1] = p
        end
    end

    -- 1) 用户手动指定（「关于 → 更改运行环境」写的就是这个文件）
    add(readPySetting())

    -- 2) 本插件自带的 venv（当前默认）：
    --    本机开发/搬迁后落在引擎目录下；全新安装则由安装器装在
    --    安装位置 \Qwen ASR\.venv（embeddable Python + torch）
    add(ASCII_ROOT .. "\\.venv\\Scripts\\python.exe")
    add(BASE_DIR .. "\\Qwen ASR\\.venv\\Scripts\\python.exe")

    -- 3) 系统 Python：按版本从新到旧逐个试。全是 _fileOk 探测，不闪窗
    local roots = {}
    local okEnv, la = pcall(os.getenv, "LOCALAPPDATA")
    if okEnv and type(la) == "string" and la ~= "" then
        roots[#roots + 1] = la .. "\\Programs\\Python"
    end
    roots[#roots + 1] = "C:\\"
    for _, r in ipairs(roots) do
        for _, v in ipairs({ "313", "312", "311", "310", "39", "38" }) do
            add(r .. "\\Python" .. v .. "\\python.exe")
        end
    end
    return out
end

local PYTHON = ""
for _, p in ipairs(pyCandidates()) do
    if _fileOk(p) then PYTHON = p break end
end
-- pythonw 优先（启动 worker 不闪窗）。名字不是预期形状时留空，
-- 各处用 exists(PYTHONW) and PYTHONW or PYTHON 兜底
local PYTHONW = ""
if PYTHON ~= "" then
    local w = PYTHON:gsub("[pP]ython%.exe$", "pythonw.exe")
    if w ~= PYTHON then PYTHONW = w end
end

-- 模型 / 字幕输出所在目录（含中文）。
-- ★ 这个目录【只有 Python 会碰】，Lua 一律不碰。
-- ★ 已删掉原先那个 `if BASE_DIR == "C:\\HEIBA" then TOOL_ROOT = "C:\\HEIBA\\Qwen字幕工具" end`：
--   它是 no-op —— BASE_DIR 为 "C:\HEIBA" 时上面这行拼出来的就是同一个字符串，
--   留着只会让人以为"老布局另有特殊处理"。
local TOOL_ROOT = BASE_DIR .. "\\Qwen字幕工具"

-- ★★ 凡是 Lua 会碰到的路径，必须全是 ASCII。
--    两条独立的坑，都会让中文路径变成 "Qwen瀛楀箷宸ュ叿"：
--      1) 命令行（os.execute / io.popen）按 GBK 解读 UTF-8 参数
--      2) Lua 的 io.open / exists() 在 Windows 上走 ANSI 接口
--    → 所以中间产物（源路径、状态、日志、导出的 WAV）全放 ASCII 目录。
--    中文素材路径本身没问题：它由 Python 写出、Python 读取，全程 Unicode。
--
-- ★★★ 这里【绝对不能】再写 `local ASCII_ROOT = "C:\\HEIBA\\q3"`！
--    文件顶部（第 75 行）已经声明过一次 ASCII_ROOT 并做了盘符探测：
--        优先用安装器替换过的 INSTALLED_ROOT，失败再 _probeRoot() 按盘符找。
--    Lua 的 local 在同一 block 里可以重复声明，后一个会【遮蔽】前一个 ——
--    一旦在这里再写死一次，从这行往下所有路径变量（PROBE_SCRIPT /
--    PROBE_WORK / BRIDGE / LAND_SCRIPT / SUBS_IO / EXPORT_SCRIPT /
--    ASR_SERVER / WORKER / MODEL_MANIFEST*）就全部指回 C 盘，
--    顶部的探测彻底白做。症状：插件装到 D 盘后模型目录还能找到
--    （TOOL_ROOT 走的是探测出来的 BASE_DIR），引擎脚本却一个都找不到，
--    报的错还会是"任务超时"这种和真因无关的话。
--    曾有此 bug，已删。改动本文件时注意别再"顺手补一行"。
local PROBE_SCRIPT = ASCII_ROOT .. "\\timeline_source.py"
local PROBE_WORK = ASCII_ROOT .. "\\rt"
local BRIDGE = ASCII_ROOT .. "\\resolve_bridge.py"
-- 落轨脚本：把 SRT 挂到时间线字幕轨 + 导入媒体池（逻辑全在 Python 侧）
local LAND_SCRIPT = ASCII_ROOT .. "\\land_subtitle.py"
-- 字幕存取桥：SRT ↔ Lua 表 / JSON。
--   SRT 放在中文目录里，Lua 的 io.open 打不开中文路径，所以读写都交给它。
local SUBS_IO = ASCII_ROOT .. "\\subs_io.py"
-- 导出脚本：把 srt / txt 复制到用户指定的文件夹
local EXPORT_SCRIPT = ASCII_ROOT .. "\\export_files.py"
-- ★ 常驻 ASR 服务：模型只加载一次，之后每次识别省掉 6~7 秒
--   它只是加速器，不在/崩了 resolve_bridge.py 会自动退回本地加载
local ASR_SERVER = ASCII_ROOT .. "\\asr_server.py"
-- 给常驻服务的"预热模型"文件（写本次用的模型路径，服务起来就装这个）
local SRV_PRELOAD = PROBE_WORK .. "\\asr_preload.txt"

-- ★★ 常驻后台执行器 worker.py
--   为什么需要它：见 worker.py 顶部说明。
--   一句话：os.execute 一定要经 cmd.exe，而 cmd.exe 被 Resolve 拉起时
--   会闪一个黑窗。worker 只在会话里启动一次（且用 pythonw，本身无窗），
--   之后它通过 CREATE_NO_WINDOW 启动任务，全程零窗口。
local WORKER = ASCII_ROOT .. "\\worker.py"
local CMD_FILE = PROBE_WORK .. "\\cmd.json"
local RES_FILE = PROBE_WORK .. "\\res.lua"
local WHB_FILE = PROBE_WORK .. "\\whb.lua"
-- worker 写下的"还活着的子进程 PID"。worker 不在时用它精确 taskkill，
-- 绝不退化成 taskkill /IM python.exe（那会把机器上所有 python 一起杀掉）
local PIDS_FILE = PROBE_WORK .. "\\pids.lua"

-- ★ 工作目录 = ASCII 目录。原来在中文目录里，导致 FindAudio 的
--   io.popen('dir /b ...') 和 io.open 全部失效（同一个编码坑的第三处）。
local WORK_DIR = PROBE_WORK
-- ★ PYTHON / PYTHONW 已在文件顶部「路径解析」里按盘符探测好了（可能不在 C 盘）

local LANGUAGES = {
    { "中文", "Chinese" },
    { "English", "English" },
    { "粤语", "Cantonese" },
    { "日语", "Japanese" },
    { "韩语", "Korean" },
    { "自动识别", "Auto" },
}
local MAX_CHARS_OPTS = { "16", "24", "32", "40", "50" }

-- 这些阶段表示"后台还有活儿在跑"。
-- ★ 导出按钮以前没有这道检查：识别途中点导出会把 phase 改成 exporting，
--   于是识别进度再也没人轮询，界面永远停在"识别中"。
local BUSY_PHASES = {
    probing = true, rendering = true, recognizing = true,
    landing = true, importing = true, exporting = true,
    -- 交付页就绪等待 + 格式配置（渲染前的准备相位，见 App:ConfigRender）
    render_cfg = true,
    -- 「更新字幕」之后的媒体池同步（见 App:StartLand 的 reason="sync"）
    syncing = true,
}

local App = {}
App.S = {
    phase = "idle",          -- idle | rendering | recognizing | done | error
    jobId = nil,
    renderStartedAt = 0,
    logLines = {},
    win = nil,
    dispatcher = nil,
    langCode = "Chinese",
    maxChars = 24,
    prompt = "",
    noGap = false,
    noPunct = false,
    allPunct = false,        -- 去除标点符号（行内标点也删）
    srt = WORK_DIR .. "\\subtitle.srt",
    -- ★ 状态文件和日志放【纯 ASCII】目录。
    --   Lua 要 exists()/tail() 读它们，而 io.open 走 ANSI API 打不开中文路径
    --   （实测：明明存在的文件被判定为不存在）。
    --   只有最终产出的 SRT 留在中文目录（那是给用户看的，Lua 不用读）。
    statusFile = PROBE_WORK .. "\\status.txt",
    logFile = PROBE_WORK .. "\\engine.log",
    -- 落轨（把字幕挂到时间线字幕轨）的两个中间文件
    landFile = PROBE_WORK .. "\\land.lua",
    landCfg  = PROBE_WORK .. "\\land.json",
    landStartedAt = nil,
    -- 识别完成后【自动导入媒体池】用的另一组文件
    --   （和落轨分开，避免两个流程互相读到对方的结果）
    importFile = PROBE_WORK .. "\\import.lua",
    importCfg  = PROBE_WORK .. "\\import.json",
    importStartedAt = nil,
    -- 导出用的中间文件
    exportFile = PROBE_WORK .. "\\export.lua",
    exportCfg  = PROBE_WORK .. "\\export.json",
    exportStartedAt = nil,
    -- worker 相关
    cmdId = 0,
    workerOk = nil,
    srtBase = "",
    txt = "",
    count = 0,
    pyStartedAt = nil,
    prevPage = nil,
    -- ★ 会话标识：每次运行本脚本都换一个，worker 靠 (sess,id) 去重。
    --   没有它的时候，第二次运行脚本发出的 id=1 会被 worker 当成
    --   上一次的重复命令【静默丢弃】→ 干等超时 → 回退 os.execute 闪黑窗。
    -- ★ 必须足够唯一：worker 按 (sess, id) 去重，sess 撞了会把
    --   新命令当"上一次的重复"静默丢掉 → 干等超时 → 回退闪黑窗。
    --   Lua 5.1 的 math.random 默认种子是固定的，光靠它同一秒内会重复，
    --   所以把 os.clock()（进程内高精度计时）也拼进去。
    sess = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
        .. "-" .. string.format("%06d", math.floor((os.clock() % 1) * 1000000)),
    -- 异步探测（读时间线素材）的起始时间
    probeStartedAt = nil,
    -- 常驻 ASR 服务是否已预热过（每次会话只预热一次）
    srvWarm = false,
    -- worker 保活 ping 的时间戳
    lastPingAt = 0,
    -- 上一次的状态文字（避免每 0.5 秒重复设置同一个 Label）
    lastStatus = nil,
    modelPath = "",

    -- ── 字幕编辑器 ──────────────────────────────────────────────
    subs = {},                 -- 当前字幕：{ {s=开始秒, e=结束秒, t=文本}, ... }
    subsLua = PROBE_WORK .. "\\subs.lua",        -- dump 输出（Lua 表）
    subsCfg = PROBE_WORK .. "\\subs_cfg.json",   -- 传给 subs_io.py 的配置
    subsJson = PROBE_WORK .. "\\subs_in.json",   -- 保存时上行给 Python 的数据
    subsPending = false,       -- 是否正在等 dump 结果
    subsStartedAt = nil,
    selRow = nil,              -- 当前选中的字幕行号
    -- ★ 代码主动改写编辑框内容时要置位，否则会触发 TextChanged，
    --   把同一段文字又回灌一遍（参考版本里的 suppressEditor 是同一作用）。
    suppressEdit = false,
    -- 表格里有改动，但还没写进 SRT
    subsDirty = false,
    -- ★ 代码主动改写【表格行】内容时要置位，否则会触发 Tree.ItemChanged，
    --   被当成"用户在格子里手改了字"，反复回写（B 方案的就地编辑防递归）。
    suppressTreeEdit = false,

    -- ── 查找高亮 ──────────────────────────────────────────────
    -- matchRows[k] = 第 k 处匹配所在的行号（一条字幕里出现多次算多处）
    -- matchTotal  = 匹配总处数；curMatch = 当前停在第几处
    matchKw = nil,
    matchRows = nil,
    matchTotal = 0,
    curMatch = nil,

    -- ── 子进程退出码回传（worker.py 写的 rc_<sess>_<id>.lua）───
    curTask = nil,               -- { id=, script=, rcFile=, log=, startedAt= }
    ignoreRc = false,            -- 用户主动「停止」时不拿退出码报错
}

-- ── 工具 ──────────────────────────────────────────────────────────
local function P(msg) print("[Qwen ASR] " .. tostring(msg)) end

-- 错误日志：写到文件。脚本闪退时 Console 看不到，只能靠文件。
local ERRLOG = BASE_DIR .. "\\Qwen ASR_error.log"
-- ★ ELog 缓冲：识别过程中每秒能产出十几条日志，每条都 open/close 一次
--   文件会白等一堆 IO。攒够 ELOG_FLUSH_N 条、或过了 ELOG_FLUSH_SEC 秒，
--   再一次写掉。ELogReset 和进程退出前会强制落盘，不会丢。
local ELOG_BUF, ELOG_AT = {}, os.time()   -- AT 初值取当前时刻，别让第一条就触发孤零零的一次落盘
local ELOG_FLUSH_N, ELOG_FLUSH_SEC = 20, 3
local function ELogFlush()
    if #ELOG_BUF == 0 then return end
    local f = io.open(ERRLOG, "a")
    if f then
        for _, l in ipairs(ELOG_BUF) do f:write(l .. "\n") end
        f:close()
    end
    ELOG_BUF = {}
    ELOG_AT = os.time()
end
local function ELog(msg)
    ELOG_BUF[#ELOG_BUF + 1] = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg)
    if #ELOG_BUF >= ELOG_FLUSH_N then
        ELogFlush()
    elseif os.time() - ELOG_AT >= ELOG_FLUSH_SEC then
        ELogFlush()
    end
end

local function ELogReset()
    ELOG_BUF = {}
    ELOG_AT = os.time()
    local f = io.open(ERRLOG, "w")
    if f then
        f:write("=== run " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
        f:close()
    end
end

-- ── 控件取值 ─────────────────────────────────────────────────────
--   ★★ Fusion 的 UI 属性名在不同版本上并不统一，这里统一从这里取：
--        · LineEdit  / TextEdit  → Text 和 PlainText 都试一遍
--        · CheckBox             → Checked（偶尔是数字），兜底 CheckState
--     之前只对输入框用 PlainText，结果 Resolve 21.1 的 LineEdit 读出来是
--     nil，字数设置一直 silently 走默认值 12 —— 用户改 50 也没反应。
--   ★ 每一步都包 pcall：GetItems() 返回的是 userdata，某些版本读不存在的
--     属性会直接抛错，那样整个按钮回调就废了（Fusion 还会静默吞异常）。
local function ctlGet(item)
    if item == nil then return nil, "nil-item" end
    local ok, v = pcall(function() return item.Text end)
    if ok and type(v) == "string" then return v, "Text" end
    ok, v = pcall(function() return item.PlainText end)
    if ok and type(v) == "string" then return v, "PlainText" end
    return nil, "unreadable"
end

local function ctlSet(item, s)
    if item == nil then return false end
    local ok1 = pcall(function() item.Text = s end)
    local ok2 = pcall(function() item.PlainText = s end)
    return ok1 or ok2
end

local function ctlChecked(item)
    if item == nil then return false, "nil-item" end
    local ok, v = pcall(function() return item.Checked end)
    if ok and type(v) == "boolean" then return v, "Checked" end
    if ok and type(v) == "number" then return v ~= 0, "Checked(num)" end
    ok, v = pcall(function() return item.CheckState end)
    if ok and type(v) == "number" then return v ~= 0, "CheckState(num)" end
    if ok and type(v) == "boolean" then return v, "CheckState" end
    return false, "unreadable"
end

-- ★ 写勾选状态：Checked 与 CheckState 两个属性都试一遍（v1.28 新增）。
--   实测日志里 AllPunct 走的是 "removed"（Checked 读不出来），说明 Fusion
--   的 CheckBox 在不同版本里可写属性并不一致：只看 Checked 会漏。
--   这里两条路都走，谁成功用谁；返回是否至少成功一次，供调用方记录。
local function setChecked(item, val)
    if item == nil then return false end
    local b = val and true or false
    local done = false
    -- 优先 Checked（语义最贴近）
    local ok1 = pcall(function() item.Checked = b end)
    if ok1 then done = true end
    -- 再补 CheckState（Qt 的枚举：0=未选中, 2=选中）
    local ok2 = pcall(function() item.CheckState = b and 2 or 0 end)
    if ok2 then done = true end
    return done
end

-- ══════════════════════════════════════════════════════════════
-- ★ 以下四个基础函数参考 AutoSubs（github.com/tmoroney/auto-subs）的实测结论。
--   该仓库实测：Resolve 21.1 的脚本 Lua 状态里
--     io / ffi / package / require / os.execute / bmd.readdir 可能是 nil
--   但
--     bmd.wait / bmd.fileexists / bmd.direxists / loadfile 一定可用
--   所以凡是与"等一等""文件在不在"有关的操作，一律优先走 bmd.*，
--   io.* 只作为兜底 —— 这样即使哪天换到被沙箱限制的环境也照样能跑。
-- ══════════════════════════════════════════════════════════════
local function waitSec(s)
    if type(bmd) == "table" and type(bmd.wait) == "function" then
        pcall(bmd.wait, s)
        return
    end
    -- ★ 兜底也绝不能启子进程：os.execute("ping ...") 会闪黑窗，
    --   而这个函数每次轮询都调（0.1 秒一次），闪起来根本没法用。
    --   改成纯 Lua 忙等（只在极端环境下才会走到，单次 0.1 秒，代价可接受）。
    local limit = tonumber(s) or 0.1
    if limit <= 0 then return end
    local t0 = os.clock()
    while (os.clock() - t0) < limit do end
end

local function exists(path)
    if type(bmd) == "table" and type(bmd.fileexists) == "function" then
        local ok, r = pcall(bmd.fileexists, path)
        if ok and r == true then return true end
    end
    if io == nil then return false end
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- ★ 用 loadfile 读"Lua 格式"的数据文件，而不是解析 JSON。
--   AutoSubs 的邮箱就是这么做的（request.lua 是一个 return {...} 的 chunk）。
--   好处：不用在 Lua 里做 JSON 模式匹配，中文/转义全部由 Lua 引擎自己处理。
--   返回一个 table；失败返回 nil。
local function loadLuaTable(path)
    if type(loadfile) ~= "function" then return nil end
    if not exists(path) then return nil end
    local ok1, chunk = pcall(loadfile, path)
    if not ok1 or type(chunk) ~= "function" then return nil end
    local ok2, t = pcall(chunk)
    if not ok2 or type(t) ~= "table" then return nil end
    return t
end

-- ══════════════════════════════════════════════════════════════
-- 设置持久化（rt\settings.lua）
--
-- 旧格式只有 python = "..." 一行（「关于 → 更改运行环境」写的），
-- 顶部的 readPySetting() 靠正则抠它 —— 所以 python 那一行
-- 【格式必须保持】，后面可以随便加键。
-- 现在扩成完整表：python + 界面七项 + 窗口 Geometry。
--   · 读：loadLuaTable + 逐项类型校验，脏值回默认（绝不崩）
--   · 写：tmp → remove → rename 原子写
--     （Windows 的 os.rename 不覆盖已存在的文件，必须先删）
--   · 保存时机：点「开始生成字幕」+ 关窗（自然提交点，
--     不依赖 ComboBox 的事件是否派发）
-- ══════════════════════════════════════════════════════════════
local SETTINGS_VER = 2
local DEFAULT_GEO = { 400, 80, 1030, 772 }
-- 每行宽度默认值：断句按【显示宽度】计（中文/全角=2，ASCII=1），
-- 24 ≈ 12 个汉字，和以前"每行 12 字"的观感一致。
local DEFAULT_MAX_CHARS = 24

-- 值 → Lua 字符串字面量（用户输入/控件值必须转义）
local function lstr(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "\\n")
    return '"' .. s .. '"'
end

local function readSettings()
    local d = {
        python = "", lang = 0, model = 0, model_path = "",
        max_chars = DEFAULT_MAX_CHARS, no_gap = false, all_punct = false,
        prompt = "", win = nil,
    }
    local t = loadLuaTable(SETTINGS_FILE)
    if type(t) ~= "table" then
        -- 旧格式 / 文件不存在：python 仍用正则抠（保持兼容）
        d.python = readPySetting()
        return d
    end
    if type(t.python) == "string" then d.python = t.python end
    local li = tonumber(t.lang)
    if li and li >= 0 and li < 16 and li == math.floor(li) then d.lang = li end
    local mi = tonumber(t.model)
    if mi and mi >= 0 and mi < 64 and mi == math.floor(mi) then d.model = mi end
    if type(t.model_path) == "string" then d.model_path = t.model_path end
    local mc = tonumber(t.max_chars)
    if mc and mc >= 4 and mc <= 200 then d.max_chars = math.floor(mc) end
    if type(t.no_gap) == "boolean" then d.no_gap = t.no_gap end
    if type(t.all_punct) == "boolean" then d.all_punct = t.all_punct end
    if type(t.prompt) == "string" then d.prompt = t.prompt end
    if type(t.win) == "table" and #t.win == 4 then
        local x, y, w, h = t.win[1], t.win[2], t.win[3], t.win[4]
        if type(x) == "number" and type(y) == "number"
           and type(w) == "number" and type(h) == "number"
           and w >= 760 and h >= 570 and w <= 4000 and h <= 3000 then
            d.win = { math.floor(x), math.floor(y), math.floor(w), math.floor(h) }
        end
    end
    return d
end

local function writeSettings(t)
    t = t or {}
    -- python 行保持旧格式（顶部 readPySetting 用正则抠它）
    local py = tostring(t.python or "")
    if py == "" then py = readPySetting() end
    local lines = {
        "-- Qwen ASR 设置（由插件自动保存；也可手改，别破坏 return{...} 结构）",
        "return {",
        "    ver = " .. SETTINGS_VER .. ",",
        "    python = " .. lstr(py) .. ",",
        "    lang = " .. tostring(math.floor(tonumber(t.lang) or 0)) .. ",",
        "    model = " .. tostring(math.floor(tonumber(t.model) or 0)) .. ",",
        "    model_path = " .. lstr(t.model_path) .. ",",
        "    max_chars = " .. tostring(math.floor(tonumber(t.max_chars) or DEFAULT_MAX_CHARS)) .. ",",
        "    no_gap = " .. ((t.no_gap and "true") or "false") .. ",",
        "    all_punct = " .. ((t.all_punct and "true") or "false") .. ",",
        "    prompt = " .. lstr(t.prompt) .. ",",
    }
    if type(t.win) == "table" and #t.win == 4 then
        lines[#lines + 1] = string.format(
            "    win = { %d, %d, %d, %d },",
            math.floor(t.win[1]), math.floor(t.win[2]),
            math.floor(t.win[3]), math.floor(t.win[4]))
    end
    lines[#lines + 1] = "}"
    local body = table.concat(lines, "\n") .. "\n"

    local tmp = SETTINGS_FILE .. "." .. tostring(os.time())
        .. tostring(math.floor((os.clock() or 0) * 1000)) .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(body)
    f:close()
    -- Windows rename 不覆盖已存在文件 → 先删再改名
    os.remove(SETTINGS_FILE)
    local ok = os.rename(tmp, SETTINGS_FILE)
    if not ok then pcall(os.remove, tmp) end
    return ok and true or false
end

local function ensureDir(path)
    if exists(path) then return end
    if type(bmd) == "table" and type(bmd.createdir) == "function" then
        if (pcall(bmd.createdir, path)) then return end
    end
    -- ★ 不用 os.execute('cmd /c mkdir') —— 会闪黑窗。
    --   真正需要的目录（PROBE_WORK）由 worker.py 启动时创建；
    --   这里退一步：写个占位文件把父目录带出来（父目录本来就该存在）。
    if io ~= nil then
        pcall(function()
            local f = io.open(path .. "\\.keep", "w")
            if f then f:write(""); f:close() end
        end)
    end
end

local function tail(path, n)
    if io == nil then return "" end
    local f = io.open(path, "rb")
    if not f then return "" end
    local size = f:seek("end")
    f:seek("set", math.max(0, size - n))
    local d = f:read("*all") or ""
    f:close()
    return d
end

local function osPath(p) return p:gsub("/", "\\") end

-- 列出目录里匹配「前缀 + 后缀」的文件名。
-- ★★ 绝不用 io.popen('cmd /c dir /b ...')：会闪黑窗。
--    优先 bmd.readdir（AutoSubs 实测可用，沙箱下可能是 nil），
--    拿不到就按 Resolve 的常见命名逐个试存在性。
local function listFiles(dir, prefix, suffix)
    local out = {}
    local lp, ls = prefix:lower(), suffix:lower()

    if type(bmd) == "table" and type(bmd.readdir) == "function" then
        local ok, files = pcall(bmd.readdir, dir)
        if ok and type(files) == "table" then
            for _, n in pairs(files) do
                local s = tostring(n)
                if s:lower():sub(1, #lp) == lp
                    and s:lower():sub(-#ls) == ls then
                    out[#out + 1] = s
                end
            end
        end
    end
    if #out > 0 then return out end

    -- 兜底：Resolve 导出重名时会追加 _1 / _2 …
    for i = 0, 6 do
        local nm = prefix .. (i == 0 and "" or ("_" .. i)) .. suffix
        if exists(dir .. "\\" .. nm) then out[#out + 1] = nm end
    end
    return out
end

-- ★ Lua 没有 sleep。优先 bmd.wait（精确到 0.05 秒，且不启子进程），
--   没有 bmd.wait 时才退回到 ping。
local function sleepMS()
    waitSec(0.1)
end

-- 读取模型清单（Lua 不能列目录，Python 侧会生成这个文件）
--
-- ★★ 路径必须在【ASCII 目录】。改之前的两个问题：
--   ① 清单原本指向 TOOL_ROOT（C:\HEIBA\Qwen字幕工具\models.txt，中文），
--      而 Python 写的是 C:\HEIBA\q3\models.txt —— 两边根本不是同一个文件；
--   ② 就算指对了，Windows 下 Lua 的 io.open 走 ANSI 接口，中文路径打不开。
--   结果：模型下拉框永远只有硬编码的默认一项，装了新模型也看不到。
-- ★ 现在优先读 models.lua（loadfile 加载，连 io.open 都不需要）。
local MODEL_MANIFEST = ASCII_ROOT .. "\\models.txt"
local MODEL_MANIFEST_LUA = ASCII_ROOT .. "\\models.lua"
local DEFAULT_MODEL = "Qwen3-ASR-0.6B-hf"

-- 读模型清单。返回 {{name=.., path=..}, ...}
--   ★ path 由 Python 直接给出完整路径：模型不一定装在默认目录，
--     让 Lua 去拼 TOOL_ROOT\models\<名字> 的话，拼错就静默回退默认模型。
local function readModels()
    local out = {}
    local t = loadLuaTable(MODEL_MANIFEST_LUA)
    if t then
        for _, v in ipairs(t) do
            if type(v) == "table" then
                local n = tostring(v.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local p = tostring(v.path or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if n ~= "" then
                    out[#out + 1] = { name = n, path = (p ~= "" and p or nil) }
                end
            else
                -- 兼容旧格式（纯字符串数组）：只能靠拼
                local s = tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if s ~= "" then out[#out + 1] = { name = s, path = nil } end
            end
        end
        if #out > 0 then return out end
    end
    -- 兜底：读纯文本清单
    if io == nil then
        return { { name = DEFAULT_MODEL, path = nil } }
    end
    local f = io.open(MODEL_MANIFEST, "r")
    if not f then return { { name = DEFAULT_MODEL, path = nil } } end
    for line in f:lines() do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then out[#out + 1] = { name = s, path = nil } end
    end
    f:close()
    if #out == 0 then return { { name = DEFAULT_MODEL, path = nil } } end
    return out
end

-- 取清单里所有模型名（填下拉用）
local function pickModelNames(list)
    local names = {}
    for i, m in ipairs(list or {}) do names[i] = m.name end
    return names
end

-- ── 启动 ──────────────────────────────────────────────────────────
-- ── 环境自检 ────────────────────────────────────────────────────────
--   把"工具在哪、环境在不在"先摸一遍。换了电脑 / 挪了目录 / 重装了
--   DaVinci 之后，这些信息第一时间就能告诉你是哪里没对上，
--   而不是点半天没反应还不知道为什么。
--   ★ 只检查 ASCII 路径 —— 中文目录（模型）Lua 在 Windows 上探不了。
function App:SelfCheck()
    local report, bad = {}, {}
    report[#report + 1] = "引擎目录 " .. ASCII_ROOT
    report[#report + 1] = "运行环境 " .. PYTHON
    report[#report + 1] = "模型目录 " .. TOOL_ROOT .. "\\models"

    if not exists(ASCII_ROOT .. "\\resolve_bridge.py") then
        bad[#bad + 1] = "引擎脚本缺失：" .. ASCII_ROOT .. "\\resolve_bridge.py"
    end
    if not exists(PYTHON) then
        bad[#bad + 1] = "Python 环境缺失：" .. PYTHON
    end

    for _, s in ipairs(report) do ELog("  [路径] " .. s) end
    App.S.pathReport = report
    App.S.pathBad = bad
    if #bad > 0 then
        ELog("!! 环境自检发现 " .. #bad .. " 处问题")
        for _, s in ipairs(bad) do ELog("   - " .. s) end
    else
        ELog("环境自检通过")
    end
    return #bad == 0
end

function App.OnRun()
    ELogReset()
    ELog("OnRun 开始")
    pcall(function() App:SelfCheck() end)

    local ok, err = pcall(function()
        local r = resolve
        if not r and type(Resolve) == "function" then r = Resolve() end
        ELog("resolve = " .. tostring(r))
        if not r then ELog("中止：无法获取 resolve"); return end
        App.resolve = r          -- ★ 必须保存！StartRender 里要用

        local pm = r:GetProjectManager()
        ELog("projectManager = " .. tostring(pm))
        if not pm then ELog("中止：GetProjectManager 返回空"); return end

        local project = pm:GetCurrentProject()
        ELog("project = " .. tostring(project))
        if not project then ELog("中止：请先打开一个项目"); return end
        App.project = project

        local timeline = project:GetCurrentTimeline()
        ELog("timeline = " .. tostring(timeline))
        if not timeline then ELog("中止：请先打开一个时间线"); return end
        App.timeline = timeline
        App.tlName = timeline:GetName() or "未命名"
        ELog("timelineName = " .. tostring(App.tlName))

        local fusion = r:Fusion()
        ELog("fusion = " .. tostring(fusion))
        if not fusion then ELog("中止：resolve:Fusion() 返回空"); return end

        local ui = fusion.UIManager
        ELog("UIManager = " .. tostring(ui))
        if not ui then ELog("中止：fusion.UIManager 为空"); return end

        ELog("bmd = " .. tostring(bmd))
        if not bmd then ELog("中止：bmd 全局为空"); return end

        local dispatcher = bmd.UIDispatcher(ui)
        ELog("dispatcher = " .. tostring(dispatcher))
        if not dispatcher then ELog("中止：UIDispatcher 返回空"); return end
        App.S.dispatcher = dispatcher

        -- 注意：不在这里 mkdir（会闪 CMD 窗口），改由 Python 侧创建目录
        ELog("进入 BuildUI")
        App:BuildUI(ui, dispatcher)
        ELog("BuildUI 返回（RunLoop 已退出）")
    end)

    if not ok then
        ELog("!!! OnRun 异常: " .. tostring(err))
        P("脚本错误: " .. tostring(err))
    end
    ELog("OnRun 结束")
end

-- ── 「关于」里的全部说明文字 ────────────────────────────────────────
--   ★ 以前这些是散在界面上的一行行小字，窗口一窄就被截断。
--     现在统一收进左下角的「关于」弹窗，主界面只留控件。
--   ★ 排版约定：节标题用【】，正文缩进两格，说明文字用 · 引导，
--     打开等宽字体后各列自然对齐（窗口建时给 AboutText 设了字体）。
local ABOUT_TEXT = [[
关于 Qwen ASR                                            版本 v1.28

【是什么】
  DaVinci Resolve 字幕插件：用本机显卡运行 Qwen3-ASR 语音识别，
  为时间线一键生成字幕。音频不联网，全部在本机处理。

【怎么用】
  1  打开一条含音频的时间线
  2  菜单：工作区 → 脚本 → 工具 → Qwen ASR
  3  选语言、每行宽度（中文建议 20~32）→ 开始生成字幕
  4  点「适配字幕」，字幕自动挂到新时间线，原时间线不动
     字幕同时导入媒体池，并保存在 字幕输出\ 目录

【改字幕】
  点右侧任意一行，下方编辑框直接改，改完点「更新字幕」。
  更新会自动写回 SRT 文件并同步媒体池，不用手动导来导去。

【查找替换】
  右上方输入关键词，命中的字幕行立刻高亮；
  「查找下一个」滚动跳转，播放头同步跳到对应位置。
  状态栏的「第 X / Y 处」是第几个重复出现，不是行号。

【运行环境】
  本页顶部显示当前在用的 Python 与 torch / transformers 版本。
  · 换环境：点「更改…」选一个 venv 或 Python 目录，重启插件后生效
  · 不依赖其他插件：别的字幕插件装卸卸载，都不影响本插件
  · 同一素材重复识别会命中音频缓存，第二次明显更快

【出问题看这里】
  脚本列表为空      完全退出 Resolve，再重新打开
  读取时间线失败    首选项 → 系统 → 常规 → 外部脚本使用，
                    设为「本地」或「网络」
  识别失败          子进程日志在 rt\logs\，出错时界面日志
                    会直接给出对应的文件路径
  任务卡住不动      看界面日志最后两行；子进程一出事会当场报错，
                    不用干等超时
]]

-- 秒 → "mm:ss.cc" / "h:mm:ss.cc"
local function fmtSec(x)
    x = tonumber(x) or 0
    if x < 0 then x = 0 end
    local h = math.floor(x / 3600)
    local m = math.floor((x % 3600) / 60)
    local s = x % 60
    if h > 0 then
        return string.format("%d:%02d:%05.2f", h, m, s)
    end
    return string.format("%02d:%05.2f", m, s)
end

-- 把表格里手敲的时间文本解析回「秒」。解析不了返回 nil —— 调用方会把该格
-- 还原成原值。支持 "SS.mm" / "MM:SS.mm" / "H:MM:SS.mm"，逗号当小数点。
local function parseTimeText(s)
    local raw = tostring(s or ""):gsub("%s", ""):gsub(",", ".")
    if raw == "" then return nil end
    local parts = {}
    for p in raw:gmatch("[^:]+") do parts[#parts + 1] = p end
    if #parts == 0 or #parts > 3 then return nil end
    local nums = {}
    for i, p in ipairs(parts) do
        if not p:match("^%d+%.?%d*$") then return nil end
        nums[i] = tonumber(p)
        if not nums[i] then return nil end
    end
    if #nums == 1 then return nums[1] end
    if #nums == 2 then return nums[1] * 60 + nums[2] end
    return nums[1] * 3600 + nums[2] * 60 + nums[3]
end

-- ── 界面 ──────────────────────────────────────────────────────────
-- 把当前界面值收集成设置表（读控件的优先级和「开始」按钮一致：
-- 变更事件备份 → 直接读控件 → 默认值），供保存用。
function App:CurrentSettings()
    local it = App.S.items or {}
    local snap = App.S.uiSnap or {}
    local t = {
        lang = 0, model = 0, model_path = "",
        max_chars = DEFAULT_MAX_CHARS,
        no_gap = false, all_punct = false, prompt = "",
    }
    pcall(function()
        t.lang = math.floor(tonumber(it.LangCombo and it.LangCombo.CurrentIndex or 0) or 0)
        t.model = math.floor(tonumber(it.ModelCombo and it.ModelCombo.CurrentIndex or 0) or 0)
    end)
    -- ★ 同样改成【控件优先】（v1.28）：保存时要存用户当前在框里看到的那个值。
    --   旧写法 snap 优先 → 用户清空自定义模型路径后，保存下来的还是旧路径。
    local mpTxt = ctlGet(it.ModelPathEdit)
    local mp = (mpTxt ~= nil) and mpTxt or (snap.model or "")
    if type(mp) ~= "string" then mp = "" end
    t.model_path = mp:gsub("^%s+", ""):gsub("%s+$", "")
    -- ★ 同样改成【控件优先】：保存时要存用户当前在框里看到的那个值，
    --   不能存快照里的旧值（否则下次打开又变回 24，改了等于没改）。
    local mcTxt = ctlGet(it.MaxEdit)
    if not mcTxt or mcTxt == "" then mcTxt = snap.max or "" end
    local mc = tonumber(mcTxt)
    if mc and mc >= 4 and mc <= 200 then t.max_chars = math.floor(mc) end
    -- ★ 空串也要当成有效值：用户把短语框清空 = 不要热词了，
    --   旧写法 `ptTxt ~= ""` 会把空串当成"读不到"，于是又把旧短语存回去，
    --   清空操作永远不生效。
    local ptTxt = ctlGet(it.PromptEdit)
    t.prompt = (ptTxt ~= nil) and ptTxt or (snap.prompt or "")
    -- ★ 勾选框同样【控件真值优先】，快照只在读不出来时才兜底
    local ng, ngSrc = ctlChecked(it.NoGap)
    if ngSrc == "unreadable" and snap.gap ~= nil then ng = snap.gap end
    t.no_gap = ng and true or false
    local na, naSrc = ctlChecked(it.AllPunct)
    if naSrc == "unreadable" and snap.punctAll ~= nil then na = snap.punctAll end
    t.all_punct = na and true or false
    return t
end

-- 保存设置（界面七项 + 窗口 Geometry）。失败只记日志，不打断用户。
function App:SaveSettingsNow()
    local ok, err = pcall(function()
        local t = self:CurrentSettings()
        local g = nil
        pcall(function() g = App.S.win and App.S.win.Geometry end)
        if type(g) == "table" and #g == 4 then t.win = g end
        if not writeSettings(t) then
            ELog("!! 设置保存失败（写不进 " .. SETTINGS_FILE .. "）")
        end
    end)
    if not ok then ELog("!! 保存设置异常: " .. tostring(err)) end
end

function App:BuildUI(ui, dispatcher)
    -- 窗口尺寸：上次记住的就用上次的（含用户拖动后的位置/大小），
    -- 没有记录才用默认 4:3。readSettings 里已校验过范围。
    local cfg = readSettings()
    local geo = cfg.win or DEFAULT_GEO

    -- 所有控件都必须有 ID；ComboBox 的内容在 GetItems 之后再填（官方模式）
    -- ★ Geometry 顺序是 { x, y, 宽, 高 }，不是 {宽,高,x,y}！
    local win = dispatcher:AddWindow({
        ID = "QwenASRTool",
        WindowTitle = "Qwen ASR",
        -- ★ 窗口可以随时拖边框放大/缩小（日志区会自动跟着变高）。
        --   默认尺寸按用户拍板：宽 : 高 = 4 : 3。宽度沿用截图换算值 1030，
        --   高度 = 1030 × 3 / 4 ≈ 772（原来的 950 上下太空）。
        Geometry = geo,
        Spacing = 8,
        -- ★ 千万【不要】在这里给控件设 min-height。
        --   所有控件的最小高度加总以后，一旦超过窗口的可用高度，
        --   Qt 布局就压不下去，超出部分直接越界重叠 ——
        --   实测过：QTextEdit 90px × 2 + QTreeView 200px 就是元凶，
        --   窗口一缩小，左栏的文本框、按钮、日志区就叠在一起。
        --   这里只管字号，高度交给布局按 Weight 自己分。
        StyleSheet = [[
            QWidget { font-size: 13px; }
            /* 「适配字幕」真能挂的时候才强调一下。没字幕可挂时它是
               disabled，由 Qt 自己画成灰的，不覆盖 disabled 的观感。
               注：这条靠 objectName 命中 #LandBtn；命中不了就是空操作，
               不影响任何功能，按钮的可用/禁用照样由 Enabled 决定。 */
            QPushButton#LandBtn:enabled { background-color: rgba(70, 110, 145, 210); }
            /* ★ 时间码块（StatusTC）：只读 LineEdit，去掉边框和底色，
               让它看起来就是一行普通文字，但可以被选中复制。
               位置提示仍是 Label，保持"不可复制"的观感。 */
            QLineEdit#StatusTC {
                border: none;
                background: transparent;
                padding: 0px;
                /* ★ 时间码 00:00:00:00 共 10 个字符，宽度必须给足，
                   否则只读输入框内容为空时布局会把宽度压到几乎 0 而截断。
                   两条路都写，谁生效都行：
                   ① qproperty-minimumWidth —— 直接设 QWidget 的
                      minimumWidth 属性【最可靠】，Fusion 的 LineEdit
                      对纯 CSS 的 min-width 支持有限（92px 实测没撑开）；
                   ② min-width —— CSS 兜底。
                   另：等宽字体让数字对齐好读，且比比例字体更省宽度。 */
                qproperty-minimumWidth: 115;
                min-width: 115px;
                font-family: "Consolas", "Cascia Mono", monospace;
                font-size: 12px;
            }
        ]],
    }, ui:VGroup{ ID = "Root", Spacing = 8,
        ui:Label{ ID = "Title", Text = "Qwen ASR", Weight = 0 },
        ui:Label{ ID = "TlName", Text = "时间线：" .. tostring(self.tlName), Weight = 0 },
        ui:VGap(4),

        -- ══ 左右两栏：左＝从音频创建字幕，右＝字幕编辑 ══
        ui:HGroup{ ID = "MainSplit", Weight = 1, Spacing = 10,

            ui:VGroup{ ID = "LeftCol", Weight = 0.44, Spacing = 6,
                ui:Label{ ID = "SecCreate", Text = "从音频创建字幕", Weight = 0 },
                ui:HGroup{ ID = "RowLang", Weight = 0,
                    ui:Label{ ID = "LangLabel", Text = "语言", Weight = 0.25 },
                    ui:ComboBox{ ID = "LangCombo", Weight = 0.75 },
                },
                ui:HGroup{ ID = "RowModel", Weight = 0,
                    ui:Label{ ID = "ModelLabel", Text = "识别模型", Weight = 0.25 },
                    ui:ComboBox{ ID = "ModelCombo", Weight = 0.75 },
                },
                ui:HGroup{ ID = "RowModelPath", Weight = 0,
                    ui:Label{ ID = "PathLabel", Text = "自定义模型路径", Weight = 0.25 },
                    ui:LineEdit{ ID = "ModelPathEdit", Weight = 0.62,
                                 Events = { TextChanged = true } },
                    ui:Button{ ID = "ModelBrowseBtn", Text = "浏览…", Weight = 0.13 },
                },
                ui:HGroup{ ID = "RowMax", Weight = 0,
                    ui:Label{ ID = "MaxLabel", Text = "每行字数限制", Weight = 0.25 },
                    -- ★ TextChanged 必须显式开：LineEdit 的事件不是全默认派发
                    --   （Tree 的 ItemDoubleClicked 就是这么坑过一次）。
                    --   宽度口径：中文/全角字符算 2，英文数字算 1（默认 24
                    --   ≈ 12 个汉字）。断句严格不超过这个宽度。
                    ui:LineEdit{ ID = "MaxEdit", Weight = 0.75,
                                 Events = { TextChanged = true } },
                },
                -- ★ 已按需求移除「句末去标点」勾选项（与「去除标点符号」重复度高）。
                -- ★ 两个勾选框都显式开 Toggled：下面绑了 win.On.NoGap.Toggled /
                --   AllPunct.Toggled 来同步 uiSnap 快照。不开的话那两个绑定
                --   永远不触发，快照会一直停在开窗时的旧值。
                --   （不致命：勾选状态读取走 ctlChecked 控件优先，快照只在
                --    读不出来时兜底；但留着死绑定迟早误导人。）
                ui:HGroup{ ID = "RowOpt", Weight = 0,
                    ui:CheckBox{ ID = "NoGap", Text = "字幕无间隙", Weight = 0.5,
                                 Events = { Toggled = true } },
                    ui:CheckBox{ ID = "AllPunct", Text = "去除标点符号", Weight = 0.5,
                                 Events = { Toggled = true } },
                },
                ui:Label{ ID = "PromptLabel", Text = "短语列表 / 提示", Weight = 0 },
                -- ★ TextChanged 必须显式开！TextEdit 的事件同样不是全默认派发，
                --   不开的话下面绑的 win.On.PromptEdit.TextChanged 永远不会触发。
                --   （这不是致命问题 —— 读取短语走的是"控件优先、快照仅兜底"，
                --    但那份兜底快照会一直是旧值，等于白绑。）
                ui:TextEdit{ ID = "PromptEdit", Weight = 0.5,
                             Events = { TextChanged = true } },
                -- ★ 「开始生成字幕」和「停止」改成【左右并排】（原来上下排）。
                ui:HGroup{ ID = "RowRun", Weight = 0,
                    ui:Button{ ID = "StartBtn", Text = "开始生成字幕", Weight = 1 },
                    ui:Button{ ID = "StopBtn", Text = "停止", Weight = 1 },
                },
                -- ★ 状态栏拆成两块（按用户要求）：
                --   Status   = 「第 X / Y 处」—— 用 Label，
                --             纯提示，不要求复制（Label 文字本来就选不中）。
                --             （「（第 N 行）」已按需求去掉）
                --   StatusTC = 时间码「HH:MM:SS:FF」—— 用只读 LineEdit，
                --             只有这一段需要能被选中复制走。
                --   「播放头」三个字已按需求去掉，只留时间码本身。
                -- ★ Weight 也给一点（不再写死 0）：只读输入框内容为空时
                --   sizeHint 会退化到很窄，仅靠样式兜底不稳。给 0.35 让它
                --   按布局分到一份基础宽度，配合上面的 minimumWidth 双保险；
                --   Status 仍是 1，占主要空间，显示「第 X / Y 处」不受影响。
                ui:HGroup{ ID = "RowStatus", Weight = 0, Spacing = 6,
                    ui:Label{ ID = "Status", Text = "就绪", Weight = 1 },
                    ui:LineEdit{ ID = "StatusTC", Text = "",
                                 ReadOnly = true, Weight = 0.35 },
                },
                ui:TextEdit{ ID = "LogEdit", ReadOnly = true, Weight = 1 },
            },

            ui:VGroup{ ID = "RightCol", Weight = 0.56, Spacing = 6,
                ui:HGroup{ ID = "RowEditHead", Weight = 0,
                    ui:Label{ ID = "SecEdit", Text = "字幕编辑", Weight = 0.5 },
                    ui:Button{ ID = "LoadPoolBtn", Text = "读取媒体池字幕", Weight = 0.5 },
                },
                ui:HGroup{ ID = "RowFind", Weight = 0,
                    ui:LineEdit{ ID = "FindInput", PlaceholderText = "查找文本",
                                 Weight = 1, Events = { TextChanged = true } },
                    ui:Button{ ID = "FindNextBtn", Text = "查找下一个", Weight = 0 },
                    ui:LineEdit{ ID = "ReplaceInput", PlaceholderText = "替换文本",
                                 Weight = 1, Events = { TextChanged = true } },
                    ui:Button{ ID = "ReplaceAllBtn", Text = "全部替换", Weight = 0 },
                    ui:Button{ ID = "ReplaceOneBtn", Text = "替换", Weight = 0 },
                },
                ui:Tree{ ID = "SubTree", ColumnCount = 4,
                         AlternatingRowColors = true, SortingEnabled = false,
                         -- ★ 长字幕会换行显示，行高必须允许变化：
                         --   UniformRowHeights = true 时行高被钉死，字幕超过
                         --   一列宽度就只显示开头几个字（直接被截断）。
                         WordWrap = true, UniformRowHeights = false,
                         HorizontalScrollMode = true,
                         SelectionMode = "SingleSelection",
                         -- ★★★ 官方文档里 Tree 的事件【默认开关不一样】：
                         --   CurrentItemChanged / ItemClicked  默认【开】
                         --   ItemDoubleClicked / ItemChanged   默认【关】！
                         --   不在这里显式打开，事件【永远不会派发】——
                         --   症状就是"双击毫无反应"。上次漏掉的就是这一句。
                         Events = { ItemClicked = true,
                                   ItemDoubleClicked = true, ItemChanged = true },
                         Weight = 1 },
                -- ★★★ 双击表格里的一行，光标会自动跳进这个编辑框并全选，
                --   改的时候上面那一行同步跟着变；改完点「更新字幕」落盘。
                --   （A 方案：表格本身只读时的唯一改字入口。）
                -- ★★★ Events 必须显式写 TextChanged！这是修掉的一个真 bug：
                --   TextEdit 的 TextChanged 不是默认派发的（和 Tree 的
                --   ItemDoubleClicked 一样要显式打开）。不写这一句，
                --   下面第 ~1584 行绑的 win.On.SubEdit.TextChanged 永远不触发，
                --   而 UpdateSubRow 的注释明确写着"这个按钮【不管】提交编辑，
                --   它只负责保存" —— 结果就是【改完字幕点更新，静默保存旧文本】，
                --   编辑丢失且不报错。作者注释里"编辑框是实时同步的"
                --   全靠这个事件。
                ui:TextEdit{ ID = "SubEdit", Weight = 0.22,
                             Events = { TextChanged = true } },
                ui:HGroup{ ID = "RowSave", Weight = 0,
                    -- 「更新字幕」= 写回 SRT 文件 + 自动同步媒体池，两步一次跑完
                    ui:Button{ ID = "UpdateSubsBtn", Text = "更新字幕", Weight = 1 },
                },
                ui:HGroup{ ID = "RowAct", Weight = 0,
                    ui:Button{ ID = "LandBtn", Text = "适配字幕", Weight = 0.5 },
                    ui:Button{ ID = "TxtBtn", Text = "导出 TXT 文稿", Weight = 0.5 },
                },
            },
        },

        -- ★ 左下角「关于」：必须用「按钮 Weight=0 + 空 Label Weight=1」当弹簧
        --   才能把它顶到窗口最左边。★ 注意 Alignment 只调按钮【内部文字】的
        --   对齐，不会移动按钮本身 —— 上次正是踩了这个坑：按钮在 VGroup 里
        --   被拉满整栏宽度，看着就落在"左栏中间下面"，怎么设 AlignLeft 都没用。
        ui:HGroup{ ID = "RowAbout", Weight = 0, Spacing = 6,
            ui:Button{ ID = "AboutBtn", Text = "关于",
                       Alignment = { AlignLeft = true, AlignVCenter = true },
                       Font = ui:Font{ PixelSize = 12 },
                       Flat = true, Weight = 0 },
            ui:Label{ ID = "AboutSpacer", Text = "", Weight = 1 },
        },
    })

    if not win then
        ELog("!! AddWindow 返回空")
        return
    end
    App.S.win = win
    App.S.ui = ui            -- 「关于」弹窗要用同一个 UIManager 建窗口
    -- ★ 给窗口一个最小尺寸：拖得再小也不会把控件挤到重叠。
    --   （之前是靠在 StyleSheet 里给控件设 min-height 防重叠，结果反过来
    --     把布局撑爆 —— 现在改成限制【窗口】本身的最小尺寸，方向才对。）
    pcall(function() win.MinimumSize = { 760, 570 } end)
    ELog("窗口已创建")

    -- ★ 必须用 GetItems() 取控件，不能用 win.StartBtn
    local okItems, items = pcall(function() return win:GetItems() end)
    if not okItems or not items then
        ELog("!! GetItems 失败: " .. tostring(items))
        return
    end
    App.S.items = items
    ELog("GetItems 成功")

    -- 环境自检结果写进界面日志（现在 Log 已经能用了）
    --   路径没问题时只说一句；有问题就把三处路径全列出来，方便对照。
    do
        local bad = App.S.pathBad or {}
        if #bad > 0 then
            self:Log("环境自检：有 " .. #bad .. " 处路径不对")
            for _, s in ipairs(bad) do self:Log("  · " .. s) end
            self:Log("  · 工具被移动过？点左下角「关于」看怎么改")
        else
            for _, s in ipairs(App.S.pathReport or {}) do
                ELog("    " .. s)
            end
        end
    end

    -- ★ AddItems 必须传【表格】，不能逐个传字符串（官方用法）
    local langNames = {}
    for _, it in ipairs(LANGUAGES) do table.insert(langNames, it[1]) end
    local modelList = readModels()
    local modelNames = pickModelNames(modelList)

    local okFill, fillErr = pcall(function()
        items.LangCombo:AddItems(langNames)
        items.ModelCombo:AddItems(modelNames)
        items.LangCombo.CurrentIndex = 0      -- 中文
        items.ModelCombo.CurrentIndex = 0     -- 第一个可用模型
        local okInit = ctlSet(items.MaxEdit, "24")    -- 默认每行宽度 24（≈12 汉字）
        ELog("MaxEdit 默认值写入 ok=" .. tostring(okInit)
            .. " 读回=" .. tostring(select(1, ctlGet(items.MaxEdit))))
    end)
    ELog("下拉项填充 ok=" .. tostring(okFill) .. " err=" .. tostring(fillErr))
    ELog("可选模型: " .. table.concat(modelNames, ", "))

    -- ★★ 第二道保险：用【变更事件】备份用户输入。
    --   万一某种 Resolve 版本连 Text / PlainText 都读不出来（这里是真的踩过：
    --   字数选项一直 silently 用默认的 12），只要用户在框里打过字，我们就
    --   把它记进 uiSnap —— 控件真值读不出来时才用这份数据。
    --   整体包 pcall：不支持的事件绑不上也只是没这份备份，不影响其它功能。
    --
    --   ★★ 更正（v1.28）：老写法是 `function(_, ...) snatch(k, ...)`，指望
    --      事件把新文本当参数带过来 —— 但官方文档写得很清楚：事件回调只收到
    --      一个属性字典（who / what / when / sender / modifiers），
    --      TextChanged【不带文本字段】。所以 select(1, ...) 恒为 nil，
    --      这份"第二道保险"从来没生效过，是死代码。
    --      要备份只能在这里【回读控件本身】。
    App.S.uiSnap = { max = "", prompt = "", model = "", gap = nil, punct = nil,
                     punctAll = nil }
    pcall(function()
        local function snatch(key, item)
            local v = ctlGet(item)
            if type(v) == "string" then
                App.S.uiSnap[key] = v
            end
        end
        local okEv = pcall(function()
            win.On.MaxEdit.TextChanged = function() snatch("max", items.MaxEdit) end
            win.On.PromptEdit.TextChanged = function() snatch("prompt", items.PromptEdit) end
            win.On.ModelPathEdit.TextChanged = function() snatch("model", items.ModelPathEdit) end
        end)
        ELog("输入框 TextChanged 绑定 ok=" .. tostring(okEv))

        -- CheckBox 的 Toggled 可能把勾选状态作为参数传进来；不同版本参数
        -- 位置不一样，干脆遍历一遍找一个 boolean。
        local function boolArg(...)
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                if type(v) == "boolean" then return v end
            end
            return nil
        end
        local okTg = pcall(function()
            win.On.NoGap.Toggled = function(_, ...)
                App.S.uiSnap.gap = boolArg(...)
            end
            win.On.AllPunct.Toggled = function(_, ...)
                App.S.uiSnap.punctAll = boolArg(...)
            end
        end)
        ELog("勾选框 Toggled 绑定 ok=" .. tostring(okTg))
    end)

    -- ★ 应用上次保存的设置（值已在 readSettings 里校验过类型/范围）。
    --   放在 uiSnap 建立之后：备份表也要同步，否则"读不回控件"的版本
    --   会把界面值当成空，点开始时又跳回默认值。
    pcall(function()
        if cfg.lang >= 0 and cfg.lang < #LANGUAGES then
            items.LangCombo.CurrentIndex = cfg.lang
        end
        if cfg.model >= 0 and cfg.model < #modelNames then
            items.ModelCombo.CurrentIndex = cfg.model
        end
        if cfg.model_path ~= "" then
            ctlSet(items.ModelPathEdit, cfg.model_path)
        end
        ctlSet(items.MaxEdit, tostring(cfg.max_chars))
        ctlSet(items.PromptEdit, cfg.prompt)
        -- ★★ 回填勾选框时【绝不能同步写 uiSnap】—— 这是 v1.28 修掉的真 bug：
        --    旧代码在这里写了 uiSnap.gap / uiSnap.punctAll，而点「开始」时
        --    snap 又【无条件覆盖】控件真值（见下方 snap.gap ~= nil 那两行），
        --    结果：开窗回填的瞬间快照就被钉死成 false，用户之后手动勾选
        --    虽然 Toggled 会更新快照，但只要读取仍走"快照优先"，
        --    表现就是「勾了没效果」。日志实证：勾选读取 gap=false(Checked)。
        --    现在：uiSnap 只由 Toggled 事件写，回填只动控件，快照不碰。
        setChecked(items.NoGap, cfg.no_gap)
        setChecked(items.AllPunct, cfg.all_punct)
        App.S.uiSnap.max = tostring(cfg.max_chars)
        App.S.uiSnap.prompt = cfg.prompt
        App.S.uiSnap.model = cfg.model_path
        -- gap / punctAll 故意不在这里写：让 Toggled 成为唯一写入源。
        ELog(string.format(
            "已恢复设置: lang=%d model=%d path=%q max=%d gap=%s punct=%s",
            cfg.lang, cfg.model, cfg.model_path, cfg.max_chars,
            tostring(cfg.no_gap), tostring(cfg.all_punct)))
    end)

    -- ★ 按钮初始状态必须在拿到控件后显式设置
    --   （写在构造函数里的 Enabled 不可靠，实测会显示反）
    ELog("Enabled 类型检查: StartBtn.Enabled=" .. type(items.StartBtn and items.StartBtn.Enabled)
        .. " StopBtn.Enabled=" .. type(items.StopBtn and items.StopBtn.Enabled))

    pcall(function() items.StartBtn.Enabled = true end)
    pcall(function() items.StopBtn.Enabled = false end)
    pcall(function() items.LandBtn.Enabled = false end)
    -- 导出按钮：还没识别出字幕时点了只会报错，先禁用
    pcall(function() items.TxtBtn.Enabled = false end)
    ELog("按钮状态 Start=" .. tostring(items.StartBtn and items.StartBtn.Enabled)
        .. " Stop=" .. tostring(items.StopBtn and items.StopBtn.Enabled))

    -- 事件绑定：注意是 .Clicked（不是 .Click）
    -- 取值方式全部照官方：CurrentIndex / PlainText / Checked
    -- 「关于 / 使用说明」：所有提示文字的归宿
    win.On.AboutBtn.Clicked = function()
        local okA, errA = pcall(function() App:ShowAbout() end)
        if not okA then ELog("关于弹窗异常: " .. tostring(errA)) end
    end

    -- 「浏览…」选模型文件夹
    --   ★ 用 Fusion 自带的 RequestDir：跟导出功能一样，不走 os.execute，
    --     所以不会闪黑窗。选完直接写回输入框，并同步到 uiSnap ——
    --     否则万一 Resolve 的 LineEdit 读不回值，这次选择就白做了。
    win.On.ModelBrowseBtn.Clicked = function()
            local okB, errB = pcall(function()
            local fu = App.resolve and App.resolve:Fusion() or nil
            if not fu then
                App:Log("取不到 Fusion，打不开选择框 —— 请手动粘贴路径。")
                return
            end
            if type(fu.RequestDir) ~= "function" then
                App:Log("当前 Resolve 不支持选择文件夹 —— 请手动粘贴路径。")
                return
            end
            local okD, d = pcall(function()
                return fu:RequestDir(TOOL_ROOT .. "\\models")
            end)
            if not okD then
                App:Log("打开选择框失败：" .. tostring(d))
                return
            end
            -- 不同版本可能返回字符串或 {路径}
            if type(d) == "table" then d = d[1] end
            d = tostring(d or "")
            if d == "" then return end

            ctlSet(items.ModelPathEdit, d)
            App.S.uiSnap = App.S.uiSnap or {}
            App.S.uiSnap.model = d
            App:Log("自定义模型：" .. d)
        end)
        if not okB then ELog("浏览按钮异常: " .. tostring(errB)) end
    end

    win.On.StartBtn.Clicked = function()
      -- ★ 包一层 pcall：事件处理里的错误会被 Resolve 静默吞掉，必须自己抓
      local okClick, clickErr = pcall(function()
        local it = items

        -- 语言（ComboBox → CurrentIndex，0 基）
        local li = tonumber(it.LangCombo and it.LangCombo.CurrentIndex or 0) or 0
        local lang = "Chinese"
        if LANGUAGES[li + 1] then lang = LANGUAGES[li + 1][2] end

        -- 每行最多字数：手动填写，非法则回到 12
        -- ★ 取值优先级【已改为控件优先】（v1.28 热修）：
        --   先直接读输入框里的真实内容，读不到再退回变更事件备份，
        --   最后才是默认 24。
        --   旧写法是"快照优先"，和勾选框踩的是同一个坑：开窗回填时
        --   把快照写成 24，之后只要快照非空就一直压住控件真值 ——
        --   用户在框里改成 8，读到的却仍是 24，"字数限制没生效"。
        --   注：Resolve 21.1 的 LineEdit 读 PlainText 是 nil，
        --   ctlGet 内部已做 Text/PlainText 多路兜底，这里直接用它。
        local snap = App.S.uiSnap or {}
        local mcTxt, mcSrc = ctlGet(it.MaxEdit)
        if not mcTxt or mcTxt == "" then
            mcTxt, mcSrc = snap.max, "uiSnap(max)"
        end
        local mc = tonumber(mcTxt)
        if not mc or mc < 4 then
            mc = tonumber(snap.max) or DEFAULT_MAX_CHARS
        end
        if mc < 4 then mc = DEFAULT_MAX_CHARS end
        if mc > 200 then mc = 200 end
        ELog(("MaxEdit 读取 via=%s raw=%q -> %d"):format(
            tostring(mcSrc), tostring(mcTxt), mc))

        -- 模型：自定义路径优先；否则用下拉里选中的那个
        -- ★★ 取值优先级【已改为控件优先】（v1.28 热修，和短语框同一批）：
        --    旧写法 snap 优先 —— 而 snap.model 在开窗回填时就被写成上次
        --    保存的值（见「已恢复设置」那段），之后只要非空就永远压住控件，
        --    用户改了「自定义模型路径」也不生效，得关掉工具重开才行。
        --    现在：控件读得出来就用控件的（空串 = 用户主动清空 → 走下拉框
        --    分支，语义正确），只有读不出来才退回快照。
        local customTxt, customSrc = ctlGet(it.ModelPathEdit)
        local custom = (customTxt ~= nil) and customTxt or (snap.model or "")
        if type(custom) ~= "string" then custom = "" end
        ELog(("ModelPathEdit 读取 via=%s raw=%q"):format(
            tostring(customSrc), custom))
        custom = custom:gsub("^%s+", ""):gsub("%s+$", "")
        local modelPath = custom
        if modelPath == "" then
            local mi = tonumber(it.ModelCombo and it.ModelCombo.CurrentIndex or 0) or 0
            local models = readModels()
            local m = models[mi + 1] or models[1]
            local name = (m and m.name) or DEFAULT_MODEL
            -- ★ 优先用清单给的完整路径；老格式没有 path 时才退回拼接。
            modelPath = (m and m.path) or (TOOL_ROOT .. "\\models\\" .. name)
        end

        -- 短语提示（热词 / 领域词，见 App:Start 与 asr_engine.transcribe_segment）
        -- ★★ 取值优先级【已改为控件优先】（v1.28 热修）：
        --    旧写法 `(snap.prompt ~= "" and snap.prompt) or ctlGet(...)` 是
        --    快照优先，而 snap.prompt 在开窗回填时就被写成上次保存的值
        --    （见「已恢复设置」那段），之后永远非空 ⇒ 用户在短语框里改了
        --    什么，点「开始」读到的还是旧值 —— 而 CurrentSettings() 保存
        --    时走的却是控件优先，于是表现为「改了不生效，关掉工具重开才生效」。
        --    这就是「短语列表 / 提示 好像没用」的头号原因。
        --    现在：控件读得出来就用控件的（空串 = 用户主动清空，同样要尊重，
        --    否则热词删不掉），只有控件读不出来（unreadable）才退回快照。
        local ptTxt, ptSrc = ctlGet(it.PromptEdit)
        local pt = (ptTxt ~= nil) and ptTxt or (snap.prompt or "")
        if type(pt) ~= "string" then pt = "" end
        ELog(("PromptEdit 读取 via=%s 长度=%d"):format(tostring(ptSrc), #pt))

        -- 勾选框（CheckBox → Checked，兜底 CheckState；再兜底 Toggled 备份）
        -- ★★ 优先级已反转（v1.28 修复）：【控件真值优先，快照只做兜底】。
        --    旧写法是"只要 snap 非 nil 就无条件覆盖控件"，而开窗回填时
        --    又正好写了快照 ⇒ 用户勾了框也读到 false（日志实证 false(Checked)）。
        --    现在语义：只有控件【读不出来】（unreadable）时才退回快照，
        --    这样手动勾选的结果永远不会被陈旧的快照盖掉。
        local ng, ngSrc = ctlChecked(it.NoGap)
        -- ★「句末去标点」勾选项已按需求从界面移除，这里固定为 false。
        --   引擎侧仍保留该参数（no_punct），只是界面不再暴露它。
        local np, npSrc = false, "removed"
        local na, naSrc = ctlChecked(it.AllPunct)
        if ngSrc == "unreadable" and snap.gap ~= nil then
            ng, ngSrc = snap.gap, "snap-gap"
        end
        if naSrc == "unreadable" and snap.punctAll ~= nil then
            na, naSrc = snap.punctAll, "snap-punctAll"
        end
        -- ★ 已删掉这里原有的 `if snap.punct ~= nil then np, npSrc = snap.punct, "snap-punct" end`：
        --   ① 它是死代码 —— uiSnap.punct 在初始化时是 nil，全文件没有任何地方写它，
        --      所以这个条件永远不成立；
        --   ② 而且写法本身是错的：它【不带 unreadable 前置判断】就无条件覆盖 np，
        --      属于"快照优先"那类坑的残留（详见上方勾选框的注释）。
        --      "句末去标点"已从界面移除，np 固定 false，引擎侧的 no_punct 参数保留不动。

        -- ★ "去除标点符号"包含"句末去标点"：两个都勾就按"全部"处理，
        --   在引擎里也是 all 优先（不然会出现"两个开关互相打架"的观感）。
        local pMode = "关"
        if na then
            pMode = "全部"
        elseif np then
            pMode = "句末"
        end
        ELog(("勾选读取 gap=%s(%s) punct=%s(%s) all=%s(%s) -> %s"):format(
            tostring(ng), tostring(ngSrc), tostring(np), tostring(npSrc),
            tostring(na), tostring(naSrc), pMode))

        ELog(("点击开始: lang=%s max=%d gap=%s punct=%s all=%s model=%s")
            :format(lang, mc, tostring(ng), tostring(np), tostring(na),
                    modelPath))

        -- 设置持久化：点「开始」是一次自然提交点（值都是刚读准的）
        self:SaveSettingsNow()

        self:Start(lang, pt, mc, ng, np, modelPath, na)

      end)

      if not okClick then
        ELog("!! 开始按钮异常: " .. tostring(clickErr))
        self:Log("错误：" .. tostring(clickErr))
        self:Status("出错，详见日志")
        pcall(function() items.StartBtn.Enabled = true end)
        pcall(function() items.StopBtn.Enabled = false end)
        App.S.phase = "error"
      end
    end

    win.On.LandBtn.Clicked = function()
        local okClick, clickErr = pcall(function()
            self:DoLand()
        end)
        if not okClick then
            ELog("!! 适配字幕按钮异常: " .. tostring(clickErr))
            self:Log("错误：" .. tostring(clickErr))
            self:Status("适配字幕出错，详见日志")
        end
    end

    win.On.TxtBtn.Clicked = function()
        local okClick, clickErr = pcall(function()
            self:StartExport({ "txt" })
        end)
        if not okClick then
            ELog("!! 导出TXT异常: " .. tostring(clickErr))
            self:Log("错误：" .. tostring(clickErr))
        end
    end

    win.On.StopBtn.Clicked = function()
        self:Cleanup()
        self:Status("已停止")
    end

    -- ── 字幕编辑器事件 ──────────────────────────────────────────
    -- ★★★ 本项目【第二大坑】：事件回调只传【一个 ev 表】，没有额外不定参数。
    --   之前写成 function(_, ...) 靠遍历 select("#", ...) 取行号 ——
    --   实际传进来 0 个额外参数，循环 0 次，行号恒为 nil。
    --   后果：不只是双击没反应，【连单击选中都是坏的】——
    --   表格点不动 → selRow 永远为空 → 下方编辑框拿不到内容，
    --   表现出"那个能打字的框没什么作用"。
    --   正确写法（参考 DaVinci ASR）：在回调里取 tree:CurrentItem()，
    --   再用 item.Text[0] 拿行号（行号就写在第一列）。
    local function rowFromTree()
        local items = App.S.items
        if not items or not items.SubTree then return nil end
        local item = nil
        pcall(function() item = items.SubTree:CurrentItem() end)
        if not item then return nil end
        local idx = nil
        pcall(function() idx = tonumber(tostring(item.Text[0])) end)
        if idx and App.S.subs[idx] then return idx end
        return nil
    end

    -- ★ 全部包 pcall：不同 Resolve 版本的事件签名不完全一致，
    --   绑不上只影响对应功能，不能让整个窗口起不来。
    pcall(function()
        win.On.SubTree.ItemClicked = function(ev)
            local row = rowFromTree()
            if row then
                App.S.selRow = row
                -- 用户手动点了行：把"当前第几处"对齐到这一行。
                -- 不这样做的话，接着点「查找下一处」会从别处继续数，
                -- 状态栏的序号和眼睛看到的位置对不上。
                App.S.curMatch = self:MatchIndexAtRow(row)
                self:SelectRow(row)
                -- ★ 单击 = 选中并展示：内容填进下方只读框 + 全选，
                --   方便直接 Ctrl+C 复制。表格本身在这个 Resolve 版本上
                --   不能就地输入（ItemIsEditable 无效且不报错），
                --   改字走【双击 → 弹出编辑窗】。
                self:FocusSubEdit()
            end
        end
    end)

    -- ★ A 方案：双击一行 = 准备改它 —— 内容填进编辑框、全选、把光标抢过去。
    --   要让它触发，ui:Tree 里必须写 Events = { ItemDoubleClicked = true }。
    pcall(function()
        win.On.SubTree.ItemDoubleClicked = function(ev)
            local row = rowFromTree()
            if row then
                App.S.selRow = row
                self:SelectRow(row)
                self:FocusSubEdit()
            end
        end
    end)


    -- ★ B 方案开关（单元格就地编辑）：在格子里直接打字后触发。
    --   能不能生效取决于 ItemIsEditable 是否被这个 Resolve 版本支持；
    --   不支持也【不会报错】，双击仍走上面那条（跳进编辑框），
    --   两条路互不干扰。
    pcall(function()
        win.On.SubTree.ItemChanged = function(ev)
            if App.S.suppressTreeEdit then return end
            local items = App.S.items
            if not items or not items.SubTree then return end
            local item = nil
            pcall(function()
                item = (ev and ev.item) or items.SubTree:CurrentItem()
            end)
            if not item then return end
            local idx = nil
            pcall(function() idx = tonumber(tostring(item.Text[0])) end)
            if not idx or not App.S.subs[idx] then return end
            local b = App.S.subs[idx]

            -- 第 4 列：字幕文本
            -- ★ 读不到就【直接跳过】—— 绝不能把"读失败"当成"空字符串"，
            --   否则会把这一行字幕文本整个清空（刷新 / 跨进程 IPC 读不出来时）。
            local raw = nil
            pcall(function() raw = item.Text[3] end)
            if raw ~= nil then
                local one = tostring(raw):gsub("\r", " "):gsub("\n", " ")
                if one ~= tostring(b.t or "") then
                    b.t = one
                    App.S.subsDirty = true
                end
            end

            -- 第 2、3 列：允许改时间，但格式不对就【还原】，别把时间码敲坏
            local function fixTime(col, key)
                local raw = nil
                pcall(function() raw = tostring(item.Text[col] or "") end)
                if raw == nil then return end
                local v = parseTimeText(raw)
                if v then
                    if math.abs((tonumber(b[key]) or 0) - v) > 0.0005 then
                        b[key] = v
                        App.S.subsDirty = true
                    end
                end
                -- 无论解析成功与否，都按「当前真值」刷新一次显示：
                --   成功 → 规范化格式；失败 → 还原用户敲坏的内容
                App.S.suppressTreeEdit = true
                pcall(function() item.Text[col] = fmtSec(b[key]) end)
                App.S.suppressTreeEdit = false
            end
            fixTime(1, "s")
            fixTime(2, "e")
        end
    end)
    -- ★ 编辑框实时同步：每敲一个字，表格里那一行立刻跟着变。
    --   有了它，「更新字幕」就只剩下"写进文件"这一件事，语义才清楚。
    pcall(function()
        win.On.SubEdit.TextChanged = function()
            if App.S.suppressEdit then return end
            local i = App.S.selRow
            if not i or not App.S.subs[i] then return end
            local it = App.S.items
            if not it then return end
            local txt = ""
            pcall(function() txt = tostring(it.SubEdit.PlainText or "") end)
            local one = txt:gsub("\r\n", " "):gsub("\r", " "):gsub("\n", " ")
            App.S.subs[i].t = one
            App.S.subsDirty = true
            -- ★ 回写表格单元格时要挡住 ItemChanged —— 否则会被当成
            --   "用户在格子里手改了字"，来回触发（B 方案的就地编辑防递归）。
            App.S.suppressTreeEdit = true
            pcall(function()
                local item = it.SubTree:TopLevelItem(i - 1)
                if item then item.Text[3] = one end
            end)
            App.S.suppressTreeEdit = false
        end
    end)
    -- ★ 查找框一有输入就重建索引并刷新高亮 —— 用户是"边打边看"的，
    --   等他按下「查找下一处」才亮就太晚了。
    pcall(function()
        win.On.FindInput.TextChanged = function()
            self:RebuildMatches()
            self:ApplyFindHighlight()
        end
    end)
    pcall(function()
        win.On.FindNextBtn.Clicked = function() self:FindNext() end
    end)
    pcall(function()
        win.On.ReplaceOneBtn.Clicked = function() self:ReplaceInSubs(false) end
    end)
    pcall(function()
        win.On.ReplaceAllBtn.Clicked = function() self:ReplaceInSubs(true) end
    end)
    pcall(function()
        win.On.UpdateSubsBtn.Clicked = function() self:UpdateSubRow() end
    end)
    pcall(function()
        win.On.LoadPoolBtn.Clicked = function() self:LoadFromMediaPool() end
    end)

    -- 窗口关闭事件：用字面量 ID，不要用 win.ID（可能为 nil，会导致崩溃）
    win.On["QwenASRTool"].Close = function()
        -- 先存设置再收尾：Geometry/各项选择都是这一刻的准值
        self:SaveSettingsNow()
        self:Cleanup()
        pcall(function() ELogFlush() end)   -- 缓冲的日志别丢在内存里
        pcall(function() dispatcher:ExitLoop() end)
    end

    -- ══════════════════════════════════════════════════════════════
    -- ★★★★ 本项目【头号坑】：定时器必须显式创建 + Start()
    --
    --   Fusion 的 UIManager **不会**因为绑定了 dispatcher.On.Timeout
    --   就自动产生超时事件！必须先用 ui:Timer{...} 建一个定时器对象，
    --   再调用它的 :Start()，Timeout 才会按 Interval 周期触发。
    --
    --   我之前只写了 `dispatcher.On.Timeout = function() ... end`，
    --   以为轮询就跑起来了 —— 结果 **Tick 一次都没执行过**，
    --   症状正是用户反复反馈的"界面永远停在识别中/导出中，
    --   其实后台早就跑完了"。这个 bug 骗了我整整 6 轮排查。
    --
    --   官方写法（Steak Underwater 论坛 UITimer 示例）：
    --       timer = ui:Timer{ ID=..., Interval=100, SingleShot=false }
    --       disp.On.Timeout = function(ev) timer_funcs[ev.who]() end
    --       timer:Start()
    --   Interval 单位是【毫秒】。
    -- ══════════════════════════════════════════════════════════════
    local TIMER_ID = "QwenASRPoll"
    local okT, timerObj = pcall(function()
        return ui:Timer({ ID = TIMER_ID, Interval = 500, SingleShot = false })
    end)
    ELog("创建定时器 ok=" .. tostring(okT) .. " timer=" .. tostring(timerObj))
    App.timer = (okT and timerObj) or nil

    dispatcher.On.Timeout = function(ev)
        -- ev.who = 触发事件的定时器 ID（可能同时存在多个定时器）
        if ev and ev.who and ev.who ~= TIMER_ID then return end
        -- ★ 必须 pcall：回调里一旦抛错，定时器会静默失效，
        --   症状和"忘了 Start"一模一样（界面永远不动），几乎无法排查。
        local ok, err = pcall(function() self:Tick() end)
        if not ok then ELog("!! Tick 异常: " .. tostring(err)) end
    end

    ELog("事件已绑定，准备显示窗口")
    self:Log("准备就绪")
    self:Log("引擎目录：" .. TOOL_ROOT)
    ELog("能力探测: io=" .. type(io) .. " loadfile=" .. type(loadfile)
         .. " os.execute=" .. type(os.execute) .. " bmd=" .. type(bmd))

    -- ★ 预热 worker：只拉起、不等待。
    --   这样用户点「开始生成字幕」时它已经就绪，不会因为等它启动而卡一下。
    if not self:WorkerAlive() then
        if PYTHON == "" then
            self:Log("错误：找不到可用的 Python 运行环境")
            self:Log("  · 点左下角「关于 → 更改运行环境」指定一个 python.exe")
            ELog("预热 worker 中止：PYTHON 为空")
        else
            local py = exists(PYTHONW) and PYTHONW or PYTHON
            pcall(function()
                os.execute('start "" /B "' .. py .. '" "' .. WORKER .. '"')
            end)
            ELog("已预热 worker（不等待）: " .. py)
        end
    end

    -- ★★★ 必须显式 Show()，否则窗口不会出现（这就是"点了没反应"的原因）
    local okShow, showErr = pcall(function() win:Show() end)
    ELog("Show() ok=" .. tostring(okShow) .. " err=" .. tostring(showErr))
    if not okShow then
        P("窗口显示失败：" .. tostring(showErr))
    end

    -- ★★ 启动定时器（必须在 RunLoop 之前）
    if App.timer then
        local okS, sErr = pcall(function() App.timer:Start() end)
        ELog("定时器 Start ok=" .. tostring(okS) .. " err=" .. tostring(sErr))
        if not okS then
            self:Log("错误：轮询定时器启动失败，进度不会自动刷新")
        end
    else
        self:Log("错误：无法创建轮询定时器，进度不会自动刷新")
    end

    dispatcher:RunLoop()
    pcall(function() if App.timer then App.timer:Stop() end end)
    ELog("RunLoop 已退出")
end

-- ── 「关于」弹窗 ────────────────────────────────────────────────────
--   把界面上原本那一堆小字说明集中到这里，主界面保持干净。
--   窗口只建一次，之后重复点就是 Show 回来（反复 AddWindow 会攒垃圾）。
-- 最近一次识别的诊断快照（bridge 写的 rt\last_run.lua）。
-- 读不到返回空串 ——「关于」里就不显示这一段，不报错。
function App:LastRunText()
    local t = loadLuaTable(PROBE_WORK .. "\\last_run.lua")
    if type(t) ~= "table" or not t.blocks then return "" end
    local function b(v) return tostring(v) end
    local lines = {
        "",
        "【最近一次识别】",
        string.format("  字幕 %s 条 · 音频 %.1fs · 耗时 %.1fs · RTF %.2f · %s",
            b(t.blocks), tonumber(t.duration) or 0,
            tonumber(t.elapsed) or 0, tonumber(t.rtf) or 0, b(t.device)),
        string.format("  模型 %s · 语言 %s · 每行宽度 %s · 音频缓存 %s",
            b(t.model), b(t.lang), b(t.max_chars),
            (t.cached and "命中" or "未用")),
    }
    return table.concat(lines, "\n")
end

function App:ShowAbout()
    local d = App.S.dispatcher
    local ui = App.S.ui
    if not d or not ui then
        App:Log("取不到 UIManager，打不开说明窗口。")
        return
    end

    if App.S.aboutWin then
        -- 已开过：刷新诊断段再显示（上次识别的数据可能变了）
        pcall(function()
            local it2 = App.S.aboutWin:GetItems()
            if it2 and it2.AboutText then
                pcall(function() it2.AboutText.PlainText =
                    ABOUT_TEXT .. App:LastRunText() end)
                pcall(function() it2.AboutText.Text =
                    ABOUT_TEXT .. App:LastRunText() end)
            end
        end)
        pcall(function() App.S.aboutWin:Show() end)
        return
    end

    local w = d:AddWindow({
        ID = "QwenASRAbout",
        WindowTitle = "关于",
        Geometry = { 300, 120, 720, 660 },
        -- ★ 等宽字体：ABOUT_TEXT 的排版（标题行、缩进、· 引导列）
        --   是按等宽对齐写的，比例字体下会参差不齐。
        StyleSheet = [[
            QWidget { font-size: 13px; }
            QTextEdit#AboutText {
                font-family: "Consolas", "Cascia Mono", monospace;
                font-size: 12px;
            }
        ]],
    }, ui:VGroup{ ID = "AboutRoot", Spacing = 8,
        ui:Label{ ID = "AboutTitle", Text = "关于 Qwen ASR", Weight = 0 },
        ui:HGroup{ ID = "AboutEnvRow", Weight = 0, Spacing = 6,
            ui:Label{ ID = "AboutEnv", Text = "运行环境：检测中…", Weight = 1 },
            ui:Button{ ID = "AboutEnvBtn", Text = "更改…", Weight = 0 },
        },
        ui:TextEdit{ ID = "AboutText", ReadOnly = true, Weight = 1 },
        -- ★ 底部不放「关闭」按钮 —— 和右上角 × 功能重复。
        --   但前提是 × 得真的能用，见下面的 Close 事件绑定。
    })
    if not w then
        App:Log("说明窗口创建失败。")
        return
    end

    local it = w:GetItems()
    if it and it.AboutText then
        -- 官方是给 PlainText 赋值（TextEdit 用这个；LineEdit 才是 Text）
        pcall(function() it.AboutText.PlainText =
            ABOUT_TEXT .. App:LastRunText() end)
        pcall(function() it.AboutText.Text =
            ABOUT_TEXT .. App:LastRunText() end)
    end
    pcall(function()
        if it and it.AboutTitle then
            it.AboutTitle.Text = "关于 Qwen ASR"
        end
    end)

    -- 运行环境：读 rt\env.lua（worker 启动时写的）。
    -- ★ 读不到就明说"未检测"，不要在"关于"里显示一个假的正常状态。
    pcall(function()
        if not it or not it.AboutEnv then return end
        local e = loadLuaTable(PROBE_WORK .. "\\env.lua")
        if e and e.ok then
            it.AboutEnv.Text = string.format(
                "运行环境：%s（torch %s / transformers %s）",
                tostring(e.python or "?"), tostring(e.torch or "?"),
                tostring(e.transformers or "?"))
        elseif e then
            it.AboutEnv.Text = "运行环境不完整：" .. tostring(e.python or "?")
                .. "（缺 torch / transformers）"
        else
            it.AboutEnv.Text = "运行环境：未检测（后台执行器还没起来）"
        end
    end)

    -- 「更改…」：指定一个 python.exe，写进 rt\settings.lua 永久记住。
    -- ★★ 这是插件独立性的关键一步：别的插件被卸载/更新之后，
    --    在这里指一个新环境就能继续用，不用改代码、不用重装。
    pcall(function()
        w.On.AboutEnvBtn.Clicked = function()
            local okB, errB = pcall(function()
                local fu = App.resolve and App.resolve:Fusion() or nil
                if not fu or type(fu.RequestDir) ~= "function" then
                    App:Log("当前 Resolve 不支持选择目录，请手动编辑："
                            .. SETTINGS_FILE)
                    return
                end
                -- 用 RequestDir（模型浏览已经在用，确定可用）而不是
                -- RequestFile（是否存在没验证过）。选完自己找 python.exe。
                local okD, d = pcall(function()
                    return fu:RequestDir("C:\\")
                end)
                if not okD then return end
                if type(d) == "table" then d = d[1] end
                d = tostring(d or "")
                if d == "" then return end
                local py = d .. "\\python.exe"
                if not exists(py) then py = d .. "\\Scripts\\python.exe" end
                if not exists(py) then
                    App:Log("错误：这个目录里没有 python.exe")
                    App:Log("  · venv 请选到 .venv 根目录；系统 Python 请选到 Python3xx")
                    return
                end
                -- ★ 合并写，不要整个文件重写 —— 否则会把用户存好的
                --   语言/模型/宽度/窗口位置一并抹掉。
                local cur = readSettings()
                cur.python = py
                if not writeSettings(cur) then
                    App:Log("错误：写不进设置文件 " .. SETTINGS_FILE)
                    return
                end
                App:Log("已记住运行环境：" .. py)
                App:Log("  · 重启本插件后生效")
                if it and it.AboutEnv then
                    it.AboutEnv.Text = "运行环境：" .. py .. "（重启后生效）"
                end
            end)
            if not okB then ELog("更改运行环境异常: " .. tostring(errB)) end
        end
    end)

    -- ★★ 右上角 × 走的是【窗口的 Close 事件】，不是按钮事件。
    --    主窗口绑了 win.On["QwenASRTool"].Close，而这个弹窗以前
    --    只绑了一个「关闭」按钮 —— 所以点 × 毫无反应，弹窗关不掉。
    --    现在用 Hide 而不是真正的销毁：下次点「关于」还能直接复现。
    w.On["QwenASRAbout"].Close = function() w:Hide() end
    App.S.aboutWin = w
    w:Show()
    ELog("关于窗口已打开")
end

-- ── 日志 ──────────────────────────────────────────────────────────
-- 日志最多保留这么多行。每次 Log 都要 table.concat 全文再赋给 PlainText，
-- 行多了以后一次刷新就要拼几十 KB 字符串，界面会越来越涩。
-- ★ 日志是【倒序】存的：logLines[1] 永远是最新一条，最新一行显示在最上面，
--   用户不用再去拖滚动条看新消息（本 Resolve 版本没法命令 TextEdit 滚到底）。
local LOG_MAX_LINES = 400
-- 界面日志区实际显示多少行（倒序，最新的在最上面，更早的没人翻）
local LOG_SHOW_LINES = 120
-- 字幕表格每批填充多少行（长音频时分批，避免一次性卡死界面）
local TREE_BATCH = 150

function App:Log(text)
    P(text)
    ELog("  [log] " .. tostring(text))
    -- 倒序：新消息插到最前面（第 1 行），最旧的从尾部丢掉
    table.insert(App.S.logLines, 1, tostring(text))
    -- 倒序存储：最旧的在最后，直接从尾部丢，不用重建整张表
    while #App.S.logLines > LOG_MAX_LINES do
        table.remove(App.S.logLines)
    end
    -- ★ 节流：同一秒内的多条日志只拼一次字符串。
    --   识别过程中每秒能刷出十几条，每次都 concat 全文（400 行、几十 KB）
    --   会让界面明显变涩；合并后界面成本从"N 次拼接"降到"1 秒 1 次"。
    local now = os.time()
    if now ~= App.S.logFlushedAt then
        self:FlushLog()
    else
        App.S.logDirty = true
    end
end

-- 把日志真正刷进界面（FlushLog 单独拆出来，Tick 也要调它补刷）
function App:FlushLog()
    local it = App.S.items
    if not it or not it.LogEdit then return end
    App.S.logDirty = false
    App.S.logFlushedAt = os.time()
    -- 只拼最新那截：显示区就 120 行，拼 400 行纯属浪费
    local show = {}
    for i = 1, math.min(#App.S.logLines, LOG_SHOW_LINES) do
        show[i] = App.S.logLines[i]
    end
    pcall(function()
        -- 官方用 PlainText 属性赋值，不是 :SetText()
        it.LogEdit.PlainText = table.concat(show, "\n")
    end)
end

function App:Status(text)
    -- ★ 状态每 0.5 秒刷新一次，但内容经常和上次一字不差
    --   （比如"识别中... 37%"卡在那儿）。重复赋值会让 Qt 反复重排，
    --   白烧 CPU。这里先比一次。
    if App.S.lastStatus == text then return end
    App.S.lastStatus = text
    local it = App.S.items
    if it and it.Status then
        pcall(function() it.Status.Text = text end)
    end
end

-- ★ 时间码单独一块（只读、可复制）：只显示 HH:MM:SS:FF。
--   传空串表示清空（比如开始新一轮识别时，旧时间码不该留在那儿）。
function App:StatusTimecode(tc)
    tc = tostring(tc or "")
    if App.S.lastTC == tc then return end
    App.S.lastTC = tc
    local it = App.S.items
    if not it or not it.StatusTC then return end
    pcall(function() it.StatusTC.Text = tc end)
    -- 只读控件在个别 Resolve 版本上赋值会失败，补一次兜底
    pcall(function()
        if it.StatusTC.Text ~= tc then it.StatusTC.PlainText = tc end
    end)
end

-- 让字幕文件名跟着【源素材】走（123.mp4 → 123.srt）。
-- 好处：媒体池里的字幕项、素材旁的副本、字幕输出里的文件三者同名，最好找；
--       也避免 SRT 叫 "Timeline 1" 和工程里的时间线重名造成混淆。
function App:SetSrtName(src)
    local fname = tostring(src or ""):match("[^\\/]+$") or ""
    local base = fname:gsub("%.[%a%d]+$", "")
    base = base:gsub('[\\/:*?"<>|]', "_")
    if base == "" then return end
    App.S.srt = TOOL_ROOT .. "\\字幕输出\\" .. base .. ".srt"
    App.S.txt = TOOL_ROOT .. "\\字幕输出\\" .. base .. ".txt"
    App.S.srtBase = base
    ELog("字幕输出 = " .. App.S.srt .. "  文稿 = " .. App.S.txt)
end

-- ── 启动流程 ──────────────────────────────────────────────────────
function App:Start(lang, prompt, maxChars, noGap, noPunct, modelPath, allPunct)
    if App.S.phase ~= "idle" and App.S.phase ~= "done" and App.S.phase ~= "error" then
        self:Status("已有任务进行中")
        return
    end

    -- 新一轮识别开始：清掉上一轮查找留下的时间码，别让它挂在状态栏上
    self:StatusTimecode("")

    App.S.langCode = lang
    App.S.prompt = prompt
    App.S.maxChars = maxChars
    App.S.noGap = noGap
    App.S.noPunct = noPunct
    App.S.allPunct = allPunct and true or false
    App.S.modelPath = modelPath or ""
    App.S.logLines = {}

    -- 输出到好找的位置，文件名带时间线名（原来藏在 resolve_temp 里，用户根本找不到）
    local safeName = tostring(App.tlName or "字幕"):gsub('[\\/:*?"<>|]', "_")
    App.S.srt = TOOL_ROOT .. "\\字幕输出\\" .. safeName .. ".srt"
    App.S.txt = TOOL_ROOT .. "\\字幕输出\\" .. safeName .. ".txt"

    pcall(function() os.remove(App.S.srt) end)
    pcall(function() os.remove(App.S.txt) end)
    pcall(function() os.remove(App.S.importFile) end)
    pcall(function() os.remove(App.S.exportFile) end)
    pcall(function() os.remove(App.S.statusFile) end)
    pcall(function() os.remove(App.S.logFile) end)
    -- 进度/心跳的 Lua chunk 也要清掉，否则会读到上次运行的结果
    pcall(function() os.remove(PROBE_WORK .. "\\status.lua") end)
    pcall(function() os.remove(PROBE_WORK .. "\\hb.lua") end)
    -- 落轨结果同理（不清的话会立刻误判成"已完成"）
    pcall(function() os.remove(App.S.landFile) end)
    pcall(function() os.remove(App.S.landCfg) end)
    App.S.landStartedAt = nil

    -- ★ 这两个时间戳不清零的话，下一轮 Tick 一进来就算出"已经超时"，
    --   自动入库 / 导出会被瞬间判死（跑了 0 秒就报超时）。
    App.S.importStartedAt = nil
    App.S.exportStartedAt = nil
    App.S.probeStartedAt = nil
    App.S.syncStartedAt = nil
    -- 「更新字幕」留下的待办同步标记也要清（属于上一轮的字幕）
    App.S.pendingSync = nil
    -- ★ worker 上一次不可用不代表这次也不可用（可能只是当时还没起来）。
    --   每轮重新探测，否则一旦失败就永久退化成"闪黑窗"的老路径。
    App.S.workerOk = nil
    App.S.lastStatus = nil

    -- 重置轮询状态
    App.S.pyStartedAt = nil
    App.S.count = 0
    App.S.realModel = ""        -- 引擎实际用的模型（回退时会和填的不一样）
    App.S.lastPct = 0
    App.S.lastSize = 0
    App.S.sameCount = 0
    App.S.restartTried = false
    App.S.renderStartedAt = os.time()
    -- 删掉上次导出的音频，避免"按文件判定"时把旧文件当成新产出
    -- （用 listFiles 而不是 io.popen：后者会闪黑窗）
    pcall(function()
        for _, nm in ipairs(listFiles(WORK_DIR, "qwen3_audio", ".wav")) do
            os.remove(WORK_DIR .. "\\" .. nm)
        end
    end)
    pcall(function() App.S.items.StartBtn.Enabled = false end)
    pcall(function() App.S.items.StopBtn.Enabled = true end)
    pcall(function() App.S.items.LandBtn.Enabled = false end)
    pcall(function() App.S.items.TxtBtn.Enabled = false end)
    pcall(function() App.S.items.StartBtn.Text = "开始生成字幕" end)

    -- 步骤 1：优先直接读时间线上的源文件（快），不行才走渲染
    --   ★ 这一步是【异步】的：只负责把探测脚本发出去，
    --     结果由 Tick 的 probing 分支收（见 App:StartProbe 的说明）。
    self:StartProbe()
end


-- ══════════════════════════════════════════════════════════════
-- 快速路径：读时间线上的源文件直接识别，跳过渲染。
--
-- ★ 为什么用外部 Python 脚本而不是在 Lua 里做：
--   1. Lua 侧 TimelineItem 方法名各版本不一致（21.1 是 GetStart()/GetSpeed()，
--      不是 GetStartFrame()），取不到值时返回 nil 而不报错，很难发现。
--   2. Lua 里异常被 Resolve 静默吞掉，只能看到"没反应"。
--      Python 侧能 try/except 并把结果和错误写进 JSON。
--
--   前置条件：首选项 → 系统 → 常规 → 外部脚本使用 = 本地 / 网络
-- ══════════════════════════════════════════════════════════════
-- ★★ 只【发出】探测命令，立刻返回。结果在 Tick 的 probing 分支里收。
--
--   原来这里是同步忙等：最多 150 次 × 0.1 秒 = 15 秒，
--   期间 RunLoop 根本转不起来 —— 窗口不能重绘、点不动、看着像"点了没反应"。
--   加上 EnsureWorker / RunTask 各自的等待，最坏能卡 27 秒。
--   现在整条链上最长的单次阻塞是 RunTask 等 worker 回执（2.5 秒上限）。
function App:StartProbe()
    local jsonPath = PROBE_WORK .. "\\src.json"
    local txtPath  = PROBE_WORK .. "\\src_path.txt"
    local luaPath  = PROBE_WORK .. "\\src.lua"
    App.S.srcLua   = luaPath
    App.S.srcTxt   = txtPath
    App.S.srcJson  = jsonPath
    pcall(function() os.remove(jsonPath) end)
    pcall(function() os.remove(txtPath) end)
    pcall(function() os.remove(luaPath) end)

    -- ★★ 交给常驻 worker 启动（os.execute 会闪黑窗，worker 不会）。
    --    路径全 ASCII；中文值走文件，不进命令行。
    if not self:RunTask(PROBE_SCRIPT, { jsonPath, txtPath, luaPath }) then
        -- 探测脚本没起来：别在 probing 里空等 20 秒，直接走渲染
        self:Log("读取时间线失败，改用渲染导出")
        self:StartRender()
        return
    end

    App.S.phase = "probing"
    App.S.probeStartedAt = os.time()
    self:Status("正在读取时间线素材…")
    ELog("探测已下发（异步）")
end

-- 探测有结果了：要么直接用源文件识别，要么退回渲染导出
function App:OnProbe(t)
    ELog("src.lua 加载成功")
    local errMsg = tostring(t.error or "")
    local hint   = tostring(t.hint or "")
    local src    = tostring(t.path or "")
    local any    = tostring(t.any or "")
    local name   = tostring(t.name or "")
    local nItems = tonumber(t.items) or 0
    -- 帧率 / 时间线起始帧：播放头联动跳转的时间码换算要用
    App.S.fps     = tonumber(t.fps) or 0
    App.S.tlStart = tonumber(t.tl_start) or 0

    -- ★ 走渲染兜底时也要记住素材路径（哪怕它"不能直接识别"），
    --   否则落轨那一步的"在源素材旁边放一份 srt"会被静默跳过。
    if any ~= "" then App.S.audioPath = any end

    if errMsg ~= "" then self:Log("读取时间线失败：" .. errMsg) end
    if hint ~= "" and errMsg == "" then self:Log(hint) end

    -- ★★ 快速路径只认【单片段且未裁剪】。
    --   以前只要"第一个片段恰好没被裁剪"就直接拿它的源文件识别 ——
    --   多片段时间线里第 2 段之后的音频被无声丢掉，字幕却按整条
    --   时间线排，观众看到的就是"后半段没字幕"。必须走渲染。
    if src ~= "" and nItems ~= 1 then
        self:Log(string.format(
            "时间线上有 %d 个音频片段，为保证声画同步，走渲染导出", nItems))
        src = ""
    end

    if src == "" then
        if errMsg == "" and hint == "" then
            self:Log("时间线上没有可直接使用的素材，走渲染导出")
        end
        return self:StartRender()
    end

    -- ★★ 不要在这里用 exists() 判断素材存在性！
    --   Windows Lua 的 io.open 走 ANSI API，**打不开中文路径**，
    --   会把明明存在的文件判成"不存在"（实测踩过）。
    --   存在性已由 Python 用 os.path.exists 校验过。
    self:Log("快速路径：直接使用源文件，跳过渲染")
    if name ~= "" then self:Log("  " .. name) end
    self:Log("  " .. src)
    App.S.audioPath = src
    self:SetSrtName(src)

    return self:StartPython(src)
end

-- ══════════════════════════════════════════════════════════════
-- 渲染导出 WAV（兜底路径：快速路径用不了时才走这里）
--
-- ★★ 两段式：StartRender 只负责【切页 + 快照】，格式配置放进 Tick 的
--   render_cfg 相位、等交付页就绪后再做。
--   原因（实测踩坑）：OpenPage("deliver") 是异步的，切完立刻调
--   SetCurrentRenderFormatAndCodec / SetRenderSettings 会静默失败，
--   格式停在 "unknown"，渲染作业"成功"结束但一个文件都不产出，
--   最后报"未生成音频文件"—— 和真因（格式没设上）八竿子打不着。
--
-- ★ 大量细节来自 AutoSubs（github.com/tmoroney/auto-subs）Resolve-Integration
--   的实测结论，他们踩过的坑和我一模一样：
--   1. 必须先 OpenPage("deliver")，否则 AddRenderJob/StartRendering 会静默失败
--   2. StartRendering 偶尔返回 false（交付页还在切），等 0.5 秒重试一次即可
--   3. 导出前要快照用户的渲染设置，跑完恢复 —— 否则把用户交付页改得乱七八糟
--   4. JobStatus 是本地化字符串（中文/葡语/俄语…），绝对不能拿它和
--      "Complete" 比 —— 见 App:Tick 里的判定
--   5. 'Audio Only' 内置预设在非英文 Resolve 上名字被本地化，加载必失败
--      → 改用官方 DaVinci ASR 同款做法：ImportRenderPreset 导入自带的
--        render_to_wav.xml（格式写死在 XML 里，不依赖任何本地化名字），
--        导入后再读回校验，不是 WAV 就明确报错，绝不静默产出空文件
-- ══════════════════════════════════════════════════════════════
function App:StartRender()
    local proj = App.project

    -- ① 切到交付页（不切的话渲染根本起不来）。
    --    这里只切页 + 记相位；格式配置等页面就绪，见 App:ConfigRender。
    App.S.prevPage = App.resolve:GetCurrentPage()
    pcall(function() App.resolve:OpenPage("deliver") end)

    self:Status("正在配置音频导出...")
    self:Log("导出时间线音轨（WAV）")
    self:Log("（导出期间请勿关闭本窗口）")

    -- ② 清掉我们自己的旧作业（不动用户自己的渲染任务）
    --    卡在 'Ready' 的僵尸作业会让 IsRenderingInProgress() 永远为 true，
    --    导致之后每次导出都被阻塞 —— 必须清。
    self:RemoveStaleJobs()

    -- ③ ★ 快照用户当前的交付页设置，跑完要还原
    App.S.renderSnap = nil
    pcall(function()
        local name = "QwenASRBackup-" .. os.date("!%Y%m%d-%H%M%S")
            .. "-" .. tostring(math.random(1000, 9999))
        if proj:SaveAsNewRenderPreset(name) then
            App.S.renderSnap = { presetName = name }
        end
    end)
    if not App.S.renderSnap then
        -- SaveAsNewRenderPreset 失败时的退路：至少记住格式和渲染模式
        local snap = {}
        pcall(function() snap.formatCodec = proj:GetCurrentRenderFormatAndCodec() end)
        pcall(function() snap.renderMode = proj:GetCurrentRenderMode() end)
        App.S.renderSnap = snap
    end

    -- ④ 等交付页就绪后再配置格式（Tick 的 render_cfg 相位驱动）
    App.S.renderCfgAt = os.time()
    App.S.phase = "render_cfg"
    ELog("已切到交付页，等页面就绪后配置导出格式")
end

-- 读回当前渲染格式，返回 "格式 / 编解码器" 文本（读不到返回 ""）
local function curFormatText(proj)
    local txt = ""
    pcall(function()
        local d = proj:GetCurrentRenderFormatAndCodec()
        if type(d) == "table" then
            local f = d.format or d.Format or d["Render Format"] or d.renderFormat
            local c = d.codec or d.Codec or d["Render Codec"] or d.renderCodec
            txt = tostring(f or "") .. " / " .. tostring(c or "")
        else
            txt = tostring(d or "")
        end
    end)
    return txt
end

-- 交付页就绪后：配置 WAV 导出格式 + 建作业 + 启动渲染。
-- 失败时自己收尾（CleanupRender + Fail），返回 false。
function App:ConfigRender()
    local proj = App.project

    -- ① 先把交付页切成"只导音频"视图（官方 DaVinci ASR 的第一步）。
    --   不做这一步，后面的格式/预设 API 在部分版本上不生效。
    pcall(function()
        proj:SetRenderSettings({ ExportVideo = false, ExportAudio = true })
    end)

    -- ② 导入自带的 WAV 预设（格式写死在 XML 里，不依赖本地化预设名）
    if RENDER_PRESET_XML and exists(RENDER_PRESET_XML) then
        pcall(function() proj:DeleteRenderPreset("render_to_wav") end)
        local okImp, imp = pcall(function()
            return App.resolve:ImportRenderPreset(RENDER_PRESET_XML)
        end)
        ELog("ImportRenderPreset ok=" .. tostring(okImp)
             .. " 返回=" .. tostring(imp))
        if okImp and imp ~= true then
            self:Log("注意：WAV 预设导入返回 " .. tostring(imp)
                     .. "，继续用格式探测")
        end
    else
        ELog("找不到 render_to_wav.xml（" .. tostring(RENDER_PRESET_XML)
             .. "），用格式探测")
    end

    -- ③ 校验格式确实是 WAV；不是就按 API 探测设一次，再不行就明确报错
    --    （以前不校验：格式停在 unknown 也照样建作业，渲染"成功"但零产出，
    --    最后只看到一句"未生成音频文件"，根本想不到是格式没设上）
    local fmtText = curFormatText(proj)
    self:Log("渲染格式：" .. (fmtText ~= "" and fmtText or "未知"))
    local low = fmtText:lower()
    if low:find("wav") == nil and low:find("wave") == nil then
        local fmtName, fmtExt, codec = "wav", "wav", "lpcm"
        pcall(function()
            local fmts = proj:GetAudioRenderFormats() or {}
            for name, ext in pairs(fmts) do
                if tostring(ext):lower() == "wav" then
                    fmtName, fmtExt = tostring(name), tostring(ext)
                end
            end
        end)
        pcall(function()
            local cs = proj:GetAudioRenderCodecs(fmtExt) or {}
            for desc, key in pairs(cs) do
                local d = tostring(desc):lower()
                local k = tostring(key):lower()
                if k:find("pcm") or d:find("pcm") or d:find("linear") then
                    codec = tostring(key)
                    break
                end
            end
        end)
        pcall(function()
            proj:SetCurrentRenderFormatAndCodec(fmtName, codec)
        end)
        fmtText = curFormatText(proj)
        self:Log("格式探测后：" .. (fmtText ~= "" and fmtText or "未知"))
        low = fmtText:lower()
        if low:find("wav") == nil and low:find("wave") == nil then
            self:CleanupRender()
            self:Fail("无法设置音频导出格式（当前：" ..
                      (fmtText ~= "" and fmtText or "未知") ..
                      "）。请在交付页手动选一次 WAV 格式后重试")
            return false
        end
    end

    -- ④ 设置导出参数
    --    ★ 两种 key 拼写都给：老版本文档是 ExportVideo/ExportAudio，
    --      某些版本只认 IsExportVideo/IsExportAudio；未知 key 会被忽略，
    --      所以两个都写最稳（AutoSubs 的做法）。
    App.S.audioPrefix = "qwen3_audio_" .. os.date("!%Y%m%d-%H%M%S")
    local ok, err = pcall(function()
        return proj:SetRenderSettings({
            SelectAllFrames  = true,
            ExportVideo      = false,
            ExportAudio      = true,
            IsExportVideo    = false,
            IsExportAudio    = true,
            AudioFormat      = "wav",
            AudioCodec       = "lpcm",
            AudioBitDepth    = 16,
            AudioSampleRate  = 48000,
            TargetDir        = osPath(WORK_DIR),
            CustomName       = App.S.audioPrefix,
        })
    end)
    ELog("SetRenderSettings ok=" .. tostring(ok) .. " 返回=" .. tostring(err))

    if not ok or err ~= true then
        self:CleanupRender()
        self:Fail("无法设置渲染参数（返回 " .. tostring(err) .. "）")
        return false
    end

    -- ⑤ 建作业 + 启动（全部包 pcall：裸调用抛错会被静默吞掉 → 界面永久卡住）
    local okJob, jobId = pcall(function() return proj:AddRenderJob() end)
    ELog("AddRenderJob ok=" .. tostring(okJob) .. " 返回=" .. tostring(jobId))
    if not okJob or not jobId or jobId == "" then
        self:CleanupRender()
        self:Fail("无法创建渲染任务（AddRenderJob 返回 " .. tostring(jobId) .. "）")
        return false
    end

    -- ★ AutoSubs 实测：交付页刚切过来时 StartRendering 偶尔返回 false，
    --   等半秒重试一次就能起来。这里照做。
    local started = false
    pcall(function() started = proj:StartRendering({ jobId }, false) end)
    if started ~= true then
        ELog("StartRendering 首次返回 " .. tostring(started) .. "，重试")
        waitSec(0.5)
        pcall(function() started = proj:StartRendering({ jobId }, false) end)
    end
    ELog("StartRendering = " .. tostring(started))

    if started ~= true then
        pcall(function() proj:DeleteRenderJob(jobId) end)
        self:CleanupRender()
        self:Fail("无法启动渲染任务（StartRendering 返回 " .. tostring(started) .. "）")
        return false
    end

    App.S.jobId = jobId
    App.S.phase = "rendering"
    App.S.renderStartedAt = os.time()
    App.S.restartTried = false
    App.S.lastSize = -1
    App.S.sameCount = 0
    ELog("渲染已启动 jobId=" .. tostring(jobId))
    self:Status("导出音频中...")
    return true
end
-- 只删我们自己留下的作业（按文件名前缀识别），绝不碰用户的渲染任务
function App:RemoveStaleJobs()
    pcall(function()
        local jobs = App.project:GetRenderJobList() or {}
        for _, j in ipairs(jobs) do
            local nm = tostring(j.OutputFilename or "") .. tostring(j.CustomName or "")
            local id = j.JobId or j.Id
            if id and id ~= App.S.jobId and nm:find("qwen3_audio") then
                pcall(function() App.project:DeleteRenderJob(id) end)
            end
        end
    end)
end

-- 渲染结束（成功/失败/取消都要调）：删掉我们的作业 + 还原用户交付页设置
function App:CleanupRender()
    if App.S.jobId then
        pcall(function() App.project:DeleteRenderJob(App.S.jobId) end)
        App.S.jobId = nil
    end
    -- 收掉我们导入的 WAV 预设，别在用户的交付页预设列表里留垃圾
    pcall(function() App.project:DeleteRenderPreset("render_to_wav") end)
    local snap = App.S.renderSnap
    App.S.renderSnap = nil
    if type(snap) ~= "table" then return end
    if snap.presetName then
        pcall(function() App.project:LoadRenderPreset(snap.presetName) end)
        pcall(function() App.project:DeleteRenderPreset(snap.presetName) end)
    else
        if type(snap.formatCodec) == "table" then
            local f = snap.formatCodec.format or snap.formatCodec["format"]
            local c = snap.formatCodec.codec or snap.formatCodec["codec"]
            if f and c then
                pcall(function() App.project:SetCurrentRenderFormatAndCodec(f, c) end)
            end
        end
        if snap.renderMode ~= nil then
            pcall(function() App.project:SetCurrentRenderMode(snap.renderMode) end)
        end
        -- 拿不到预设快照时，只能把导出开关恢复到常规默认，
        -- 总比把用户留在"仅音频"上强
        pcall(function()
            App.project:SetRenderSettings({
                ExportVideo = true, ExportAudio = true,
                IsExportVideo = true, IsExportAudio = true,
                SelectAllFrames = true,
            })
        end)
    end
end

function App:ReturnToPrevPage()
    -- 回到原页面（用 pcall 防止页面名不被支持时崩溃）
    if App.S.prevPage then
        pcall(function() App.resolve:OpenPage(App.S.prevPage) end)
    end
end

-- ── 主循环 ────────────────────────────────────────────────────────
-- 取一个日志文件的最后一条非空行（字节级 seek，不是逐行读全文）
local function lastLogLine(path)
    if not path or path == "" then return "" end
    local d = tail(path, 1500)
    if d == "" then return "" end
    local best = ""
    for line in (d .. "\n"):gmatch("(.-)\n") do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s ~= "" then best = s end
    end
    return best
end

function App:Tick()
    local ph = App.S.phase

    -- 日志节流补刷：同一秒里攒下的日志在这里一次性刷进界面
    if App.S.logDirty then self:FlushLog() end

    -- ── 子进程退出码：worker 写回 rc_<sess>_<id>.lua ──────────
    --   ★ 以前只能轮询输出文件。进程如果在写出任何东西之前就崩了，
    --     Lua 要干等满超时（保存分支 20 秒）才报错，而且报的是
    --     "读取字幕超时"这种和真因无关的话。现在失败当时就能报，
    --     还能把日志最后一行直接贴出来。
    --   ★ 这里只做"报错 + 清场"，不动状态机 —— 渲染中的任务万一
    --     被 Fail 打断，渲染作业没人收。原有的超时逻辑照旧兜底。
    if App.S.curTask and not App.S.ignoreRc then
        local rc = loadLuaTable(App.S.curTask.rcFile)
        if rc and tonumber(rc.id) == App.S.curTask.id then
            local task = App.S.curTask
            App.S.curTask = nil
            pcall(function() os.remove(task.rcFile) end)
            local code = tonumber(rc.rc) or 0
            if code ~= 0 then
                local why = lastLogLine(task.log or "")
                self:Log("错误：" .. tostring(task.script or "任务")
                         .. " 异常退出（退出码 " .. tostring(code) .. "）")
                if why ~= "" then self:Log("  · " .. why) end
                if task.log and task.log ~= "" then
                    self:Log("  · 完整日志：" .. task.log)
                end
                self:Status("任务失败，详见日志")
            end
        elseif os.time() - (App.S.curTask.startedAt or os.time()) > 900 then
            -- 挂了 15 分钟以上的命令别再跟了（worker 可能被重启过）
            App.S.curTask = nil
        end
    end

    -- 字幕表格分批续填：一批 150 行，剩下的下一拍继续，界面不会卡死
    if App.S.treeQueue then
        local i = App.S.treeQueue
        if i > #App.S.subs then
            App.S.treeQueue = nil
        else
            self:FillSubTreeBatch(i, i + TREE_BATCH - 1)
            App.S.treeQueue = i + TREE_BATCH
        end
    end

    -- ── 待办：把刚保存的字幕同步进媒体池（「更新字幕」的第二步）──────
    --   ★ 不能点完按钮就立刻启动同步：写 SRT 和读 SRT 是两个独立 python
    --     进程（worker 用 Popen 拉起，彼此不等待），同时跑会读到半截文件。
    --     这里等 1 秒（约两拍定时器）再动手。
    if App.S.pendingSync and os.time() >= App.S.pendingSync then
        App.S.pendingSync = nil
        if BUSY_PHASES[App.S.phase] then
            self:Log("  · 当前任务还没结束，这次没同步媒体池（字幕文件已是最新）")
        elseif App.S.srt and App.S.srt ~= "" then
            self:StartLand("media", "sync")
        end
    end

    -- ── 字幕编辑器：等 subs_io.py 写出 subs.lua（独立于主状态机）──
    if App.S.subsPending then
        local t = loadLuaTable(App.S.subsLua)
        if t then
            App.S.subsPending = false
            pcall(function() os.remove(App.S.subsLua) end)
            self:FillSubTree(t)
            if #App.S.subs > 0 then
                self:Status(string.format("字幕编辑器已载入 %d 条", #App.S.subs))
            end
        elseif os.time() - (App.S.subsStartedAt or os.time()) > 20 then
            App.S.subsPending = false
            self:Log("错误：读取字幕超时（字幕文件仍在：" .. tostring(App.S.srt) .. "）")
        end
    end

    -- ── 交付页就绪等待 + 格式配置（渲染前的准备相位）────────────
    --   OpenPage("deliver") 是异步的：页面没切完就调格式 API 会静默
    --   失败（格式停在 unknown → 渲染零产出）。这里等页面真就绪了
    --   再配置，最多等 3 秒。
    if ph == "render_cfg" then
        local page = ""
        pcall(function() page = tostring(App.resolve:GetCurrentPage() or "") end)
        local waited = os.time() - (App.S.renderCfgAt or os.time())
        if page ~= "deliver" and waited < 3 then
            return                        -- 下一拍再问
        end
        if page ~= "deliver" then
            self:CleanupRender()
            self:Fail("无法切换到交付页（用于导出音频），请重试")
            return
        end
        self:ConfigRender()
        return
    end

    if ph == "rendering" then
        -- ★★ 参考 AutoSubs 实测的两条铁律：
        --  (1) GetRenderJobStatus 返回的是【表】，不是两个返回值
        --      { JobStatus = ..., CompletionPercentage = 0-100, Error = ... }
        --  (2) JobStatus 是【本地化字符串】！中文 Resolve 上不是 "Complete"，
        --      葡语是 "Finalizado"/"Concluído"，俄语是 "Завершено"。
        --      → 绝对不能拿它和英文比。真正的完成判据只有两个：
        --          Error 为空  且  CompletionPercentage >= 100
        local rendering = false
        pcall(function() rendering = App.project:IsRenderingInProgress() end)

        local st = nil
        local okQ, res = pcall(function()
            return App.project:GetRenderJobStatus(App.S.jobId)
        end)
        if okQ then st = res else ELog("GetRenderJobStatus 异常: " .. tostring(res)) end

        local jobStatus, pct, jobError = "", 0, nil
        if type(st) == "table" then
            jobStatus = tostring(st.JobStatus or "")
            pct = tonumber(st.CompletionPercentage) or 0
            if st.Error ~= nil and tostring(st.Error) ~= "" then
                jobError = tostring(st.Error)
            end
        elseif type(st) == "string" then
            jobStatus = st
        end
        App.S.lastPct = pct

        local elapsed = os.time() - App.S.renderStartedAt

        -- 进度显示：优先用百分比，拿不到就看已导出的文件大小
        local audioNow, sizeNow = self:FindAudio()
        if pct > 0 then
            pcall(function() App.S.items.StartBtn.Text = string.format("导出中 %d%%", pct) end)
            self:Status(string.format("导出音轨... %d%%", pct))
        elseif sizeNow > 0 then
            pcall(function()
                App.S.items.StartBtn.Text = string.format("导出中 %.0f MB", sizeNow / 1048576)
            end)
            self:Status(string.format("导出音轨... %.0f MB", sizeNow / 1048576))
        end

        -- ── ① 真正出错：Error 非空
        if jobError then
            self:ReturnToPrevPage()
            self:CleanupRender()
            self:Fail("导出失败：" .. jobError)
            return
        end

        -- ── ② 完成：不再渲染 + 百分比到 100（不看 JobStatus 的文字）
        if not rendering and pct >= 100 then
            self:Log("音频导出完成")
            self:ReturnToPrevPage()
            self:CleanupRender()
            local audio = self:FindAudio()
            if audio then
                self:StartPython(audio)
            else
                self:Fail("未生成音频文件（时间线可能没有音频轨）")
            end
            return
        end

        -- ── ③ 卡住：没在渲染、也没到 100%、启动已超过宽限期
        --      AutoSubs 实测：作业被排队却从没真正启动（停在 0% 无错误），
        --      重启一次就能起来。真错误的不重启（上面已处理）。
        local GRACE = 10
        if (not rendering) and pct < 100 and elapsed > GRACE then
            if not App.S.restartTried and pct == 0 then
                App.S.restartTried = true
                self:Log("渲染任务未启动，重启一次…")
                local restarted = false
                pcall(function()
                    restarted = App.project:StartRendering({ App.S.jobId }, false)
                end)
                if restarted == true then
                    App.S.renderStartedAt = os.time()
                    return
                end
            end
            -- 重启也没用，且确实没有产出文件 → 判失败
            if sizeNow <= 0 then
                self:ReturnToPrevPage()
                self:CleanupRender()
                self:Fail(string.format(
                    "渲染未开始（%d%%，状态“%s”，已等 %d 秒）", pct, jobStatus, elapsed))
                return
            end
        end

        -- ── ④ 兜底：只要"已经不在渲染"且文件不再增长，就认为写完了。
        --      覆盖两种情况：
        --        · st 为 nil（作业已被移除 / 接口返回空）
        --        · 百分比卡在 99 之类的边界值，永远等不到 100
        --      连续 3 次采样大小不变才算完成（单次判断会误判半成品）。
        if (not rendering) and elapsed > 10 then
            if sizeNow > 0 then
                if App.S.lastSize == sizeNow then
                    App.S.sameCount = (App.S.sameCount or 0) + 1
                else
                    App.S.lastSize = sizeNow
                    App.S.sameCount = 0
                end
                if App.S.sameCount >= 3 then
                    self:Log(string.format(
                        "音频导出完成（按文件判定 %.1f MB）", sizeNow / 1048576))
                    self:ReturnToPrevPage()
                    self:CleanupRender()
                    self:StartPython(audioNow)
                    return
                end
            elseif elapsed > 60 then
                self:ReturnToPrevPage()
                self:CleanupRender()
                self:Fail("拿不到渲染状态，且未生成音频文件")
                return
            end
        end

        -- ── ⑤ 总超时
        if elapsed > 900 then
            self:ReturnToPrevPage()
            self:CleanupRender()
            self:Fail("导出超时（15 分钟）")
        end

    elseif ph == "probing" then
        -- ══════════════════════════════════════════════════════════════
        -- 异步等探测结果（原来是同步忙等 15 秒，界面整个卡死）
        --   每 0.5 秒只做一次 loadfile，代价可以忽略，界面全程可响应。
        -- ══════════════════════════════════════════════════════════════
        local t = loadLuaTable(App.S.srcLua or (PROBE_WORK .. "\\src.lua"))
        if t then
            self:OnProbe(t)
            return
        end
        local el = os.time() - (App.S.probeStartedAt or os.time())
        if el > 20 then
            -- 超时：先看有没有纯文本兜底产出，没有才走渲染
            local src = ""
            local tp = App.S.srcTxt or (PROBE_WORK .. "\\src_path.txt")
            if exists(tp) then
                src = tail(tp, 4000):gsub("[\r\n]", "")
                src = src:gsub("^%s+", ""):gsub("%s+$", "")
            end
            if src ~= "" then
                ELog("探测超时（20 秒），但拿到 src_path.txt，按快速路径继续")
                App.S.audioPath = src
                self:SetSrtName(src)
                return self:StartPython(src)
            end
            ELog("探测超时（20 秒），转渲染")
            self:Log("读取时间线超时，走渲染导出")
            self:StartRender()
        end

    elseif ph == "landing" then
        -- ══════════════════════════════════════════════════════════════
        -- 落轨：外部脚本把 SRT 挂到字幕轨后，会写一个 land.lua
        --   （return { ok=.., total=.., sidecar=.., item=.., err=.. }）
        -- 用 loadfile 加载 —— 与进度/心跳同一套机制。
        -- ══════════════════════════════════════════════════════════════
        local d = loadLuaTable(App.S.landFile)
        if d then
            App.S.phase = "done"
            if d.ok then
                local n = tonumber(d.total) or tonumber(d.placed) or 0
                local rep = tonumber(d.replaced) or 0
                local off = tonumber(d.offset) or 0
                if rep > 0 then
                    self:Log(string.format("  · 字幕轨上原有的 %d 条已替换", rep))
                end
                self:Status(string.format("完成：%d 条字幕已上轨", n))
                self:Log(string.format("已挂到时间线字幕轨：%d 条", n))

                -- ★ 时间线上已有素材时，字幕只能在【新建的空时间线】上正确落位，
                --   同时把素材精确复制过去（原时间线全程不动）。要说清楚。
                local nt = tostring(d.new_timeline or "")
                if nt ~= "" then
                    self:Log("────────────────")
                    self:Log("已新建时间线：「" .. nt .. "」")
                    self:Log("  · 字幕、视频、音频都在这条时间线上，位置已对齐")
                    self:Log("  · 你原来的时间线没有被改动")
                    local nc = tonumber(d.clips) or 0
                    if nc > 0 then
                        self:Log(string.format("  · 已复制 %d 个素材片段过去", nc))
                    end
                    self:Log("────────────────")
                end

                if off > 0 then
                    self:Log(string.format("  · 已与素材对齐（起始帧 %d）", off))
                else
                    self:Log("  · 已与素材对齐（素材从时间线 0 帧开始）")
                end
                local side = tostring(d.sidecar or "")
                if side ~= "" then
                    self:Log("  · 素材旁已生成：" .. side)
                end
                local item = tostring(d.item or "")
                if item ~= "" then
                    self:Log("  · 已导入媒体池：" .. item)
                end
            else
                local err = tostring(d.err or "")
                self:Status("适配字幕失败")
                self:Log("错误：挂轨未成功" .. (err ~= "" and ("：" .. err) or ""))
                self:Log("  · 字幕文件在：" .. App.S.srt)
                self:Log("  · 手动导入：菜单「文件 → 导入 → 字幕文件」选它，"
                    .. "或从媒体池拖到字幕轨")
                self:Log("  · 自动挂轨需要 首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络")
            end
            self:EnableButtons()
            return
        end

        -- 超时兜底（Resolve 忙 / 外部脚本访问被关掉时）
        local el = os.time() - (App.S.landStartedAt or os.time())
        if el > 40 then
            App.S.phase = "done"
            self:EnableButtons()
            self:Status("适配字幕超时")
            self:Log("错误：挂轨超时（可能未开启「外部脚本使用」，或 Resolve 正忙）")
            self:Log("  · 字幕文件在：" .. App.S.srt)
            self:Log("  · 可以再点一次「适配字幕」重试；"
                .. "或手动：菜单「文件 → 导入 → 字幕文件」选它")
        end

    elseif ph == "importing" then
        -- ══════════════════════════════════════════════════════════════
        -- 识别完自动做的那一步：把 SRT 放进媒体池（+ 素材旁一份）。
        --   不动时间线 —— 新建时间线要等用户点「适配字幕」。
        -- ══════════════════════════════════════════════════════════════
        local d = loadLuaTable(App.S.importFile)
        if d then
            App.S.phase = "done"
            if d.ok then
                local item = tostring(d.item or "")
                if item ~= "" then
                    self:Log("  · 已导入媒体池：" .. item)
                end
                local side = tostring(d.sidecar or "")
                if side ~= "" then
                    self:Log("  · 素材旁已生成：" .. side)
                end
                self:Status(string.format("完成：%d 条字幕", tonumber(App.S.count) or 0))
            else
                local err = tostring(d.err or "")
                self:Log("错误：导入媒体池未成功" .. (err ~= "" and ("：" .. err) or ""))
                self:Log("  · 自动导入需要 首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络")
            end
            self:Log("")
            self:Log("要让字幕上时间线，点「适配字幕」")
            self:EnableButtons()
            -- 识别完成后顺带把字幕载入右侧编辑区
            self:LoadSubs(true)
            return
        end

        local el = os.time() - (App.S.importStartedAt or os.time())
        if el > 30 then
            App.S.phase = "done"
            self:EnableButtons()
            self:Log("错误：导入媒体池超时（字幕文件仍在：" .. App.S.srt .. "）")
        end

    elseif ph == "syncing" then
        -- ══════════════════════════════════════════════════════════════
        -- 「更新字幕」之后的自动同步：把最新的 SRT 重新导入媒体池。
        --   不动时间线 —— 要重挂字幕轨仍然走「适配字幕」。
        --   import_to_pool 会先删掉媒体池里【同名且是字幕类型】的旧项再导入，
        --   所以媒体池里不会堆出好几份，等于原地替换。
        -- ══════════════════════════════════════════════════════════════
        local d = loadLuaTable(App.S.importFile)
        if d then
            App.S.phase = "done"
            self:EnableButtons()
            if d.ok then
                local item = tostring(d.item or "")
                self:Status("字幕已保存并同步媒体池")
                self:Log("媒体池已同步：" .. (item ~= "" and item or App.S.srt))
                local side = tostring(d.sidecar or "")
                if side ~= "" then
                    self:Log("  · 素材旁副本已更新：" .. side)
                end
            else
                local err = tostring(d.err or "")
                self:Status("字幕已保存，媒体池同步失败")
                self:Log("错误：媒体池同步失败" .. (err ~= "" and ("：" .. err) or ""))
                self:Log("  · 自动同步需要 首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络")
                self:Log("  · 字幕文件本身已是最新：" .. App.S.srt)
            end
            return
        end
        local el = os.time() - (App.S.syncStartedAt or os.time())
        if el > 30 then
            App.S.phase = "done"
            self:EnableButtons()
            self:Status("字幕已保存，媒体池同步超时")
            self:Log("错误：媒体池同步超时（字幕文件本身已是最新：" .. App.S.srt .. "）")
            self:Log("  · 检查 首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络")
        end

    elseif ph == "exporting" then
        local d = loadLuaTable(App.S.exportFile)
        if d then
            App.S.phase = "done"
            self:EnableButtons()
            if d.ok then
                self:Status(string.format("已导出 %d 个文件", tonumber(d.paths) or 0))
                self:Log("已导出到：" .. tostring(d.dir))
                for ln in tostring(d.names or ""):gmatch("[^\r\n]+") do
                    self:Log("  · " .. ln)
                end
            else
                self:Status("导出失败")
                self:Log("错误：导出失败：" .. tostring(d.err or ""))
            end
            return
        end
        local el = os.time() - (App.S.exportStartedAt or os.time())
        if el > 30 then
            App.S.phase = "done"
            self:EnableButtons()
            self:Status("导出超时")
            self:Log("错误：导出超时")
        end

    elseif ph == "recognizing" then
        -- ══════════════════════════════════════════════════════════════
        -- 进度读取：两个通道
        --  ① 首选 status.lua —— Python 写的 `return {pct=..,count=..}`
        --     用 loadfile 加载。**实测 loadfile 在本机 Resolve 一定可用**，
        --     而 io.open 在 Windows 上既不支持中文路径、沙箱里还可能是 nil。
        --  ② 兜底 status.txt —— 纯文本 "百分比%|条数"
        -- ══════════════════════════════════════════════════════════════
        local pct, cnt, serr = 0, 0, ""
        local st = loadLuaTable(PROBE_WORK .. "\\status.lua")
        local tStamp = 0
        if st then
            pct = tonumber(st.pct) or 0
            cnt = tonumber(st.count) or 0
            tStamp = tonumber(st.t) or 0
            serr = tostring(st.err or "")
            -- ★ 实际跑起来的模型（自定义路径无效时这里会带 ⚠ 说明）
            if tostring(st.model or "") ~= "" then
                App.S.realModel = tostring(st.model)
            end
        else
            local c = ""
            if exists(App.S.statusFile) then c = tail(App.S.statusFile, 48) end
            pct = tonumber(c:match("(%d+)%%") or "0") or 0
            cnt = tonumber(c:match("%%|(%d+)") or "0") or 0
        end
        App.S.count = cnt

        -- ── 引擎明确报错？（Python 写 err 字段）
        --   ★ 必须和"完成"分开判断：以前失败路径也报 pct=100，
        --     于是界面显示"未生成字幕"，用户完全不知道出了什么事。
        if serr ~= "" then
            App.S.phase = "error"
            self:Status("识别失败")
            self:Log("识别失败：" .. serr)
            self:Log("--- 引擎输出 ---")
            local lg = tail(App.S.logFile, 1200)
            if lg ~= "" then self:Log(lg) end
            self:EnableButtons()
            return
        end

        if pct > 0 and pct < 100 then
            pcall(function()
                App.S.items.StartBtn.Text = string.format("识别中 %d%%", pct)
            end)
            self:Status(string.format("识别中... %d%%", pct))
        end

        -- ── 完成？只看进度，不去 exists 中文路径的 srt（Lua 打不开）
        if pct >= 100 then
            self:Finish()
            return
        end

        -- ── 引擎还活着吗？
        -- ★ 用【心跳文件】判断，不用 tasklist 查进程：
        --   io.popen 查进程会阻塞界面（每 0.5 秒一次非常卡），
        --   而且脚本是用 pythonw 启动的，查 python.exe 永远查不到
        --   → 之前因此误报"识别进程已退出"。
        if App.S.pyStartedAt == nil then App.S.pyStartedAt = os.time() end
        local elapsed = os.time() - App.S.pyStartedAt

        if elapsed > 8 then
            local hb = 0
            local hbt = loadLuaTable(PROBE_WORK .. "\\hb.lua")
            if hbt then hb = tonumber(hbt.t) or 0 end
            if hb == 0 then hb = tStamp end   -- 兜底：用进度文件里的时间戳

            local stale
            if hb > 0 then
                stale = (os.time() - hb) > 30
            else
                -- 心跳文件都还没出现（模型加载中）→ 给足宽限
                stale = elapsed > 300
            end

            if stale then
                App.S.phase = "error"
                self:Status("识别进程已退出")
                self:Log("识别进程没有响应（心跳已停），可能已崩溃")
                self:Log("--- 引擎输出 ---")
                local lg = tail(App.S.logFile, 1500)
                if lg ~= "" then self:Log(lg) end
                self:EnableButtons()
            end
        end
    end

    -- ── 收尾：预热常驻识别服务（每次会话只做一次）──────────────
    if ph == "done" and not App.S.srvWarm
        and (tonumber(App.S.count) or 0) > 0 then
        App.S.srvWarm = true
        pcall(function() self:WarmAsrServer() end)
    end

    -- ── 空闲保活 ────────────────────────────────────────────────
    --   worker 空闲 20 分钟会自己退出。它一退，下次点「开始」就得重新
    --   os.execute 拉它 —— 那就会再闪一次黑窗。这里每 30 秒发一个
    --   ping（只是刷新"最近有命令"时间，不启任何进程），把它留住。
    if ph == "idle" or ph == "done" or ph == "error" then
        local nowT = os.time()
        if nowT - (App.S.lastPingAt or 0) >= 30 then
            App.S.lastPingAt = nowT
            self:PingWorker()
        end
    end
end

-- 返回: 完整路径, 字节数（找不到时返回 nil, 0）
function App:FindAudio()
    local files = listFiles(WORK_DIR, "qwen3_audio", ".wav")
    if #files == 0 then return nil, 0 end

    -- ★ 文件名是 qwen3_audio_<YYYYMMDD-HHMMSS>.wav，按字符串排序即按时间先后；
    --   显式取【最新】的一份，避免 bmd.readdir 返回顺序不稳定时误取到旧文件。
    table.sort(files)
    local path = WORK_DIR .. "\\" .. files[#files]
    local size = 0
    if io ~= nil then
        local fh = io.open(path, "rb")
        if fh then size = fh:seek("end") or 0; fh:close() end
    end
    return path, size
end

-- ── 启动 Python ───────────────────────────────────────────────────
-- JSON 字符串转义（只处理必须转义的字符）
-- ★ 中文不转义也不改写：Lua 以 UTF-8 字节原样写出，Python 按 UTF-8 读即可
local function jstr(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end

-- ══════════════════════════════════════════════════════════════
-- ★★ 后台执行器 worker.py 的客户端
--
-- 【为什么要有这一层】
--   os.execute 在 Windows 上必经 cmd.exe，而 cmd.exe 被 Resolve 这种
--   没有控制台的 GUI 进程拉起时，Windows 会新建一个控制台窗口 ——
--   哪怕命令瞬间结束也会「闪一下黑窗」。
--   原来一次「开始生成字幕」要经历 探测 + 识别 两次 os.execute，
--   加上建目录/列目录的 io.popen，用户会看到好几次黑窗。
--
-- 【怎么解决的】
--   worker.py 用 pythonw 启动一次（GUI 子系统，本身无窗口），之后常驻：
--     Lua 写 cmd.json  →  worker 用 CREATE_NO_WINDOW 启动任务  →  写 res.lua
--   全程零窗口。worker 不在时自动拉起（这时会闪一次，且只在首次），
--   worker 完全拉不起来时回退到原来的 os.execute —— 功能不受影响。
-- ══════════════════════════════════════════════════════════════

-- worker 是否还活着：看心跳文件的时间戳
function App:WorkerAlive()
    local t = loadLuaTable(WHB_FILE)
    if not t then return false end
    local ts = tonumber(t.t) or 0
    if ts <= 0 then return false end
    return (os.time() - ts) < 10
end

function App:EnsureWorker()
    if self:WorkerAlive() then return true end

    -- ★ 窗口一创建就预热过 worker（且空闲时一直 ping 保活），
    --   所以正常情况下走到这里它已经活着了，下面的等待基本不会触发。
    if PYTHON == "" then
        -- 绝不静默：以前会退化成 os.execute 一个空路径，
        -- 用户看到的是"任务超时"，完全指不到真因
        self:Log("错误：找不到 Python 运行环境，任务无法启动")
        self:Log("  · 点左下角「关于 → 更改运行环境」指定 python.exe")
        App.S.workerOk = false
        return false
    end
    local py = exists(PYTHONW) and PYTHONW or PYTHON
    pcall(function()
        os.execute('start "" /B "' .. py .. '" "' .. WORKER .. '"')
    end)
    ELog("已尝试拉起 worker")

    for _ = 1, 30 do          -- 最多等 3 秒（原来 6 秒，太久）
        sleepMS()
        if self:WorkerAlive() then
            ELog("worker 就绪")
            App.S.workerOk = true
            return true
        end
    end
    ELog("worker 启动超时")
    App.S.workerOk = false
    return false
end

-- 命令号（每条命令都要和 sess 一起组成唯一键，见 worker.py 的说明）
function App:CmdId()
    App.S.cmdId = (App.S.cmdId or 0) + 1
    return App.S.cmdId
end

-- 写一条命令到 cmd.json。body 是已经拼好的字段文本。
-- ★ 必须带 sess：worker 用 (sess,id) 去重，少了 sess 的话，
--   第二次运行本脚本时发出的 id=1 会被当成上次的重复命令丢掉。
function App:SendCmd(id, body)
    local f = io.open(CMD_FILE, "wb")
    if not f then return false end
    f:write('{\n  "id": ' .. tostring(id) .. ',\n')
    f:write('  "sess": ' .. jstr(App.S.sess) .. ',\n')
    f:write(body)
    f:write('\n}\n')
    f:close()
    return true
end

-- 保活：让 worker 知道"还有人在用"，别自己退出
function App:PingWorker()
    if not self:WorkerAlive() then return false end
    local id = self:CmdId()
    if not self:SendCmd(id, '  "cmd": "ping"') then return false end
    return true
end

-- args 可以是字符串（单个参数）或字符串数组
local function argList(args)
    if type(args) == "string" then return { args } end
    if type(args) == "table" then return args end
    return {}
end

-- 兜底：worker 不可用时退回老办法（会闪一次窗，但功能完整）
function App:RunDirect(script, args)
    if PYTHON == "" then
        self:Log("错误：找不到 Python 运行环境，无法启动 " .. tostring(script))
        return false
    end
    local py = exists(PYTHONW) and PYTHONW or PYTHON
    local cmd = 'start "" /B "' .. py .. '" "' .. script .. '"'
    for _, a in ipairs(argList(args)) do cmd = cmd .. ' "' .. a .. '"' end
    ELog("直接启动: " .. cmd)
    pcall(function() os.execute(cmd) end)
    return true
end

-- 通过 worker 启动一个任务脚本，等它确认「已启动」
function App:RunTask(script, args)
    local list = argList(args)

    if App.S.workerOk == false then
        return self:RunDirect(script, list)
    end

    if not self:EnsureWorker() then
        App.S.workerOk = false
        return self:RunDirect(script, list)
    end

    local id = self:CmdId()
    pcall(function() os.remove(RES_FILE) end)
    -- 记下这一条命令。Tick 靠它去接 worker 回传的退出码
    -- （rt\rc_<sess>_<id>.lua）——不出事时它只是被安静地清掉。
    -- ★ sess 必须和 worker.py 的清洗规则一致：去掉非 [0-9A-Za-z_-]
    --   的字符再截前 8 位，否则两边文件名对不上，退出码永远接不到。
    local s0 = tostring(App.S.sess or ""):gsub("[^0-9A-Za-z_%-]", "")
    local safeSess = s0:sub(1, 8)
    if safeSess == "" then safeSess = "s" end
    App.S.curTask = {
        id = id, script = script, startedAt = os.time(),
        rcFile = PROBE_WORK .. "\\rc_" .. safeSess .. "_" .. tostring(id) .. ".lua",
        log = "",
    }
    App.S.ignoreRc = false

    local body = '  "script": ' .. jstr(script) .. ',\n  "args": ['
    for i, a in ipairs(list) do
        if i > 1 then body = body .. ", " end
        body = body .. jstr(a)
    end
    body = body .. "]"

    if not self:SendCmd(id, body) then
        App.S.workerOk = false
        return self:RunDirect(script, list)
    end

    -- worker 现在 0.15 秒扫一次命令文件，正常 0.2~0.5 秒就有回执。
    -- ★ 这段死等是在 RunLoop 线程里跑的，期间整个界面点不动。
    --   上限压到 1.2 秒：等不到就回退到直接启动（会闪一次窗，但功能完整），
    --   比让用户干瞪 2.5 秒好。
    for _ = 1, 12 do
        local t = loadLuaTable(RES_FILE)
        if t and tonumber(t.id) == id then
            ELog("任务已下发 id=" .. tostring(id)
                .. " ok=" .. tostring(t.ok) .. " pid=" .. tostring(t.pid))
            -- 把 worker 给的日志路径记下来：一出事直接把路径报给用户
            if App.S.curTask and App.S.curTask.id == id then
                App.S.curTask.log = tostring(t.log or "")
            end
            if t.ok == false or t.ok == nil then
                -- ★ worker 明确说没起来（互斥 busy / 找不到脚本 / 启动失败）。
                --   以前这里无脑 return true，调用方把 phase 设成
                --   recognizing/landing 之后干等满超时才报错，
                --   白等几十秒还以为是 Resolve 卡了。
                App.S.curTask = nil
                local why = tostring(t.err or "worker 未接受该任务")
                if t.busy then why = "已有同一个任务在运行，稍等一下再点" end
                self:Log("错误：" .. why)
                self:Status("任务未能启动")
                return false
            end
            return true
        end
        sleepMS()
    end

    ELog("worker 无响应，回退直接启动")
    return self:RunDirect(script, list)
end

-- 让 worker 杀掉它启动的所有任务（停止按钮用）
-- ★ 不用 taskkill：那也是 os.execute，一样会闪窗
function App:KillTasks()
    -- 被 kill 的进程退出码是非 0，不能拿它当"任务失败"报
    App.S.ignoreRc = true
    if self:WorkerAlive() then
        local id = self:CmdId()
        pcall(function() os.remove(RES_FILE) end)
        self:SendCmd(id, '  "cmd": "kill"')
        ELog("已下发 kill id=" .. tostring(id))
        return
    end

    -- ★ worker 不在时的兜底：用 worker 落下的 pids.lua【按 PID 精确杀】。
    --   绝对不能退化成 taskkill /F /IM python.exe —— 那会把这台机器上
    --   所有 python 进程（用户自己的脚本、别的工具）一起干掉。
    local pids = loadLuaTable(PIDS_FILE)
    local list = {}
    if pids then
        for _, v in pairs(pids) do
            local p = tonumber(v)
            if p and p > 0 then list[#list + 1] = p end
        end
    end
    if #list == 0 then
        ELog("没有可结束的任务进程")
        return
    end
    local cmd = "cmd /c taskkill /F"
    for _, p in ipairs(list) do cmd = cmd .. " /PID " .. tostring(p) end
    cmd = cmd .. " 2>nul"
    ELog("按 PID 结束: " .. cmd)
    pcall(function() os.execute(cmd) end)
end

function App:StartPython(audio)
    self:Log("启动识别引擎...")

    -- ★★ 用【参数文件】而不是命令行传值。
    --   命令行按 GBK 解读参数，中文路径（SRT 输出目录、素材路径）会变乱码。
    --   参数文件是 UTF-8 JSON，Python 读出来完全正确。
    local argsFile = PROBE_WORK .. "\\args.json"
    local f = io.open(argsFile, "wb")
    if not f then
        self:Fail("无法写入参数文件")
        return
    end
    f:write("{\n")
    f:write('  "audio": ' .. jstr(audio) .. ",\n")
    f:write('  "srt": ' .. jstr(App.S.srt) .. ",\n")
    f:write('  "txt": ' .. jstr(App.S.txt or "") .. ",\n")
    f:write('  "lang": ' .. jstr(App.S.langCode) .. ",\n")
    f:write('  "max_chars": ' .. tostring(App.S.maxChars or 12) .. ",\n")
    f:write('  "no_gap": ' .. (App.S.noGap and "true" or "false") .. ",\n")
    f:write('  "no_punct": ' .. (App.S.noPunct and "true" or "false") .. ",\n")
    f:write('  "strip_all_punct": ' .. (App.S.allPunct and "true" or "false") .. ",\n")
    f:write('  "prompt": ' .. jstr(App.S.prompt) .. ",\n")
    f:write('  "status": ' .. jstr(App.S.statusFile) .. ",\n")
    f:write('  "model": ' .. jstr(App.S.modelPath or "") .. ",\n")
    f:write('  "log": ' .. jstr(App.S.logFile) .. "\n")
    f:write("}\n")
    f:close()
    ELog("参数文件已写入: " .. argsFile)

    self:Log("使用模型：" .. (App.S.modelPath or "(自动)"))
    self:Log("素材：" .. tostring(audio))

    -- 命令行里只有纯 ASCII 路径，编码问题彻底绕开
    if not self:RunTask(BRIDGE, argsFile) then
        -- 起不来就把场子还给用户（互斥 busy / 启动失败）。
        -- 不这么做的话 phase 卡在 recognizing，要等满超时才动。
        App.S.phase = "error"
        self:EnableButtons()
        return
    end

    App.S.phase = "recognizing"
    self:Status("识别中...")
end

-- ── 完成 ──────────────────────────────────────────────────────────
function App:Finish()
    pcall(function() App.S.items.StartBtn.Text = "开始生成字幕" end)

    -- ★ 字幕条数由 Python 写进状态文件（Lua 的 io.open 打不开中文路径的 srt）
    local count = tonumber(App.S.count or 0)

    if count <= 0 then
        App.S.phase = "done"
        self:EnableButtons()
        self:Status("未生成字幕")
        self:Log("--- 引擎输出 ---")
        local lg = tail(App.S.logFile, 1200)
        if lg ~= "" then self:Log(lg) end
        return
    end

    self:Status(string.format("完成　%d 条字幕", count))
    self:Log(string.format("识别完成：%d 条字幕", count))

    -- ★ 回显【实际使用】的模型，而不是用户填的那个。
    --   自定义路径不存在/没有 config.json 时引擎会静默回退到默认模型 ——
    --   不回显的话用户会一直以为自己在跑 1.7B。
    if App.S.realModel and App.S.realModel ~= "" then
        self:Log("实际模型：" .. App.S.realModel)
    end
    self:Log("字幕文件：" .. App.S.srt)
    if App.S.txt and App.S.txt ~= "" then
        self:Log("文稿文件：" .. App.S.txt)
    end

    -- ★ 识别完【自动】把字幕放进媒体池（+ 素材旁一份），
    --   不再等到点「适配字幕」才做。
    --   但**不自动动时间线** —— 新建时间线/改字幕轨是要用户确认的动作。
    self:StartLand("media")
end

-- ══════════════════════════════════════════════════════════════════
-- 预热常驻 ASR 服务（asr_server.py）
--
-- ★ 为什么：模型加载（ASR + 对齐）每次 6~7 秒，而 3 分半的素材识别
--   本身才 30 秒。识别成功一次之后就把服务拉起来，下次直接复用，
--   省掉这 6~7 秒和一次 CUDA 初始化。
-- ★ 它只是加速器：拉不起来 / 崩了 / 模型不匹配，resolve_bridge.py
--   都会自动退回本地加载，功能一点不受影响。所以全流程包 pcall。
-- ══════════════════════════════════════════════════════════════════
function App:WarmAsrServer()
    pcall(function()
        local f = io.open(SRV_PRELOAD, "wb")
        if f then
            f:write(tostring(App.S.modelPath or ""))
            f:close()
        end
    end)
    pcall(function() self:RunTask(ASR_SERVER, {}) end)
    ELog("已预热 ASR 常驻服务")
end

-- ══════════════════════════════════════════════════════════════════
-- 「适配字幕」：把已生成的 SRT 挂到字幕轨 + 导入媒体池 + 素材旁副本
--   实际动作全在外部脚本 land_subtitle.py 里做（Lua 侧只读结果）。
--   ★ 为什么不在 Lua 里做：AppendToTimeline / ImportMedia 一旦参数不对，
--     会把整个 Resolve 的 API 会话搞死（实测崩过两次），隔离到独立进程更安全。
-- ══════════════════════════════════════════════════════════════════
-- 「适配字幕」到底能不能用。
-- ★★ 判据必须是【表格里的字幕条数】，不能是识别计数 App.S.count：
--    用「读取媒体池字幕」载入时 count 是 0，而 EnableButtons 早就改成
--    按 #subs 判断了 —— 两边不一致，按钮是亮的、点了却报"还没有字幕"。
--    真实症状：从媒体池读进 19 条字幕，点「适配字幕」毫无反应。
function App:CanLand()
    if #App.S.subs == 0 then return false end
    if not App.S.srt or App.S.srt == "" then return false end
    return true
end

function App:DoLand()
    if BUSY_PHASES[App.S.phase] then
        self:Status("任务进行中，请稍候")
        self:Log("当前任务还没结束，等它跑完再点「适配字幕」")
        return
    end

    if not self:CanLand() then
        self:Status("还没有字幕")
        self:Log("还没有字幕可挂。请先点「开始生成字幕」，或用「读取媒体池字幕」载入。")
        return
    end

    self:Log("")
    self:Log("适配字幕")
    self:Log("  · 字幕文件：" .. App.S.srt)
    self:StartLand()
end

-- ══════════════════════════════════════════════════════════════════
-- 把字幕挂到时间线的【字幕轨】+ 导入媒体池 + 在源素材旁放一份 srt
--
-- ★ 为什么这段逻辑放在外部 Python 脚本里而不是 Lua 里：
--   1. Lua 侧的异常会被 Resolve 静默吞掉，落轨失败时只能看到"没反应"
--   2. ★★ 字幕媒体项给 AppendToTimeline 传 startFrame/endFrame 会
--      把整个 Resolve 当场打崩（实测崩了两次）—— 这类坑集中在 Python 里守，
--      Lua 只负责"启动 + 读结果"
--   3. 中文路径在 Lua 的 io.open / 命令行里都不可靠
--
--   前置条件：首选项 → 系统 → 常规 → 外部脚本使用 = 本地/网络
-- ══════════════════════════════════════════════════════════════════
-- mode = "media"    只导入媒体池 + 素材旁副本（识别后自动入库 / 更新字幕后的同步）
-- mode = "timeline" 完整落轨（新建时间线 + 挂字幕轨，由「适配字幕」触发）
-- reason = "sync"   来自「更新字幕」的同步：走独立的 syncing 阶段，
--                   日志文案和识别后那次自动入库区分开
function App:StartLand(mode, reason)
    mode = tostring(mode or "timeline")
    local isMedia = (mode == "media")
    local isSync = isMedia and (reason == "sync")
    local outLua = isMedia and App.S.importFile or App.S.landFile
    local cfgFile = isMedia and App.S.importCfg or App.S.landCfg

    pcall(function() os.remove(outLua) end)

    local f = io.open(cfgFile, "wb")
    if not f then
        App.S.phase = "done"
        self:EnableButtons()
        self:Log("错误：无法写入参数，字幕已存到上面的路径")
        return
    end
    f:write("{\n")
    f:write('  "srt": ' .. jstr(App.S.srt) .. ",\n")
    f:write('  "media": ' .. jstr(App.S.audioPath or "") .. ",\n")
    f:write('  "mode": ' .. jstr(mode) .. ",\n")
    f:write('  "out_lua": ' .. jstr(outLua) .. "\n")
    f:write("}\n")
    f:close()
    ELog("落轨参数已写入 " .. cfgFile .. " mode=" .. mode)

    -- 命令行里只有纯 ASCII 路径（中文值都在 json 里）
    if not self:RunTask(LAND_SCRIPT, cfgFile) then
        App.S.phase = "done"
        self:EnableButtons()
        return
    end

    if isMedia then
        -- 两种语义共用同一个输出文件（importFile），靠 phase 区分
        if isSync then
            App.S.phase = "syncing"
            App.S.syncStartedAt = os.time()
            self:Status("正在同步媒体池...")
        else
            App.S.phase = "importing"
            App.S.importStartedAt = os.time()
            self:Status("正在导入媒体池...")
        end
    else
        App.S.phase = "landing"
        App.S.landStartedAt = os.time()
        self:Status("正在挂到字幕轨...")
        self:Log("正在把字幕挂到时间线字幕轨…")
    end
end

-- ══════════════════════════════════════════════════════════════
-- 字幕编辑器
--
-- ★ 为什么读写 SRT 要绕 Python：SRT 在中文目录里，Lua 的 io.open 走
--   ANSI 接口打不开中文路径。数据流：
--     读：subs_io.py dump → rt\subs.lua   → Lua 用 loadfile 读
--     写：Lua 拼 JSON    → rt\subs_in.json → subs_io.py save → 覆写 SRT
-- ══════════════════════════════════════════════════════════════

-- ★ fmtSec / parseTimeText 已上移到文件前部（BuildUI 之前）。
--   原因：Lua 的 local 只对【定义之后】的代码可见，而 BuildUI 里的
--   就地编辑回调（ItemChanged）要用到它们。留在原处的话，回调里
--   parseTimeText 会被解析成全局变量 → nil → "attempt to call a nil value"。

-- 把查找词转成 Lua 模式的字面量（中文不受影响，只转义 ASCII 元字符）
local function patternEscape(s)
    return (tostring(s):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- ══════════════════════════════════════════════════════════════
-- 查找：重复序号 + 关键词高亮 + 跳到对应行
--
-- ★★ 为什么整块放在这里（patternEscape 之后、FillSubTreeBatch 之前）：
--    Lua 的 local 只对【定义之后】的代码可见。分批填表
--    （FillSubTreeBatch）也要用这些高亮色，放在文件后部的话
--    它会拿到 nil —— 和之前 fmtSec/parseTimeText 那个 bug 同一类。
-- ══════════════════════════════════════════════════════════════
-- Resolve 是深色界面，用琥珀色系：普通匹配暗金、当前这一处亮金，
-- 一眼能看出"你停在这儿"。
local HILITE_COLOR = { R = 0.30, G = 0.26, B = 0.10, A = 0.60 }
local HILITE_CUR   = { R = 0.58, G = 0.44, B = 0.10, A = 0.90 }
-- 全透明 = 清除高亮，把底色还给 AlternatingRowColors 的斑马纹
local HILITE_CLEAR = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }

-- 给某一格上色（列下标 3 = 第 4 列"字幕文本"）。
-- ★ 失败静默：个别 Resolve 版本的 TreeItem 不暴露 BackgroundColor，
--   那种情况下高亮只是不显示，跳转和序号照旧能用。
local function tintCell(item, color)
    if not item then return end
    pcall(function() item.BackgroundColor[3] = color end)
end

-- 统计 kw 在 s 里出现的次数（纯文本匹配，不走 Lua 模式）
local function countIn(s, kw)
    if kw == "" then return 0 end
    local cnt, from = 0, 1
    while true do
        local p = s:find(kw, from, true)
        if not p then break end
        cnt = cnt + 1
        from = p + #kw
    end
    return cnt
end

-- 当前查找框里的词
function App:FindKeyword()
    local kw = ""
    pcall(function() kw = tostring(App.S.items.FindInput.Text or "") end)
    return kw
end

-- 重建匹配索引：matchRows[k] = 第 k 处所在行号
-- ★ 关键词变过、或字幕内容变过，都必须重建 —— 否则"第几处"是假的。
function App:RebuildMatches()
    local kw = self:FindKeyword()
    App.S.matchKw = kw
    App.S.matchRows = {}
    App.S.matchTotal = 0
    App.S.curMatch = nil
    if kw == "" then return end
    for i = 1, #App.S.subs do
        local c = countIn(tostring(App.S.subs[i].t or ""), kw)
        for _ = 1, c do
            App.S.matchTotal = App.S.matchTotal + 1
            App.S.matchRows[App.S.matchTotal] = i
        end
    end
end

-- 第 row 行在匹配索引里的最后一处（用户手动点了某行时用）
function App:MatchIndexAtRow(row)
    if not App.S.matchRows then return nil end
    local last = nil
    for k, r in ipairs(App.S.matchRows) do
        if r == row then
            last = k
        elseif r > row then
            break
        end
    end
    return last
end

-- 把高亮刷进表格。关键词变过 / 字幕内容变过都调它。
function App:ApplyFindHighlight()
    local items = App.S.items
    if not items or not items.SubTree then return end
    local kw = self:FindKeyword()
    if kw ~= App.S.matchKw or not App.S.matchRows then
        self:RebuildMatches()
    end
    local curRow = nil
    if App.S.curMatch and App.S.matchRows then
        curRow = App.S.matchRows[App.S.curMatch]
    end
    -- 先全清，再按索引上色：这样删词、换词都不会留下残色
    for i = 1, #App.S.subs do
        tintCell(items.SubTree:TopLevelItem(i - 1), HILITE_CLEAR)
    end
    if App.S.matchRows then
        for _, r in ipairs(App.S.matchRows) do
            tintCell(items.SubTree:TopLevelItem(r - 1),
                     (r == curRow) and HILITE_CUR or HILITE_COLOR)
        end
    end
end

-- 下发 dump：让 Python 把 SRT 转成 Lua 表
function App:LoadSubs(quiet)
    if not App.S.srt or App.S.srt == "" then
        if not quiet then self:Log("还没有字幕文件，先生成字幕。") end
        return
    end
    local f = io.open(App.S.subsCfg, "wb")
    if not f then
        self:Log("错误：无法写入字幕读取参数")
        return
    end
    f:write("{\n")
    f:write('  "mode": "dump",\n')
    f:write('  "srt": ' .. jstr(App.S.srt) .. ",\n")
    f:write('  "out": ' .. jstr(App.S.subsLua) .. "\n")
    f:write("}\n")
    f:close()

    pcall(function() os.remove(App.S.subsLua) end)
    if not self:RunTask(SUBS_IO, App.S.subsCfg) then
        -- ★ worker 拒绝（互斥 busy / 找不到脚本）：别置 pending 去干等 20 秒
        --   超时 —— 那样报的是"读取字幕超时"，和真因无关。直接说清楚。
        App.S.subsPending = false
        self:Log("错误：字幕读取未能启动（worker 拒绝或不可用）")
        return
    end
    App.S.subsPending = true
    App.S.subsStartedAt = os.time()
end

-- 用一份字幕数据重建表格
function App:FillSubTree(blocks)
    local items = App.S.items
    if not items or not items.SubTree then return end
    App.S.subs = blocks or {}
    local tree = items.SubTree
    pcall(function() tree:Clear() end)
    pcall(function()
        tree:SetHeaderLabels({ "#", "开始", "结束", "字幕文本" })
        tree.ColumnWidth[0] = 46
        tree.ColumnWidth[1] = 92
        tree.ColumnWidth[2] = 92
        tree.ColumnWidth[3] = 340
    end)
    -- ★ 分批填：几百条字幕一次性 NewItem/AddTopLevelItem 会把界面卡死
    --   （Qt 每加一行都重排一次）。第一批同步填，剩下的交给 Tick 续填。
    App.S.treeQueue = nil
    local total = #App.S.subs
    self:FillSubTreeBatch(1, math.min(total, TREE_BATCH))
    if total > TREE_BATCH then
        App.S.treeQueue = TREE_BATCH + 1
    end
    App.S.suppressEdit = true
    pcall(function() items.SubEdit.PlainText = "" end)
    App.S.suppressEdit = false
    -- 表格里有东西才让点这些按钮（字幕也可能来自「读取媒体池字幕」）
    local has = (#App.S.subs > 0)
    pcall(function() items.UpdateSubsBtn.Enabled = has end)
    -- 「适配字幕」按 CanLand 判：没字幕可挂时保持 disabled（灰的），
    -- 不会显得"能点"——用户明确要求过这一点
    pcall(function() items.LandBtn.Enabled = self:CanLand() end)
    pcall(function() items.TxtBtn.Enabled = has end)
    -- 字幕内容整个换过 → 旧匹配索引全部作废，重建并按新内容上色
    self:RebuildMatches()
    self:ApplyFindHighlight()
end

-- 填表格的 [from, to] 区间（闭区间），供 FillSubTree 分批调用
function App:FillSubTreeBatch(from, to)
    local items = App.S.items
    if not items or not items.SubTree then return end
    local tree = items.SubTree
    for i = from, math.min(to, #App.S.subs) do
        local b = App.S.subs[i]
        if not b then break end
        local ok = pcall(function()
            local item = tree:NewItem()
            item.Text[0] = tostring(i)
            item.Text[1] = fmtSec(b.s)
            item.Text[2] = fmtSec(b.e)
            item.Text[3] = tostring(b.t or ""):gsub("\n", " ")
            -- ★ B 方案开关：让单元格可以【在原地打字】。
            --   论坛实测帖的原话：8 个 flag 必须一次全写，
            --   只写想改的那一个（比如只写 ItemIsEditable）不生效。
            --   ItemIsUserCheckable 故意设成 false —— 设 true 会多出复选框。
            pcall(function()
                local f = {
                    ItemIsSelectable    = true,
                    ItemIsDropEnabled   = true,
                    ItemIsTristate      = false,
                    ItemNeverHasChildren = false,
                    ItemIsDragEnabled   = true,
                    ItemIsEditable      = true,
                    ItemIsUserCheckable = false,
                    ItemIsEnabled       = true,
                }
                if item.SetFlags then
                    item:SetFlags(f)
                else
                    item.Flags = f
                end
            end)
            tree:AddTopLevelItem(item)
        end)
        if not ok then
            self:Log("错误：表格填充中断在第 " .. i .. " 行")
            break
        end
    end

    -- 新建的这一批行立刻按当前查找词上色。
    -- ★ 必须放在循环【外面】：以前这段写在每行的循环体里，一批 150 行就要
    --   重建 150 次 isHit 表、重扫 150 行、各发一次 TopLevelItem 跨进程 IPC，
    --   整批 O(150²)。几百条字幕时界面会明显卡一下。
    -- （后面批次的行此刻还不存在，由 FillSubTree 末尾的 ApplyFindHighlight 统一补。）
    if App.S.matchRows and #App.S.matchRows > 0 then
        local curRow = nil
        if App.S.curMatch then curRow = App.S.matchRows[App.S.curMatch] end
        local isHit = {}
        for _, m in ipairs(App.S.matchRows) do isHit[m] = true end
        local hi = math.min(to, #App.S.subs)
        for r = from, hi do
            if isHit[r] then
                tintCell(items.SubTree:TopLevelItem(r - 1),
                         (r == curRow) and HILITE_CUR or HILITE_COLOR)
            end
        end
    end
end

-- 把当前字幕数据写成 Python 能读的 JSON（写回 SRT / 生成文稿共用）
function App:WriteSubsJson()
    if #App.S.subs == 0 then return false end
    local f = io.open(App.S.subsJson, "wb")
    if not f then
        self:Log("错误：无法写入字幕数据")
        return false
    end
    -- ★ 文本为空的行【不写出去】。
    --   编辑框是实时同步的，打字中途把内容删空是很自然的动作；
    --   以前会把它当成一条空字幕写进 SRT（时间轴还在、内容没了）。
    --   识别流程本来就有一道"空块兜底"过滤，手动编辑绕过了它，这里补上。
    local parts, kept = {}, 0
    for _, b in ipairs(App.S.subs) do
        local t = tostring(b.t or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then
            kept = kept + 1
            parts[#parts + 1] = string.format(
                '    { "s": %.3f, "e": %.3f, "t": %s }',
                tonumber(b.s) or 0, tonumber(b.e) or 0, jstr(t))
        end
    end
    if kept == 0 then
        f:close()
        self:Log("错误：所有字幕都是空的，没有内容可保存。")
        return false
    end
    f:write('{\n  "blocks": [\n')
    f:write(table.concat(parts, ",\n"))
    f:write("\n  ]\n}\n")
    f:close()
    return true
end

-- 把当前字幕数据写回 SRT
function App:SaveSubs(quiet)
    if #App.S.subs == 0 then
        if not quiet then self:Log("字幕为空，无需保存。") end
        return false
    end
    if not self:WriteSubsJson() then return false end

    -- ★ 文稿必须跟着一起重新生成。识别时那份 txt 只反映当时的识别结果，
    --   用户在编辑器里改过之后它就过期了，导出会出现"改了没生效"。
    if not App.S.txt or App.S.txt == "" then
        if App.S.srt and App.S.srt ~= "" then
            -- 没记过文稿路径（比如字幕是从媒体池读进来的），按 SRT 同名推一个
            App.S.txt = (App.S.srt:gsub("%.[Ss][Rr][Tt]$", "")) .. ".txt"
        end
    end

    local c = io.open(App.S.subsCfg, "wb")
    if not c then return false end
    c:write("{\n")
    c:write('  "mode": "save",\n')
    c:write('  "srt": ' .. jstr(App.S.srt) .. ",\n")
    c:write('  "in": ' .. jstr(App.S.subsJson) .. ",\n")
    c:write('  "txt": ' .. jstr(App.S.txt or "") .. "\n")
    c:write("}\n")
    c:close()
    if not self:RunTask(SUBS_IO, App.S.subsCfg) then
        -- ★ 任务没起来就不能报"已写回"：否则 SRT 其实还是旧的，
        --   紧接着的「更新字幕 / 适配字幕」会用到过期内容。
        if not quiet then self:Log("错误：字幕写回未能启动（worker 拒绝或不可用）") end
        return false
    end
    if not quiet then
        self:Log("字幕已写回：" .. tostring(App.S.srt))
    end
    return true
end

-- ★ 只按当前字幕重新生成文稿，不碰 SRT。
--   「导出 TXT」在复制之前先跑一次它，保证导出去的是修改过的最新版本。
function App:SyncTxt()
    if #App.S.subs == 0 then return false end
    if not App.S.txt or App.S.txt == "" then
        if not App.S.srt or App.S.srt == "" then return false end
        App.S.txt = (App.S.srt:gsub("%.[Ss][Rr][Tt]$", "")) .. ".txt"
    end
    if not self:WriteSubsJson() then return false end
    local c = io.open(App.S.subsCfg, "wb")
    if not c then return false end
    c:write("{\n")
    c:write('  "mode": "totxt",\n')
    c:write('  "in": ' .. jstr(App.S.subsJson) .. ",\n")
    c:write('  "txt": ' .. jstr(App.S.txt) .. "\n")
    c:write("}\n")
    c:close()
    if not self:RunTask(SUBS_IO, App.S.subsCfg) then return false end
    return true
end

-- ══════════════════════════════════════════════════════════════
-- 把表格滚到第 row 行，并尽量让这一行落在【可视区第一行】
--
-- ★ 用户实测 bug（v1.28）：点「查找下一个」时高亮会亮，但表格纹丝不动，
--   命中行只要在视口外就完全看不到 —— 等于"没跳转"。
--
-- 根因（对照官方文档 Support\Developer\Workflow Integrations\README.txt
-- 里「UIManager Elements」的 Tree 方法表）：
--   Tree 支持的是 ScrollToItem(item)，**根本没有 SetCurrentItem**。
--   原代码把两句塞进【同一个 pcall】里：
--       tree:SetCurrentItem(item)   ← 方法不存在 → 抛错
--       tree:ScrollToItem(item)     ← 上一句已抛错，这句永远执行不到
--   而 pcall 把错误吞掉了 → 表现成"点了什么也没发生"。
--
-- ★ ScrollToItem 对应 Qt 的 scrollToItem(item, EnsureVisible)：
--   只在【看不见】时才滚，而且滚到"刚好看得见"为止（可能停在中间）。
--   想让它顶到第一行，用「先首、再尾、后目标」三步：
--       ① 滚到第 1 行    —— 视图回顶，保证下一步一定会动
--       ② 滚到最后一行  —— 视图落到底，目标行被推到视口【上方之外】
--       ③ 滚到目标行    —— 此时目标在上方，EnsureVisible 向上滚到
--                          刚好露出它为止，正好落在第一行
--   ① ② ③ 是连续同步调用，Qt 要等事件循环空闲才重绘，看不到中间态。
--   若目标行离末尾不足一屏，则不可能顶到第一行，此时只保证"可见"。
-- ══════════════════════════════════════════════════════════════
function App:ScrollRowToTop(row)
    local items = App.S.items
    if not items or not items.SubTree then return end
    local tree = items.SubTree
    local total = #App.S.subs
    if total <= 0 then return end
    if row < 1 then row = 1 end
    if row > total then row = total end

    -- TopLevelItem 是 0 基下标，行号是 1 基
    local function itemAt(idx)
        local it = nil
        pcall(function() it = tree:TopLevelItem(idx - 1) end)
        return it
    end
    -- 滚一个 item。方法名按 Resolve 版本兜底，每句各自 pcall，互不连坐
    local function scrollTo(it)
        if not it then return end
        if pcall(function() tree:ScrollToItem(it) end) then return end
        if pcall(function() tree:SetCurrentItem(it) end) then return end
        pcall(function() tree.CurrentItem = it end)
    end

    local target = itemAt(row)
    if not target then return end

    scrollTo(itemAt(1))           -- ① 回顶
    if total > 1 then
        scrollTo(itemAt(total))   -- ② 落底，把目标行推到视口上方之外
    end
    scrollTo(target)              -- ③ 目标行顶到第一行
end

-- 选中第 i 行（表格高亮 + 编辑框同步）
-- ★ scroll=true：把这一行滚到字幕框可视区第一行（「查找下一个」跳转用）
function App:SelectRow(i, scroll)
    local items = App.S.items
    if not items or not items.SubTree then return end
    if scroll then self:ScrollRowToTop(i) end
    local b = App.S.subs[i]
    if b then
        -- ★ 程序性赋值同样会触发 TextChanged，必须挡掉：
        --   否则同一段文字会被再写回一次，还会把 subsDirty 误标成"有改动"。
        App.S.suppressEdit = true
        pcall(function() items.SubEdit.PlainText = tostring(b.t or "") end)
        App.S.suppressEdit = false
    end
end

-- 把光标移进字幕编辑框并全选（单击/双击一行时用）
function App:FocusSubEdit()
    local items = App.S.items
    if not items or not items.SubEdit then return end
    -- ★★★ Qt 的 setFocus 需要【FocusReason 参数】。
    --   写成无参的 :SetFocus() 时，Fusion 会因为参数不足直接抛错 ——
    --   而我们外面套了 pcall，错误被静默吞掉，症状就是
    --   "点了行、文字也填进去了、但就是没有光标，还得手动点一下输入框"。
    --   先按 Qt 签名传参；个别版本不认再退回无参写法。
    local okSet = pcall(function()
        items.SubEdit:SetFocus("OtherFocusReason")
    end)
    if not okSet then
        pcall(function() items.SubEdit:SetFocus() end)
    end
    pcall(function() items.SubEdit:SelectAll() end)
end

-- ★ 「更新字幕」= 把表格里的修改写进 SRT 文件（落盘）。
--   编辑框里的改动在打字那一刻就已经实时写回表格了（见 SubEdit.TextChanged），
--   所以这个按钮【不管】提交编辑，它只负责保存。
--   ★ 顺带去掉了「清空编辑框 = 删除该条」这个副作用：
--     实时同步下，打字中途把内容删空会把整条字幕误删，太危险。
function App:UpdateSubRow()
    if #App.S.subs == 0 then
        self:Status("还没有字幕")
        self:Log("还没有字幕可保存。先点「开始生成字幕」，或用「读取媒体池字幕」载入一份。")
        return
    end
    if self:SaveSubs(false) then
        App.S.subsDirty = false
        self:Status(string.format("已保存 %d 条字幕", #App.S.subs))
        self:Log(string.format("字幕已写回文件：%d 条", #App.S.subs))
        -- ★ 紧接着自动同步一次媒体池（媒体池不监视文件变化，不重新导入
        --   显示的还是旧内容）。延迟 1 秒启动，避开"写文件/读文件"撞车。
        if App.S.srt and App.S.srt ~= "" then
            App.S.pendingSync = os.time() + 1
        else
            self:Log("  · 没有记住字幕文件路径，跳过媒体池同步")
        end
    else
        self:Status("保存失败，详见日志")
    end
end

-- 把 Resolve 播放头移到指定秒（查找/替换跳转时联动，字幕即点即看）
-- ★ 两个官方实测细节：
--   1. 不在 edit/cut/color/fairlight/deliver 页面时先切回 edit ——
--      否则 SetCurrentTimecode 静默无效（点了没反应）
--   2. 时间码是 "HH:MM:SS:FF" 字符串，帧号 = 时间线起始帧 + 秒×帧率
--      （长直播时间线从 01:00:00 开始，起始帧非 0，必须加 base）
function App:JumpPlayhead(sec)
    local tl = App.timeline
    if not tl then return false end
    local fps = App.S.fps or 0
    if fps <= 0 then
        pcall(function()
            fps = tonumber(tl.GetSetting("timelineFrameRate")) or 0
        end)
    end
    if not fps or fps <= 0 then return false end
    sec = tonumber(sec) or 0
    if sec < 0 then sec = 0 end

    pcall(function()
        local pg = App.resolve and App.resolve:GetCurrentPage() or nil
        if pg and pg ~= "edit" and pg ~= "cut" and pg ~= "color"
           and pg ~= "fairlight" and pg ~= "deliver" then
            App.resolve:OpenPage("edit")
        end
    end)

    local tc = self:SecToTimecode(sec, tl, fps)
    if not tc then return false end
    local ok = pcall(function() return tl:SetCurrentTimecode(tc) end)
    return ok and true or false
end

-- ★ 秒 → 时间码 "HH:MM:SS:FF"（帧号 = 时间线起始帧 + 秒×帧率）
--   抽成独立函数：状态栏要显示同一个时间码，不能各算各的，
--   否则跳转位置和显示可能对不上（尤其长直播时间线起始帧非 0）。
--   fps<=0 或拿不到时间线时返回 nil，调用方自行降级。
function App:SecToTimecode(sec, tl, fps)
    tl = tl or App.timeline
    if not tl then return nil end
    local f = tonumber(fps) or App.S.fps or 0
    if not f or f <= 0 then
        pcall(function()
            f = tonumber(tl.GetSetting("timelineFrameRate")) or 0
        end)
    end
    if not f or f <= 0 then return nil end
    local s = tonumber(sec) or 0
    if s < 0 then s = 0 end
    local base = 0
    pcall(function() base = tonumber(tl:GetStartFrame()) or 0 end)
    -- ★ 帧率取整后必须 ≥ 1：否则 `fr % 0` 会直接抛错（fps 落在 (0, 0.5) 时）。
    local fint = math.floor(f + 0.5)
    if fint < 1 then fint = 1 end
    local fr = math.floor((base or 0) + s * f + 0.5)
    return string.format("%02d:%02d:%02d:%02d",
        math.floor(fr / (3600 * f)),
        math.floor((fr / (60 * f)) % 60),
        math.floor((fr / f) % 60),
        math.floor(fr % fint))
end

-- 查找下一处
-- ★ 状态栏报的是"第 X / Y 处"，不是"第 X 行"——同一个词在一条字幕里
--   可能出现多次，行号会重复，报行号等于没报。Y 是总处数，
--   所以"找到第 3 处、一共 5 处"一眼就知道还有多少要改。
function App:FindNext()
    local kw = self:FindKeyword()
    if kw == "" then
        self:Status("请先输入查找内容")
        return
    end
    if #App.S.subs == 0 then
        self:Status("字幕表为空")
        return
    end
    if kw ~= App.S.matchKw or not App.S.matchRows then
        self:RebuildMatches()
    end
    if App.S.matchTotal == 0 then
        self:Status("未找到：" .. kw)
        self:Log("未找到：" .. kw)
        return
    end
    -- 循环：数到末尾就绕回第一处
    local idx = (App.S.curMatch or 0) + 1
    if idx > App.S.matchTotal then idx = 1 end
    App.S.curMatch = idx
    local row = App.S.matchRows[idx]
    App.S.selRow = row
    -- SelectRow(row, true) 内部走 ScrollRowToTop：先把视图回顶、再落底，
    -- 最后滚到命中行 —— 命中行会成为字幕框【可视区的第一行】
    -- （目标行离末尾不足一屏时退化为"保证可见"，见 ScrollRowToTop 注释）
    self:SelectRow(row, true)
    self:ApplyFindHighlight()
    -- 播放头联动：跳到这条字幕的开始时间（看不到效果时不报错，
    -- 可能是当前页面不支持或帧率没取到）
    local b = App.S.subs[row]
    -- ★ 位置提示只写进 Status（Label，不可复制），时间码单独写进
    --   StatusTC（只读 LineEdit，可复制），两者互不干扰。
    --   「播放头」三个字已按需求去掉。
    -- ★ 「（第 N 行）」已按需求去掉：行号和"第几处"重复，
    --   而且同一个词在一条字幕里可能出现多次，报行号反而容易误导。
    self:Status(string.format("第 %d / %d 处", idx, App.S.matchTotal))
    if b and self:JumpPlayhead(b.s) then
        -- 显示时间码而不是秒数：用户看的是时间线上的位置，
        -- "0.2s" 没法和时间线刻度对上，"00:00:00:14" 才对得上。
        -- 拿不到帧率时降级成秒，不至于什么都不显示。
        local tc = self:SecToTimecode(b.s)
        self:StatusTimecode(tc or string.format("%.1fs", b.s or 0))
    else
        self:StatusTimecode("")
    end
end

-- 替换（all=true 为全部替换，否则只替换当前选中行）
function App:ReplaceInSubs(all)
    local kw, rp = "", ""
    pcall(function()
        kw = tostring(App.S.items.FindInput.Text or "")
        rp = tostring(App.S.items.ReplaceInput.Text or "")
    end)
    if kw == "" then
        self:Status("请先输入查找内容")
        return
    end
    local n = #App.S.subs
    if n == 0 then return end

    local targets
    if all then
        targets = {}
        for i = 1, n do targets[i] = i end
    else
        if not App.S.selRow then
            self:Status("先点一行或「查找下一个」")
            return
        end
        targets = { App.S.selRow }
    end

    local cnt = 0
    local pat = patternEscape(kw)
    local repl = rp:gsub("%%", "%%%%")   -- 替换串里的 % 也要转义
    for _, i in ipairs(targets) do
        local t = tostring(App.S.subs[i].t or "")
        if t:find(kw, 1, true) then
            App.S.subs[i].t = t:gsub(pat, repl)
            cnt = cnt + 1
        end
    end
    if cnt == 0 then
        self:Status("没有可替换的内容")
        return
    end
    self:FillSubTree(App.S.subs)
    self:SaveSubs(true)
    self:Status(string.format("已替换 %d 处并保存", cnt))
    self:Log(string.format("替换 %d 处：%s → %s", cnt, kw, rp))
    -- 单行替换：播放头跟着跳到这一行（全部替换跳的地方太多，不跳）
    if not all and App.S.selRow then
        local b = App.S.subs[App.S.selRow]
        if b then
            local ok = pcall(function() return self:JumpPlayhead(b.s) end)
            if ok then
                self:StatusTimecode(self:SecToTimecode(b.s) or "")
            end
        end
    end
end

-- 从媒体池里找一个 .srt 载入编辑区
-- 扫描媒体池里【所有】的 .srt（递归子文件夹，最多 6 层）
function App:CollectPoolSrts()
    local out = {}
    pcall(function()
        local mp = App.project and App.project:GetMediaPool() or nil
        if not mp then return end
        local root = mp:GetRootFolder()
        if not root then return end
        local function walk(folder, depth)
            if depth > 6 then return end
            for _, c in ipairs(folder:GetClipList() or {}) do
                local p = tostring(c:GetClipProperty("File Path") or "")
                if p:lower():sub(-4) == ".srt" then
                    out[#out + 1] = p
                end
            end
            for _, sf in ipairs(folder:GetSubFolderList() or {}) do
                walk(sf, depth + 1)
            end
        end
        walk(root, 0)
    end)
    -- 同一份字幕可能在媒体池里被引用多次，去重（路径比较不分大小写）
    local seen, uniq = {}, {}
    for _, p in ipairs(out) do
        local k = p:lower()
        if not seen[k] then seen[k] = true; uniq[#uniq + 1] = p end
    end
    return uniq
end

function App:LoadFromMediaPool()
    local list = self:CollectPoolSrts()
    if #list == 0 then
        self:Status("媒体池无 SRT")
        self:Log("媒体池里没找到 .srt 字幕文件。先生成字幕，或手动把 srt 导入媒体池。")
        return
    end
    if #list == 1 then
        -- 只有一个，没有歧义，直接载入
        App.S.srt = list[1]
        self:Log("从媒体池载入字幕：" .. list[1])
        self:LoadSubs()
        return
    end
    -- ★ 有多个：不猜、不按时间线名默认，弹出来让你自己挑
    self:ShowSrtPicker(list)
end

-- 媒体池里有多个 .srt 时的选择窗
function App:ShowSrtPicker(list)
    local d = App.S.dispatcher
    local ui = App.S.ui
    if not d or not ui then
        App.S.srt = list[1]
        self:Log("错误：弹不出选择窗，改用第一个：" .. list[1])
        self:LoadSubs()
        return
    end
    if App.S.pickerWin then
        pcall(function() App.S.pickerWin:Hide() end)
        App.S.pickerWin = nil
    end

    local w = d:AddWindow({
        ID = "QwenASRPicker",
        WindowTitle = "选择字幕",
        Geometry = { 380, 220, 640, 160 },
    }, ui:VGroup{ ID = "PickRoot", Spacing = 8,
        ui:Label{ ID = "PickLabel",
                  Text = string.format("媒体池里找到 %d 个字幕，请选择要载入的：", #list),
                  Weight = 0 },
        ui:ComboBox{ ID = "PickCombo", Weight = 0 },
        ui:HGroup{ ID = "PickRow", Weight = 0,
            ui:Button{ ID = "PickOk", Text = "载入", Weight = 0.5 },
            ui:Button{ ID = "PickCancel", Text = "取消", Weight = 0.5 },
        },
    })
    if not w then
        App.S.srt = list[1]
        self:Log("错误：选择窗创建失败，改用第一个：" .. list[1])
        self:LoadSubs()
        return
    end

    local it = w:GetItems()
    App.S.pickerList = list
    if it and it.PickCombo then
        for _, p in ipairs(list) do
            -- 完整路径太长会把下拉框撑爆，只显示文件名；
            -- 遇到同名文件再补上所在文件夹，免得分不清是哪一份
            local name = p:match("([^\\/]+)$") or p
            local parent = p:match("([^\\/]+)[\\/][^\\/]+$")
            if parent then name = name .. "　·　" .. parent end
            it.PickCombo:AddItem(name)
        end
        pcall(function() it.PickCombo.CurrentIndex = 0 end)
    end

    w.On.PickOk.Clicked = function()
        local idx = 0
        pcall(function() idx = tonumber(it.PickCombo.CurrentIndex) or 0 end)
        local picked = App.S.pickerList[idx + 1] or App.S.pickerList[1]
        w:Hide()
        if picked then
            App.S.srt = picked
            self:Log("从媒体池载入字幕：" .. picked)
            self:LoadSubs()
        end
    end
    w.On.PickCancel.Clicked = function() w:Hide() end
    -- ★ 右上角 × 走的也是窗口 Close 事件，不绑就点了没反应
    w.On["QwenASRPicker"].Close = function() w:Hide() end

    App.S.pickerWin = w
    w:Show()
end

-- ══════════════════════════════════════════════════════════════════
-- 导出：把 srt / txt 复制到用户选的文件夹
--   选文件夹用 Fusion 自带的 RequestDir（不走 os.execute，不闪窗）；
--   真正的复制交给 Python —— 目标路径可能含中文，Lua 打不开。
-- ══════════════════════════════════════════════════════════════════
function App:PickDir()
    local dir = ""
    pcall(function()
        local fu = App.resolve and App.resolve:Fusion() or nil
        if not fu then return end
        if type(fu.RequestDir) ~= "function" then return end
        local d = fu:RequestDir(TOOL_ROOT .. "\\字幕输出")
        if type(d) == "string" and d ~= "" then dir = d end
    end)
    return dir
end

function App:StartExport(kinds)
    if BUSY_PHASES[App.S.phase] then
        self:Status("任务进行中，请稍候")
        self:Log("当前任务还没结束，等它跑完再导出。")
        return
    end
    if #App.S.subs == 0 then
        self:Log("还没有字幕可导出。先点「开始生成字幕」，或用「读取媒体池字幕」载入一份。")
        return
    end

    -- ★ 导出前先按【当前】字幕把文稿重新生成一遍。识别时那份 txt 是旧稿，
    --   不重生成的话导出去的就不是你改过的版本。
    --   放在选文件夹【之前】启动：用户挑文件夹那几秒足够它跑完；
    --   这一步只写 .txt，不会动 SRT。
    self:SyncTxt()
    if not App.S.txt or App.S.txt == "" then
        self:Log("错误：拿不到文稿路径，导出取消。")
        return
    end

    local dir = self:PickDir()
    if dir == "" then
        self:Log("未选择文件夹，导出取消。")
        return
    end

    pcall(function() os.remove(App.S.exportFile) end)
    local f = io.open(App.S.exportCfg, "wb")
    if not f then
        self:Log("错误：无法写入导出参数"); return
    end
    f:write("{\n")
    f:write('  "srt": ' .. jstr(App.S.srt) .. ",\n")
    f:write('  "txt": ' .. jstr(App.S.txt or "") .. ",\n")
    f:write('  "dir": ' .. jstr(dir) .. ",\n")
    f:write('  "kinds": [')
    for i, k in ipairs(kinds) do
        if i > 1 then f:write(", ") end
        f:write(jstr(k))
    end
    f:write("],\n")
    f:write('  "open": true,\n')
    f:write('  "out_lua": ' .. jstr(App.S.exportFile) .. "\n")
    f:write("}\n")
    f:close()

    if not self:RunTask(EXPORT_SCRIPT, App.S.exportCfg) then
        -- ★ worker 拒绝时导出根本没起来，直接报错，别进 exporting 干等超时。
        self:Fail("导出任务未能启动（worker 拒绝或不可用）")
        return
    end
    App.S.phase = "exporting"
    App.S.exportStartedAt = os.time()
    self:Status("正在导出…")
    self:Log("导出到：" .. dir)
end

function App:Fail(msg)
    App.S.phase = "error"
    self:Status("失败：" .. tostring(msg))
    self:Log("错误：" .. tostring(msg))
    self:EnableButtons()
end

function App:EnableButtons()
    if App.S.win then
        pcall(function() App.S.items.StartBtn.Enabled = true end)
        pcall(function() App.S.items.StopBtn.Enabled = false end)
        -- 「适配字幕」「导出文稿」「更新字幕」：表格里得真有字幕才让点。
        -- ★ 判据用【表格里的字幕条数】而不是识别计数 —— 字幕也可能是
        --   用「读取媒体池字幕」载入的，那种情况下 count 是 0，
        --   按老写法按钮会一直灰着点不动。
        pcall(function() App.S.items.LandBtn.Enabled = self:CanLand() end)
        -- 导出文稿不再依赖识别时留下的那份 txt 路径：导出前会按当前字幕
        -- 重新生成（App:SyncTxt），所以只要表格里有内容就能导出。
        pcall(function() App.S.items.TxtBtn.Enabled = (#App.S.subs > 0) end)
        pcall(function() App.S.items.UpdateSubsBtn.Enabled = (#App.S.subs > 0) end)
    end
end

function App:Cleanup()
    if App.S.jobId then
        pcall(function() App.project:DeleteRenderJob(App.S.jobId) end)
        App.S.jobId = nil
    end
    self:ReturnToPrevPage()
    pcall(function() App.S.audioPath = nil end)
    -- ★ 无条件 kill：除了正在跑的识别任务，预热的常驻 ASR 服务也是
    --   worker 的子进程 —— 关窗口时必须一起收掉，否则它会一直占着显存。
    --   没有子进程时这是一条空操作，代价可以忽略。
    self:KillTasks()
    pcall(function() os.remove(App.S.landFile) end)
    pcall(function() os.remove(App.S.landCfg) end)
    pcall(function() os.remove(App.S.importFile) end)
    pcall(function() os.remove(App.S.importCfg) end)
    pcall(function() os.remove(App.S.exportFile) end)
    pcall(function() os.remove(App.S.exportCfg) end)
    App.S.phase = "idle"
    self:EnableButtons()
end

-- ── 入口 ──────────────────────────────────────────────────────────
if resolve == nil and type(Resolve) == "function" then
    resolve = Resolve()
end
App.OnRun()
