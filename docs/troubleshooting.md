# Troubleshooting

## 1. 点击书签后页面白屏

原因通常是书签直接把当前页面跳到 `mpvplay://`。

处理方式是使用项目提供的后台触发书签，脚本在 `src/bookmarklet/open-in-mpv.js.txt`。

## 2. 点击协议后终端闪一下就退出

先检查协议打开命令是否正确指向 `mpvplay-launch.ps1`。

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Classes\mpvplay\shell\open\command' -Name '(default)'
```

如果路径不一致，重新执行安装脚本。

```powershell
.\scripts\install.ps1
```

## 3. 点播开始后几秒才看到弹幕

当前默认关闭了预填充 `video_prefill_enabled=no`，第一批弹幕会按时间轴实时进入，不会提前铺满。

如果你需要开场更快看到更多弹幕，可以在配置里打开预填充并调以下参数。

1. `video_prefill_enabled=yes`
2. `video_prefill_startup_advance`
3. `video_emit_batch`

配置路径是 `src/config/bili_live_danmaku.conf`。

## 4. uosc 按钮和 Ctrl+D 状态不一致

确认 `src/config/uosc.conf` 的 `controls` 中保留 `show_danmaku@bili_live_danmaku`。

## 5. 字号调节范围不符合预期

当前脚本范围是 `18` 到 `144`，默认值由 `font_size` 控制。快捷键是 `Ctrl+Alt+U` 和 `Ctrl+Alt+I`。

## 6. 性能日志查看位置

1. 协议启动日志在 `%TEMP%\mpvplay_debug.log`。
2. 弹幕性能日志在 `%APPDATA%\mpv\bili_live_danmaku_perf.log`。
