# 架构与能力说明

## 目标范围

脚本目标是让 mpv 在 B 站直播和点播里稳定显示弹幕，同时兼顾实时性、交互和可观测性。

## 当前能力

### 弹幕源接入

1. 直播弹幕接口是 `https://api.live.bilibili.com/xlive/web-room/v1/dM/gethistory`。
2. 点播弹幕流程是 `bvid -> cid -> xml`。
3. 支持直播短号房间，例如 `live.bilibili.com/233`。
4. 支持 `force_room_id` 强制房间号。

### 渲染与调度

1. 使用 `ass-events` 叠加层渲染。
2. 支持轨道间距、复用惩罚、顶部偏置。
3. 顶部堆积当前基线参数是 `top_stack_ratio=0.24` 和 `top_lane_bias=8.0`。
4. 支持拥塞上限和去重时间窗。

### 点播增强

1. 支持 seek 识别和重建。
2. 支持预填充，减少开场空窗。
3. 预填充后会对齐游标，减少历史回扫。

### 交互层

1. 键盘快捷键由 `input.conf` 控制。
2. uosc 控制栏按钮由 `uosc.conf` 控制。
3. 两者都映射到 `show_danmaku` 同一条控制链。

### 诊断层

1. 支持性能窗口日志。
2. 支持会话级运行日志。
3. 支持协议链路调试日志。

## 脚本消息接口

- `bili-live-danmaku-toggle`
- `bili-live-danmaku-restart`
- `bili-live-danmaku-use-room <room_short>`
- `bili-live-danmaku-slower`
- `bili-live-danmaku-faster`
- `bili-live-danmaku-smaller`
- `bili-live-danmaku-larger`
- `show_danmaku <on|off|toggle_on|toggle_off|toggle>`
- `set show_danmaku <...>`

## 产品化分层

1. 内核层是 `src/mpv-scripts/bili_live_danmaku.lua`。
2. 配置层是 `src/config/bili_live_danmaku.conf`。
3. 交互层是 `src/config/input.conf.template` 和 `src/config/uosc.conf`。
4. 启动层是 `src/launcher/mpvplay-launch.ps1`。
5. 交付层是 `scripts/install.ps1` 与文档。
