# bili-play-in-mpv

这个项目把你当前可用的 B 站弹幕方案做成了可安装的工具包，目标是让 mpv 在直播和点播里稳定显示弹幕，同时补齐 YouTube 播放入口，并且保留你已经验证过的流畅度优化。

当前仓库内容与本机生效版本保持一致，包含脚本、配置、协议启动器、安装卸载脚本和文档。

## 现在默认行为

1. 点播和直播都由 `bili_live_danmaku.lua` 接管弹幕显示。
2. 渲染定时器固定为 `120Hz`，并记录性能日志。
3. 弹幕显示使用实时位置插值，默认从画面右侧外进入。
4. 默认启用简单出现模式 `simple_spawn_mode=yes`，优先保证稳定和可预期。
5. 点播预填充默认关闭 `video_prefill_enabled=no`，不再提前塞历史弹幕。
6. 默认字号是 `72`，运行时调节范围是 `18` 到 `144`。
7. `mpvplay://` 协议同时支持 B 站和 YouTube 链接，YouTube 也支持直接给视频 ID。

## 功能清单

1. 支持 B 站直播弹幕拉取和显示。
2. 支持 B 站点播弹幕解析和时间轴同步显示。
3. 支持 `mpvplay://` 协议，从浏览器一键唤起 mpv。
4. 支持浏览器书签后台触发，避免页面白屏。
5. 支持 `uosc` 控制栏弹幕按钮和 `Ctrl+D` 联动。
6. 支持性能日志，便于定位卡顿与拥塞。
7. 支持 YouTube 链接和 `11` 位视频 ID 直开。

## 环境要求

1. Windows 10 或 Windows 11。
2. 已安装 mpv。
3. PowerShell 可用。
4. curl 可用。
5. 可选，Firefox 或 Chrome 已登录 B 站，用于需要登录态的清晰度。
6. 建议安装最新 `yt-dlp`，用于 B 站与 YouTube 链接解析。

## 安装

在 PowerShell 进入项目目录后执行。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install.ps1
```

只预览动作不落盘。

```powershell
.\scripts\install.ps1 -DryRun
```

安装脚本会完成以下动作。

1. 复制弹幕脚本到 `%APPDATA%\mpv\scripts`。
2. 复制配置到 `%APPDATA%\mpv\script-opts`。
3. 复制协议启动器到 `%APPDATA%\mpv\tools`。
4. 追加弹幕快捷键到 `%APPDATA%\mpv\input.conf`。
5. 注册 `mpvplay://` 协议到当前用户注册表。
6. 生成安装清单 `tools\bili-play-install-manifest.tsv`。

## 卸载

```powershell
.\scripts\uninstall.ps1
```

卸载会根据安装清单恢复备份并移除协议注册。脚本兼容读取旧清单名 `bilil-play-install-manifest.tsv`。

## 使用方式

### 命令行直接播放

```powershell
mpv "https://www.bilibili.com/video/BVxxxxx/"
mpv BVxxxxx
mpv "https://live.bilibili.com/233"
mpv "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

### 协议方式播放

```powershell
start "mpvplay://https%3A%2F%2Fwww.bilibili.com%2Fvideo%2FBVxxxxx%2F"
start "mpvplay://https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"
start "mpvplay://dQw4w9WgXcQ"
```

### 浏览器书签播放

把下面这行完整代码作为书签地址。

```text
javascript:(function(){var f=document.createElement('iframe');f.style.display='none';f.src='mpvplay://'+encodeURIComponent(location.href);(document.body||document.documentElement).appendChild(f);setTimeout(function(){try{f.remove();}catch(e){}},1200);})();
```

这个写法是后台触发，不会把当前标签页跳成白屏。

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `Ctrl+D` | 弹幕开关 |
| `Ctrl+Shift+D` | 重载弹幕 |
| `Ctrl+Alt+J` | 弹幕减速 |
| `Ctrl+Alt+K` | 弹幕加速 |
| `Ctrl+Alt+U` | 字号减小 |
| `Ctrl+Alt+I` | 字号增大 |

## 关键配置

配置模板位于 `src/config/bili_live_danmaku.conf`，安装后落到 `%APPDATA%\mpv\script-opts\bili_live_danmaku.conf`。

| 参数 | 默认值 | 说明 |
|---|---|---|
| `font_size` | `72` | 默认字号，运行时范围 18 到 144 |
| `opacity` | `0.80` | 弹幕透明度 |
| `duration` | `14.0` | 弹幕飞行时长，越大越慢 |
| `simple_spawn_mode` | `yes` | 使用稳定的简单出现策略 |
| `horizontal_span_ratio` | `1.00` | 水平轨道宽度比例 |
| `area_ratio` | `0.45` | 弹幕占用高度比例 |
| `video_prefill_enabled` | `no` | 是否启用点播预填充 |
| `video_seek_reset_threshold` | `0.70` | 点播 seek 后触发重建的阈值 |
| `video_emit_batch` | `56` | 点播每帧基础发射上限 |
| `video_emit_batch_max` | `220` | 点播追赶时每帧上限 |
| `video_retry_window` | `4.5` | 拥塞重试时间窗 |
| `video_startup_hold` | `no` | 是否开场暂停等待弹幕 |
| `perf_log` | `yes` | 是否输出性能日志 |

## 脚本消息

```text
bili-live-danmaku-toggle
bili-live-danmaku-restart
bili-live-danmaku-use-room <room_short>
bili-live-danmaku-slower
bili-live-danmaku-faster
bili-live-danmaku-smaller
bili-live-danmaku-larger
show_danmaku <on|off|toggle>
```

## 日志路径

| 日志类型 | 路径 |
|---|---|
| 协议启动日志 | `%TEMP%\mpvplay_debug.log` |
| 弹幕性能日志 | `%APPDATA%\mpv\bili_live_danmaku_perf.log` |

## 项目结构

```text
bili-play-in-mpv/
├── src/
│   ├── mpv-scripts/
│   │   └── bili_live_danmaku.lua
│   ├── config/
│   │   ├── bili_live_danmaku.conf
│   │   ├── input.conf.template
│   │   └── uosc.conf
│   ├── launcher/
│   │   ├── mpvplay-launch.ps1
│   │   └── mpvplay-launch.cmd
│   └── bookmarklet/
│       └── open-in-mpv.js.txt
├── scripts/
│   ├── install.ps1
│   └── uninstall.ps1
├── docs/
│   ├── quickstart.md
│   ├── architecture.md
│   └── troubleshooting.md
└── runtime/
    └── logs/
```

## 许可证

MIT
