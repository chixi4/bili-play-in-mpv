# bilil-play-in-mpv

在 mpv 里看 B 站视频和直播，同时显示弹幕。

支持**直播弹幕**和**点播弹幕**两种模式，内置轨道调度、碰撞检测、拥塞控制和预填充等弹幕渲染优化，并提供 `mpvplay://` 浏览器协议一键唤起。

---

## 功能一览

| 能力 | 说明 |
|---|---|
| 🔴 直播弹幕 | 轮询 B 站直播历史弹幕 API，实时滚动显示 |
| 📺 点播弹幕 | 自动解析 BV 号，按视频时间轴同步渲染全量弹幕 |
| 🔗 协议唤起 | 注册 `mpvplay://` URL 协议，从浏览器一键打开 mpv 播放 |
| 🔖 浏览器书签 | 提供 bookmarklet 书签脚本，后台触发不白屏 |
| ⌨️ 快捷键 | `Ctrl+D` 开关弹幕，支持速度和字号调节 |
| 🎛️ uosc 集成 | 控制栏弹幕按钮与键盘快捷键联动 |
| 📊 性能诊断 | 渲染耗时、拉取延迟、轨道调度等全链路性能日志 |
| 📦 安装卸载 | 一键安装/卸载脚本，自动备份、支持 DryRun |

---

## 环境要求

- **Windows 11**（或 Windows 10）
- **mpv** 已安装（默认路径 `C:\Program Files\mpv-x86_64-v3-20260122-git-6e54aa3`，可自定义）
- **PowerShell** 可用
- **curl** 可用（Windows 10+ 自带）
- （可选）Firefox/Chrome 已登录 B 站，用于受限清晰度或需要 Cookie 的场景

---

## 快速开始

### 1. 安装

在 PowerShell 中进入项目目录，执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install.ps1
```

> [!TIP]
> 先用 DryRun 模式预览安装动作（不实际写入）：
> ```powershell
> .\scripts\install.ps1 -DryRun
> ```

安装脚本会自动完成以下操作：

1. 复制弹幕脚本 `bili_live_danmaku.lua` 到 mpv 的 `scripts/` 目录
2. 复制配置文件到 mpv 的 `script-opts/` 目录
3. 复制协议启动器到 mpv 的 `tools/` 目录
4. 在 `input.conf` 中追加弹幕快捷键绑定（已有则跳过）
5. 在 Windows 注册表注册 `mpvplay://` URL 协议
6. 生成安装清单 `bilil-play-install-manifest.tsv`，供卸载时还原

可选参数：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-TargetMpvRoot` | `%APPDATA%\mpv` | mpv 配置目录 |
| `-MpvInstallRoot` | `C:\Program Files\mpv-x86_64-v3-...` | mpv 安装目录 |
| `-DryRun` | - | 只输出动作，不实际执行 |

### 2. 卸载

```powershell
.\scripts\uninstall.ps1
```

卸载脚本会根据安装清单自动还原备份文件、删除已安装文件、清理注册表协议。同样支持 `-DryRun`。

---

## 使用方式

### 方式一：命令行直接打开

```powershell
# 打开 B 站视频（完整链接）
mpv "https://www.bilibili.com/video/BVxxxxx/"

# 打开 B 站视频（BV 号）
mpv BVxxxxx

# 打开 B 站直播
mpv "https://live.bilibili.com/233"
```

### 方式二：`mpvplay://` 协议唤起

```powershell
start "mpvplay://https%3A%2F%2Fwww.bilibili.com%2Fvideo%2FBVxxxxx%2F"
```

协议启动器支持以下输入格式：
- 完整 B 站视频/直播 URL（需 URL 编码）
- 裸 BV 号（如 `mpvplay://BVxxxxx`）
- `b23.tv` 短链
- 自动处理单层和双层 URL 编码

### 方式三：浏览器书签一键唤起

在浏览器中新建书签，将以下代码作为书签地址：

```
javascript:(function(){var u='mpvplay://'+encodeURIComponent(location.href);var f=document.createElement('iframe');f.style.display='none';f.src=u;(document.body||document.documentElement).appendChild(f);setTimeout(function(){try{f.remove();}catch(e){}},1500);})();
```

浏览任意 B 站视频或直播页面时，点击该书签即可唤起 mpv 播放。

> [!NOTE]
> 这个书签使用隐藏 `<iframe>` 后台触发协议，**不会**导致当前标签页白屏。

---

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `Ctrl+D` | 弹幕开关 |
| `Ctrl+Shift+D` | 重新连接/重载弹幕 |
| `Ctrl+Alt+J` | 弹幕减速（飞行时间 +1s） |
| `Ctrl+Alt+K` | 弹幕加速（飞行时间 -1s） |
| `Ctrl+Alt+U` | 弹幕字号缩小（-2） |
| `Ctrl+Alt+I` | 弹幕字号放大（+2） |

