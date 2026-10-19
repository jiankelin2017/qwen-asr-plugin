;══════════════════════════════════════════════════════════════════════════
; Qwen ASR · Inno Setup 安装脚本
;──────────────────────────────────────────────────────────────────────────
; 分工：
;   本安装包（十几 MB）=「铺文件 + Windows 标准外壳」
;     · 把 PyInstaller onedir 产物（安装核心，含内嵌的引擎脚本）
;       解到 {app}\安装核心\
;     · 注册开始菜单 / 桌面快捷方式 / 卸载信息
;     · 装完自动调起「安装核心」—— 那才是真正干活的：
;       下载 Python + torch + 模型（1.8~4.4 GB，在线下载不打进安装包）、
;       部署引擎到 {app}\q3、把 Lua 脚本写进 DaVinci 脚本目录
;
;   {app} 会作为参数传给安装核心，所以位置只问一次（在 Inno 向导里）。
;
; 构建：build.bat（PyInstaller --onedir → ISCC 编译）
;══════════════════════════════════════════════════════════════════════════

#define MyAppName "Qwen ASR"
#define MyAppVersion "1.28"
#define MyAppExeName "安装核心.exe"
#define MyAppPublisher "HEIBA"

; ★ AppId 定下后就不能改 —— 升级覆盖安装和卸载都认它
; （#define 里 { 要写成 {{，展开后才是一个合法的 GUID）
#define MyAppId "{{7A3F9C4E-2B8D-4E6A-9F1C-5D8A2B7E3C46}}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
VersionInfoVersion=1.28.0.0
VersionInfoProductName=Qwen ASR 安装器
VersionInfoDescription=Qwen ASR 一键安装包（运行环境与模型在线下载）
DefaultDirName=C:\HEIBA
DefaultGroupName=Qwen ASR
AllowNoIcons=yes
; 要把 Lua 脚本写进 %ProgramData% 下的 DaVinci 目录（全新机器还要建目录），
; 提权最稳；用户对安装器弹 UAC 也有心理预期
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=Qwen ASR安装器
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Qwen ASR
UninstallDisplayIcon={app}\安装核心\{#MyAppExeName}

[Languages]
; 安装界面用简体中文（Inno 6 自带）
Name: chinesesimplified; MessagesFile: compiler:Languages\ChineseSimplified.isl

[Tasks]
Name: desktopicon; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："

[Files]
; onedir 产物整个铺进去（exe + _internal\，内嵌的 payload 脚本就在里面）
Source: "dist\安装核心\*"; DestDir: "{app}\安装核心"; \
    Flags: recursesubdirs createallsubdirs ignoreversion
; 使用说明也放一份，开始菜单的说明快捷方式立刻有目标
; （安装核心跑完后还会用自己的 payload 覆盖一份，内容相同）
Source: "..\使用说明.txt"; DestDir: "{app}\Qwen字幕工具"; Flags: ignoreversion

[Icons]
Name: "{group}\Qwen ASR 使用说明"; Filename: "{app}\Qwen字幕工具\使用说明.txt"
Name: "{group}\重新运行安装向导"; Filename: "{app}\安装核心\{#MyAppExeName}"; \
    Parameters: """{app}"""
Name: "{group}\卸载 Qwen ASR"; Filename: "{uninstallexe}"
Name: "{commondesktop}\Qwen ASR 使用说明"; Filename: "{app}\Qwen字幕工具\使用说明.txt"; \
    Tasks: desktopicon

[Run]
; 装完自动调起下载向导。{app} 作参数传进去 —— 位置已经选好，不再重问。
; /SILENT 安装时不自动跑（skipifsilent），留给用户手动点开始菜单项。
Filename: "{app}\安装核心\{#MyAppExeName}"; Parameters: """{app}"""; \
    Description: "下载运行环境与模型并完成部署（1.8~4.4 GB，视版本而定）"; \
    Flags: nowait postinstall skipifsilent

[UninstallDelete]
; ── 先删 DaVinci 脚本目录里的副本 ──
; 只删安装核心真的写进去的（按 _deployed.json 清单核对），
; 没部署过 / 清单不在就一个都不碰，防止误删用户自己的东西。
; ★ 必须排在删 {app} 之前 —— 清单就在 {app}\安装核心\ 里，
;   先删 {app} 的话清单没了，这些就都跳过不删了。
Type: filesandordirs; Name: "{commonappdata}\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\Qwen ASR"; Check: NeedDeleteResolveDirPD
Type: filesandordirs; Name: "{userappdata}\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Qwen ASR"; Check: NeedDeleteResolveDirAD
Type: filesandordirs; Name: "{commonpf64}\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\Qwen ASR"; Check: NeedDeleteResolveDirPF
; ── 再删安装目录下本工具创建的子树 ──
; 不整删 {app}：用户可能往 C:\HEIBA 里放过自己的东西，
; 只清本工具创建的目录（下载来的环境和模型都在里面）。
Type: filesandordirs; Name: "{app}\安装核心"
Type: filesandordirs; Name: "{app}\q3"
Type: filesandordirs; Name: "{app}\Qwen ASR"
; ★★ Qwen字幕工具：只删模型，绝不整棵删 ★★
; 这里以前写的是 Type: filesandordirs; Name: "{app}\Qwen字幕工具"
; —— 整棵端掉。但那个目录里除了下载来的模型，还躺着用户跑出来的字幕：
;     {app}\Qwen字幕工具\字幕输出\*.srt / *.txt
; 结果就是：卸载一次，几小时跑出来的字幕全没了（本机实测有 6 个文件）。
; 现在只删 models 子树（下载产物，该删），字幕输出原地保留。
; 另外卸载前还会自动另存一份到文档目录（见 [Code] 里的
; CurUninstallStepChanged），双保险。
; 使用说明.txt 是 [Files] 装进去的，卸载器按安装清单自动清，不用列在这。
Type: filesandordirs; Name: "{app}\Qwen字幕工具\models"
; ── 下载缓存的清理【不在这里做】──
; 缓存堆在 %TEMP%\qwen3asr_dl（Python embed zip + torch wheel + 模型分片）。
; ★ 这里千万不能写 Type: filesandordirs; Name: "{tmp}\qwen3asr_dl"：
;   Inno 的 {tmp} 不是 %TEMP%，而是 Setup/Uninstall 每次运行自己新建的一个
;   临时子目录（形如 %TEMP%\is-XXXXX.tmp），退出时整棵自动清空。
;   指向它 = 空操作 —— 实测卸载日志里连一行删除记录都没有。
; 所以改到 [Code] 里用 GetEnv('TEMP') 定位真实的用户临时目录再删
; （见 DeleteDownloadCache）。安装核心成功后本来也会自己清一次
; （installer.py 的 Installer.clean_cache），这里是兜底。

[Code]
// 文件属性位（Inno 的 Pascal Script 没预定义这两个，自己给个名字）
const
  FA_DIRECTORY = $10;      // FILE_ATTRIBUTE_DIRECTORY
  FA_REPARSE   = $400;     // FILE_ATTRIBUTE_REPARSE_POINT（junction / 符号链接）

// 读安装核心留下的部署清单，确认某个 DaVinci 目录是我们写进去的
// ★ Inno Setup 6.7 的两个签名变化（都踩过，写注释备忘）：
//   · LoadStringFromFile 第二参数是 AnsiString，不是 String
//   · StringChange 改成【原地修改】（var S）+ 返回替换次数，
//     不再是 StringChange(S,...) 返回新串 —— txt := StringChange(...)
//     会报 Type mismatch
function ResolveDirDeployed(const dir: string): Boolean;
var
  man, needle: string;
  raw: AnsiString;
  txt: string;
begin
  Result := False;
  man := ExpandConstant('{app}\安装核心\_deployed.json');
  if not LoadStringFromFile(man, raw) then
    Exit;                            // 向导没跑完 → 什么都没部署
  txt := raw;                        // AnsiString → String 直接赋值
  needle := dir;
  StringChange(txt, '\', '/');       // 清单里存的是正斜杠
  StringChange(needle, '\', '/');
  if Pos(needle, txt) > 0 then
    Result := True;
end;

function NeedDeleteResolveDirPD: Boolean;
begin
  Result := ResolveDirDeployed(ExpandConstant(
    '{commonappdata}\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\Qwen ASR'));
end;

function NeedDeleteResolveDirAD: Boolean;
begin
  Result := ResolveDirDeployed(ExpandConstant(
    '{userappdata}\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Qwen ASR'));
end;

function NeedDeleteResolveDirPF: Boolean;
begin
  Result := ResolveDirDeployed(ExpandConstant(
    '{commonpf64}\Blackmagic Design\DaVinci Resolve\Fusion\Scripts\Utility\Qwen ASR'));
end;

//──────────────────────────────────────────────────────────────────────────
// 卸载：把「字幕输出」另存一份到文档目录（第二道保险）
//──────────────────────────────────────────────────────────────────────────
// 第一道保险在 [UninstallDelete]：已经改成只删 {app}\Qwen字幕工具\models，
// 不再整棵删，所以卸载器本身不会碰用户跑出来的字幕。
//
// 这里再加一道：卸载前把 {app}\Qwen字幕工具\字幕输出 整棵复制到
//   %USERPROFILE%\Documents\Qwen ASR 字幕备份\<时间戳>\
// 为什么还要多此一举？因为 C:\HEIBA 是安装目录 —— 用户哪天手动删它，
// 或者用 Geek 这类工具「强制删除残留」把整个 C:\HEIBA 端掉，原地那份就没了。
// 文档里这份跟安装目录无关，能活下来。
//
// ★ 钩子选 CurUninstallStepChanged(usUninstall)：这个时刻已经在用户点过
//   「确认卸载」之后、真正开始删文件之前。若改用 InitializeUninstall，
//   用户点了取消也会白备份一份，不好。
// ★ 全程 best-effort：备份失败只弹提示，不阻断卸载 —— 反正原地那份没删，
//   丢不了东西。

// 递归复制目录里的文件。
// reparse point（junction / 符号链接）一律跳过、不跟进去 —— 模型目录
// 就是指向 C:\HEIBA\models 的 junction，跟进去会把 3 GB 模型也拷一遍。
// 返回成功复制的文件数；失败数累加进 Failures。
function CopyTreeNoReparse(const src, dst: string; var Failures: Integer): Integer;
var
  fr: TFindRec;
  s, d: string;
begin
  Result := 0;
  if not FindFirst(src + '\*', fr) then
    Exit;
  repeat
    // Win32 的 * 通配会把 . 和 .. 也列出来，要滤掉
    if (fr.Name <> '.') and (fr.Name <> '..') and
       ((fr.Attributes and FA_REPARSE) = 0) then
    begin
      s := src + '\' + fr.Name;
      d := dst + '\' + fr.Name;
      if (fr.Attributes and FA_DIRECTORY) <> 0 then
      begin
        if ForceDirectories(d) then
          Result := Result + CopyTreeNoReparse(s, d, Failures);
      end
      else if CopyFile(s, d, False) then
        Result := Result + 1
      else
        Failures := Failures + 1;
    end;
  until not FindNext(fr);
  FindClose(fr);
end;

// 把「字幕输出」整棵另存到文档目录。
// ★ 单独拆成过程，不要在 CurUninstallStepChanged 里直接写带 Exit 的逻辑 ——
//   卸载钩子里还要做缓存清理，中间 Exit 会把后面的清理一起跳过。
procedure BackupSubtitleOutput;
var
  src, dst: string;
  n, fails: Integer;
begin
  src := ExpandConstant('{app}\Qwen字幕工具\字幕输出');
  if not DirExists(src) then
    Exit;                                  // 从没跑过 → 无产物，直接卸
  dst := ExpandConstant('{userdocs}\Qwen ASR 字幕备份') + '\' +
         GetDateTimeString('yyyymmdd-hhnnss', #0, #0);
  if not ForceDirectories(dst) then
    Exit;                                  // 建不了目标目录就算了，原地那份不删
  fails := 0;
  n := CopyTreeNoReparse(src, dst, fails);
  if n = 0 then
    Exit;                                  // 空目录，没什么可备的
  if fails = 0 then
    // SuppressibleMsgBox：静默卸载（/SILENT）下不弹窗、直接返回默认值，
    // 不会把无人值守的卸载卡住
    SuppressibleMsgBox('卸载前已把字幕备份到：' + #13#10 + dst + #13#10 +
      '（共 ' + IntToStr(n) + ' 个文件）',
      mbInformation, MB_OK, IDOK)
  else
    SuppressibleMsgBox('字幕备份不完整：成功 ' + IntToStr(n) + ' 个，失败 ' +
      IntToStr(fails) + ' 个。' + #13#10 +
      '原始文件仍保留在：' + #13#10 + src,
      mbError, MB_OK, IDOK);
end;

// 清掉安装时下载的缓存目录（%TEMP%\qwen3asr_dl）。
// ★ 为什么不在 [UninstallDelete] 里写 "{tmp}\qwen3asr_dl"：
//   Inno 的 {tmp} 不是 %TEMP%，而是 Setup/Uninstall 每次运行新建的临时子目录
//   （%TEMP%\is-XXXXX.tmp），退出即整棵清空 —— 指向它等于什么都没做。
//   缓存的真实位置由安装核心（installer.py）用 tempfile.gettempdir() 决定，
//   就是用户临时目录，所以这里读 TEMP / TMP 环境变量来定位。
function DeleteDownloadCache: Boolean;
var
  base, p: string;
begin
  base := GetEnv('TEMP');
  if base = '' then
    base := GetEnv('TMP');
  if base = '' then
    base := ExpandConstant('{localappdata}') + '\Temp';   // 兜底
  p := AddBackslash(base) + 'qwen3asr_dl';
  if not DirExists(p) then
  begin
    Log('下载缓存不存在，跳过：' + p);
    Result := True;
    Exit;
  end;
  DelTree(p, True, True, True);
  Result := not DirExists(p);
  if Result then
    Log('已删除下载缓存：' + p)
  else
    Log('下载缓存未能完全删除（可手动删）：' + p);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  // usUninstall = 用户已确认卸载、真正开始删文件之前
  BackupSubtitleOutput;
  DeleteDownloadCache;
end;
