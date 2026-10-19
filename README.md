# Qwen ASR — DaVinci Resolve 离线语音转字幕插件 (v1.28)

在 DaVinci Resolve 中用 Qwen3-ASR 模型自动生成字幕，音频不上传、全程本地离线运行。

## 工作原理

```
Qwen ASR.lua（Resolve 菜单启动，Fusion UI）
  → timeline_source.py    读取时间线音频源信息
  → AddRenderJob 渲染音频为 WAV（render_to_wav.xml）
  → worker.py             后台常驻执行器
    → asr_server.py       常驻 ASR 服务，模型只加载一次
      → asr_engine.py     Qwen3-ASR 识别 + ForcedAligner 强制对齐
  → subs_io.py            SRT 字幕读写（解决 Lua 读不了中文路径的问题）
  → land_subtitle.py      字幕落轨 + 导入媒体池
  → export_files.py       字幕/文稿按需导出
```

## 目录说明

| 文件 | 用途 |
|---|---|
| `Qwen ASR.lua` | Resolve 集成主脚本（Fusion UI + 全异步流程） |
| `resolve_bridge.py` | Resolve 桥接入口，被 Lua 调用 |
| `timeline_source.py` | 读取 Resolve 时间线的音频源信息（JSON 输出） |
| `worker.py` | 常驻后台执行器，替代 Lua 侧 os.execute |
| `asr_server.py` | 常驻 ASR 服务，模型只加载一次后复用 |
| `asr_engine.py` | ASR 识别引擎（Qwen3-ASR + ForcedAligner） |
| `subs_io.py` | 字幕读写桥 |
| `land_subtitle.py` | 把 SRT 落到 Resolve 字幕轨并导入媒体池 |
| `export_files.py` | 字幕/文稿导出到指定文件夹 |
| `models.lua` / `models.txt` | 模型列表与默认模型名 |
| `render_to_wav.xml` | Resolve 渲染任务配置 |
| `packer/` | 安装器打包体系（build.bat / installer.py / Inno Setup 脚本 / payload） |

## 安装

运行安装器后，插件安装到：

```
C:\ProgramData\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Qwen ASR\
```

`packer/payload/` 中的文件即安装时写入该目录的载荷，与根目录源码一致（打包时以根目录为源同步）。

## 使用

1. 打开 Resolve，进入含音频的时间线
2. 工作区 → 脚本 → Qwen ASR
3. 选择模型后开始识别（详见《使用说明.txt》）

模型可放在 `C:\HEIBA\Qwen字幕工具\models\`（HuggingFace 格式模型文件夹），或在 UI 的「自定义模型路径」中指定外部路径。

> 要求：NVIDIA 显卡。1.7B 模型需要约 8GB 以上显存，8GB 显卡可能跑不动，路径无效时自动退回默认模型。

## 说明

- 识别依赖模型文件（约数 GB，随 HuggingFace 模型下载），不包含在本仓库
- `packer/payload/get-pip.py`（Python 官方引导脚本）与打包产物 exe 不入库