uosc 控制栏上也有弹幕开关按钮，与 `Ctrl+D` 状态联动。

---

## 弹幕引擎详解

### 双模式弹幕源

#### 直播模式

当 mpv 打开的链接匹配 `live.bilibili.com` 时自动进入直播模式：

1. 通过 `room_init` API 解析短号为真实房间号
2. 按 `poll_interval`（默认 1 秒）轮询 `gethistory` 接口获取最新弹幕
3. 通过 `id_str` 去重，避免重复弹幕

#### 点播模式

当 mpv 打开的链接包含 BV 号时自动进入点播模式：

1. 通过 `pagelist` API 解析 BV 号 + 分 P 得到 CID
2. 下载 `comment.bilibili.com/{cid}.xml` 全量弹幕 XML
3. 解析并按时间排序存储，在渲染循环中按视频时间戳同步发射

### 渲染系统

弹幕使用 mpv 的 `ass-events` 叠加层渲染，120Hz 定时器驱动，具备以下特性：

- **多轨道布局**：根据屏幕高度和 `area_ratio` 动态计算可用轨道数
- **碰撞检测**：计算新弹幕与同轨道尾部弹幕的最小间距，确保不重叠
- **轨道选择策略**：
  - 优先使用顶部轨道（`top_lane_bias` 控制偏好强度）
  - 低负载时限制使用顶部区域（`top_stack_ratio`），高负载时逐步放开底部轨道
  - 同轨道短时间复用有惩罚（`lane_balance_penalty`），避免弹幕扎堆
- **动态安全间距**：屏幕越拥挤，弹幕之间的最小间距越小（平滑曲线）
- **窗口大小自适应**：OSD 分辨率变化时自动重映射所有在屏弹幕位置

### 点播增强

| 特性 | 说明 |
|---|---|
| Seek 检测 | 进度条拖动超过阈值（默认 0.7s）后自动清空并重建弹幕 |
| 预填充 | 开场时将历史弹幕按时间均匀铺到轨道上，消除前几秒空窗 |
| 游标对齐 | 预填充后自动对齐发射游标，避免重复发射历史弹幕 |
| 发射预算 | 每帧从弹幕序列取出有上限（`video_emit_batch`），避免瞬时过载 |
| 自适应追赶 | 脚本落后视频时间时自动提高每帧上限（`video_emit_lag_boost`） |
| 重试队列 | 因轨道拥塞被丢弃的弹幕进入重试队列，在窗口期内多次尝试 |
| 开场暂停 | 可选在弹幕加载完成前暂停播放，加载完自动继续 |

### 拥塞控制

| 参数 | 说明 |
|---|---|
| `merge_tolerance` | > 0 时合并时间窗口内的相同文案弹幕 |
| `max_screen_danmaku` | > 0 时限制同时在屏的最大弹幕数 |
| `video_retry_window` | 被拥塞丢弃的弹幕在此窗口内可重试 |
| `video_retry_max` | 重试队列最大容量 |

---

## 配置参考

配置文件位于 `src/config/bili_live_danmaku.conf`，安装后复制到 `%APPDATA%\mpv\script-opts\bili_live_danmaku.conf`。

### 基础参数

| 参数 | 默认值 | 范围 | 说明 |
|---|---|---|---|
| `enabled` | `yes` | yes/no | 启动时是否默认开启弹幕 |
| `show_user` | `no` | yes/no | 是否在弹幕前显示用户名 |
| `force_room_id` | （空） | 数字 | 强制指定直播房间号 |
| `poll_interval` | `1.0` | 秒 | 直播弹幕轮询间隔 |

### 样式参数

| 参数 | 默认值 | 范围 | 说明 |
|---|---|---|---|
| `font_size` | `34` | 18–72 | 弹幕字号 |
| `duration` | `14.0` | 4–30 秒 | 弹幕飞行时间（越大越慢） |
| `max_lines` | `14` | ≥1 | 最大轨道数 |
| `area_ratio` | `0.45` | 0–1 | 弹幕区域占屏幕高度的比例 |
| `horizontal_span_ratio` | `0.90` | 0.12–1.0 | 水平轨道宽度比例（1.0 为全屏宽） |
| `margin_top` | `24` | px | 顶部边距 |
| `line_gap` | `8` | px | 轨道间距 |
| `item_margin` | `16` | px | 弹幕之间的最小安全间距 |

