# Quick Start

## 1. 环境前提

1. Windows 11。
2. 已安装 mpv。
3. PowerShell 可用。
4. 如果你需要受限清晰度或登录态，Firefox 中已登录 B 站。

## 2. 安装

在 PowerShell 进入项目目录后执行。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install.ps1
```

如果你只想先看动作，不真正写入系统，可以先干运行。

```powershell
.\scripts\install.ps1 -DryRun
```

## 3. 启动方式

### 命令行直接打开

```powershell
mpv "https://www.bilibili.com/video/BVxxxxx/"
mpv BVxxxxx
mpv "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

### 协议方式打开

```powershell
start "mpvplay://https%3A%2F%2Fwww.bilibili.com%2Fvideo%2FBVxxxxx%2F"
start "mpvplay://https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"
start "mpvplay://dQw4w9WgXcQ"
```

### 浏览器书签方式打开

把下面这一整行作为书签地址。

```text
javascript:(function(){var f=document.createElement('iframe');f.style.display='none';f.src='mpvplay://'+encodeURIComponent(location.href);(document.body||document.documentElement).appendChild(f);setTimeout(function(){try{f.remove();}catch(e){}},1200);})();
```

这个写法是后台触发协议，不会把当前标签页切成白屏。

## 4. 功能验证

1. 打开任意 B 站视频后，确认弹幕能正常出现。
2. 按 `Ctrl+d` 看弹幕开关是否生效。
3. 点击 uosc 的弹幕按钮，看状态是否和 `Ctrl+d` 一致。
4. 按 `Ctrl+Alt+j` 和 `Ctrl+Alt+k` 调整速度。
5. 按 `Ctrl+Alt+u` 和 `Ctrl+Alt+i` 调整字号。
6. YouTube 链接能正常打开并播放，且不影响 B 站弹幕开关。
