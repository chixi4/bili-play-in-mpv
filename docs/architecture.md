# 架构与能力说明

## 目标

项目目标是让 mpv 在 B 站直播和点播里稳定显示弹幕，并把安装、调用和排障流程做成可重复使用的工具链。

## 核心分层

1. 弹幕引擎层：`src/mpv-scripts/bili_live_danmaku.lua`。
2. 配置层：`src/config/bili_live_danmaku.conf`。
3. 交互层：`src/config/input.conf.template` 和 `src/config/uosc.conf`。
4. 启动层：`src/launcher/mpvplay-launch.ps1` 和 `src/launcher/mpvplay-launch.cmd`。
5. 交付层：`scripts/install.ps1` 与 `scripts/uninstall.ps1`。

## 数据链路

### 直播

1. 识别直播间短号。
2. 调用房间解析接口得到真实房间号。
3. 轮询直播弹幕历史接口。
4. 去重后进入渲染队列。

### 点播

1. 识别 BV 号与分 P。
2. 通过分页接口解析 CID。
3. 下载 `comment.bilibili.com/{cid}.xml`。
4. 按时间轴发射并进入渲染队列。

## 渲染链路

1. 使用 `ass-events` 叠加层绘制。
2. 渲染循环固定 120Hz。
3. 采用实时位置插值计算每帧坐标。
4. 默认使用 `simple_spawn_mode=yes`，优先稳定和可预期。
5. 点播默认关闭预填充 `video_prefill_enabled=no`。

## 交互链路

1. 键盘侧通过 `script-message` 控制开关、速度和字号。
2. uosc 侧通过 `show_danmaku@bili_live_danmaku` 调同一条控制链。
3. 键盘和按钮状态通过脚本内部同步逻辑保持一致。

## 可观测性

1. 支持周期性能窗口日志。
2. 支持协议启动日志。
3. 支持弹幕渲染耗时、队列和拥塞相关指标输出。
