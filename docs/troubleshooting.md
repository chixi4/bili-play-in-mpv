# Troubleshooting

## 1. 点击书签后页面白屏

原因是书签直接把当前标签页跳到 `mpvplay://`。

处理方式是改用后台触发版书签，脚本见 `docs/quickstart.md` 和 `src/bookmarklet/open-in-mpv.js.txt`。

## 2. 点击协议后终端闪一下就没了

先检查注册表打开命令是否直连 PowerShell 脚本，而不是走 `.cmd` 中转。

```powershell
Get-ItemProperty -Path 'HKCU:\Software\Classes\mpvplay\shell\open\command' -Name '(default)'
```

如果不一致，重新执行安装脚本。

```powershell
.\scripts\install.ps1
```

## 3. 前几秒看不到弹幕

点播弹幕是按时间轴加载，开场会做预填充和轨道排布。如果需要进一步调优，检查下面参数。

1. `video_prefill_startup_advance`
2. `video_prefill_min_progress`
3. `video_emit_batch`

文件路径是 `src/config/bili_live_danmaku.conf`。

## 4. UI 按钮和 Ctrl+d 不一致

确认 `uosc.conf` 的 controls 包含 `show_danmaku@bili_live_danmaku` 入口。

文件路径是 `src/config/uosc.conf`。

## 5. 如何看调试日志

协议启动日志默认在本机临时目录。

`%TEMP%\mpvplay_debug.log`

弹幕性能日志在 mpv 配置目录。

`%APPDATA%\mpv\bili_live_danmaku_perf.log`