### 轨道调度参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `top_stack_ratio` | `0.24` | 低负载时使用的顶部轨道比例（越小越集中在上方） |
| `top_lane_bias` | `8.0` | 顶部轨道优先权重（越大越优先高位轨道） |

### 点播参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `video_seek_reset_threshold` | `0.70` | Seek 触发弹幕重建的阈值（秒） |
| `video_prefill_extra` | `1.20` | 预填充回溯额外时间 |
| `video_prefill_max` | `260` | 预填充最大弹幕数 |
| `video_prefill_min_elapsed` | `0.80` | 预填充弹幕最小已显示时长 |
| `video_prefill_startup_advance` | `1.60` | 开场预填充提前量 |
| `video_prefill_min_progress` | `0.50` | 预填充最小推进比例 |
| `video_emit_batch` | `56` | 每帧发射上限 |
| `video_emit_batch_max` | `220` | 自适应追赶时的最大每帧上限 |
| `video_emit_lag_step` | `0.08` | 追赶步长 |
| `video_emit_lag_boost` | `18` | 每个步长追加的发射数 |
| `video_retry_window` | `4.5` | 重试队列时间窗（秒） |
| `video_retry_max` | `600` | 重试队列最大容量 |
| `video_retry_batch` | `180` | 每帧重试扫描总上限 |
| `video_retry_tick_batch` | `56` | 每帧重试扫描基数 |
| `video_retry_step` | `0.05` | 重试间隔（秒） |
| `video_startup_hold` | `no` | 是否开场暂停等弹幕 |
| `video_startup_hold_timeout` | `4.0` | 开场暂停超时（秒） |

### 性能日志参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `perf_log` | `yes` | 是否开启性能日志 |
| `perf_log_interval` | `5.0` | 性能报告间隔（秒） |
| `perf_slow_ms` | `8.0` | 慢渲染阈值（毫秒） |
| `perf_log_to_file` | `yes` | 是否输出到文件 |

---

## 脚本消息接口

可在 mpv 中通过 `script-message` 调用：

```
bili-live-danmaku-toggle           # 弹幕开/关
bili-live-danmaku-restart          # 重新连接
bili-live-danmaku-use-room <房间号>  # 切换直播房间
bili-live-danmaku-slower           # 减速
bili-live-danmaku-faster           # 加速
bili-live-danmaku-smaller          # 缩小字号
bili-live-danmaku-larger           # 放大字号
show_danmaku <on|off|toggle>       # 设置弹幕状态（兼容 uosc）
```

---

## 项目结构

```
bilil-play-in-mpv/
├── src/
│   ├── mpv-scripts/
│   │   └── bili_live_danmaku.lua     # 弹幕引擎核心（2000+ 行）
│   ├── config/
│   │   ├── bili_live_danmaku.conf    # 弹幕参数配置
│   │   ├── input.conf.template       # 快捷键绑定模板
│   │   └── uosc.conf                 # uosc 控制栏配置
│   ├── launcher/
│   │   ├── mpvplay-launch.ps1        # 协议启动器（PowerShell）
│   │   └── mpvplay-launch.cmd        # cmd 中转脚本
│   └── bookmarklet/
│       └── open-in-mpv.js.txt        # 浏览器书签脚本
├── scripts/
│   ├── install.ps1                    # 安装脚本
│   └── uninstall.ps1                  # 卸载脚本
├── docs/
│   ├── quickstart.md                  # 快速开始
│   ├── architecture.md                # 架构说明
│   └── troubleshooting.md             # 故障排查
└── runtime/
    └── logs/                          # 运行日志目录（不提交）
```

---

## 故障排查

### 点击书签后页面白屏

使用项目提供的后台触发版书签（通过隐藏 `<iframe>` 触发协议），不要直接用 `location.href` 跳转。

### 点击协议后终端闪一下就没了

检查注册表中协议的打开命令是否正确指向 PowerShell 脚本：

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Classes\mpvplay\shell\open\command' -Name '(default)'
```

如果不一致，重新执行 `.\scripts\install.ps1`。

### 前几秒看不到弹幕

点播弹幕有预填充机制，可以调整以下参数增强开场弹幕密度：

- `video_prefill_startup_advance`（提前量，越大越容易看到）
- `video_prefill_min_progress`（最小推进比例）
- `video_emit_batch`（每帧发射上限）

### uosc 按钮和 Ctrl+D 状态不一致

确认 `uosc.conf` 的 `controls` 中包含 `show_danmaku@bili_live_danmaku` 入口。

### 查看调试日志

| 日志类型 | 路径 |
|---|---|
| 协议启动日志 | `%TEMP%\mpvplay_debug.log` |
| 弹幕性能日志 | `%APPDATA%\mpv\bili_live_danmaku_perf.log` |

---

## 许可证

MIT License
