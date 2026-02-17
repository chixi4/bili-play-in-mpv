# Changelog

## 2026-02-17

### Added

- 初始化项目目录，归档当前可用脚本和配置。
- 增加 `install.ps1` 和 `uninstall.ps1`。
- 增加 `mpvplay://` 协议注册与恢复逻辑。
- 增加书签后台触发脚本模板，避免当前页面白屏。
- 增加快速开始与排障文档。

### Changed

- 同步仓库脚本到当前实测版本，更新 `src/mpv-scripts/bili_live_danmaku.lua`。
- 同步默认配置为当前状态，新增 `opacity`、`simple_spawn_mode`、`video_prefill_enabled`，默认字号改为 `72`。
- 字号运行时调节上限从 `72` 扩展到 `144`。
- 默认关闭点播预填充，保持实时时间轴发射策略。
- 修正项目名称拼写为 `bili-play`，并更新安装清单文件名。
- 卸载脚本增加旧清单名兼容读取。
- 更新 README 与架构、排障文档，使说明与当前默认行为一致。

### Notes

- 本版本以现网可用配置为基线，重点保留弹幕滚动优化结果。
