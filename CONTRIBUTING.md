# 参与贡献

欢迎提交问题、文档改进与代码贡献。提交前请搜索已有 Issue / PR；较大的功能或交互调整请先用 Issue 说明使用场景与范围。

## 本地开发

需要 Apple Silicon Mac、macOS 14 或更新系统、Xcode Command Line Tools（`xcode-select --install`）及 zsh。离线 HTML 检查还需要 Node.js 22；应用构建本身没有第三方代码依赖。

从最新 `main` 创建独立开发分支，在仓库根目录运行：

```sh
./scripts/build.sh
./scripts/check-interactive-demo.sh
```

构建输出为 `dist/XShot.app`。构建采用本机临时签名，不包含 Developer ID 签名或公证。检查以合成图片和 Node.js 的 DOM 替身验证离线 HTML 导出、转义、导航与热点逻辑，不启动应用窗口或浏览器，也不采集屏幕。

根据改动补跑相关的 `scripts/check-*.sh`；各脚本的用途见 [README](README.md#验证)。部分 AppKit 检查依赖图形登录会话、隐藏窗口或系统服务，`check-demo-studio.sh` 还需要先运行 `check-demo-video.sh`。真实截图、录屏权限、多屏行为与视觉效果需要在本机手动验证，不能由离线检查代替。请参阅 [VERIFICATION.md](VERIFICATION.md)。

## CI 与复现

GitHub Actions 在 push 与 PR 时使用 `macos-15` ARM runner，运行上述构建与离线检查，并显式安装 Node.js 22。参见 [GitHub runner 说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。私有库需要启用 Actions 并有可用计算额度。若托管 runner 不可用，在上述本机环境运行相同命令并附上结果；不要将不可信 PR 自动转给个人 self-hosted runner。

受限环境中若编译器无法写入用户级缓存，可将缓存设到仓库的忽略目录后重试：

```sh
mkdir -p .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
./scripts/build.sh
./scripts/check-interactive-demo.sh
```

## 提交与 PR

- 保持改动聚焦，沿用现有 Swift 风格；行为修复应说明复现步骤及验证方式。
- PR 目标为 `main`，说明问题、修改后的行为、运行过的命令和结果。未运行或失败的检查请附原因。
- 界面改动请附去除隐私信息的截图或短 GIF，并注明设备与 macOS 版本。
- 不要提交密钥、证书、个人配置、真实用户截图或录屏。`.gitignore` 只是辅助，提交前仍应检查暂存内容。
- 使用第三方代码、素材或依赖前确认其许可证，并保留必要的来源与声明。

提交贡献即表示你有权按本项目的 [MIT 许可证](LICENSE) 提供这些内容。
