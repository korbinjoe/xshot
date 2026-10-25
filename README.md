# XShot

独立实现的原生 macOS 截图与产品演示工具。0.2.0 包含框选截图、标注、复制与 PNG 保存、桌面贴图，以及自动缩放录屏和可点击步骤演示。

## 运行

双击 `Run XShot.command`，或运行 `./scripts/build.sh` 后打开 `dist/XShot.app`。需要 Apple Silicon Mac、macOS 14 或更新系统和 Xcode Command Line Tools。

构建后可将 `dist/XShot.app` 拖入“应用程序”，再从聚焦搜索 XShot 启动。

全局快捷键为 **⌥X（Option + X）** 截图、**⌥R（Option + R）** 打开产品演示或完成录制，均可单手操作；菜单栏也提供入口。首次截图或录制需允许 XShot 访问屏幕，刚授权后若无法采集，请重新打开应用。未授权时仍可打开本地图片进行标注。

## 截图与标注

拖动选择区域，可拖动选区或四角调整；Enter 进入标注，Esc 取消。每次框选限制在单块显示器内。

标注支持矩形、箭头、画笔、文字与马赛克，可调整颜色和线宽；⌘Z 撤销、⌘⇧Z 重做、⌘C 复制、⌘S 保存。文字点击后输入，回车提交；提交后的对象暂不支持单独选中编辑，可撤销后重画。

编辑器顶部为图标工具栏与复制、保存、贴图按钮；底部显示尺寸及缩放。默认画布随窗口自动适配；手动缩放后可点击“适合窗口”恢复。

点击右上的“美化”，可选择原图、轻影、留白、展示四种预设，或调整背景、留白、圆角、阴影与细边框。透明、纯白、雾灰、深灰及蓝色渐变背景均可用。效果同步用于画布预览、复制、PNG保存和贴图；开启阴影时会自动留出足够空间，底部显示实际输出尺寸。选择“原图”或“恢复原图”即可关闭美化，原图与已有标注保留。

贴图支持拖动、缩放、复制、保存和多窗口并存。右下角悬浮条提供复制、保存和更多；右键或“更多”可选择缩放比例、透明度或关闭；菜单栏可统一隐藏或显示贴图。

## 产品演示 · 0.2

按 **⌥R**，选择显示器并命名，点击“开始录制”。三秒倒计时后录制整块显示器；浮动控制器提供“完成”，录制期间再按 **⌥R** 也可结束并进入编辑器。XShot 自身窗口从录制画面排除；原片、鼠标轨迹、点击和步骤截图仅保存到本机。

- **演示视频**：根据点击安排平滑缩放，邻近连续点击合并为稳定焦点；可修改片段起止时间、倍数、启用状态，并在画面中重新定位焦点。自动聚焦、鼠标和点击提示可分别关闭。预览与导出共享合成器；导出 H.264 MP4，保持原片尺寸，固定 30 fps，即使原片静止段没有新帧，鼠标和缩放仍按播放时间继续变化。
- **交互步骤**：自动生成点击前的步骤截图与最终结果图。通过缩略图编辑标题、说明、热点和跳转目标；可拖动热点、增删重排步骤，并撤销重做。切换“预览”可按热点体验分支、返回和重新开始。
- **离线 HTML**：导出内嵌图片、文字与播放器的单个 HTML 文件，在浏览器离线播放，无需服务器。它是截图式可点击演示，不会操作真实产品，也不克隆网页 DOM。继续编辑请打开原项目。

项目默认保存在 `~/Movies/XShot/` 的 `.xshotdemo` 包中，包含 `recording.mov`、`project.json` 和 `steps/`。编辑自动保存；用“打开项目…”或 **⌘⇧O** 重开。MP4 导出可取消，原片与项目保留，已有导出目标仅在新导出成功后替换。

当前录制仅支持所选单显示器整屏，原片宽度最高 1920 像素、最高 30 fps，**不含音频**。尚无窗口/区域录制、录制暂停、录音/系统音频、摄像头、云分享、AI 说明或敏感信息打码。自动步骤使用通用标题和说明，需要按实际操作编辑。功能参考与详细范围见 [产品演示说明](Docs/PRODUCT-DEMO.md)。

## 验证

运行 `./scripts/check-rendering.sh` 可检查导出像素、方向、透明度、标注坐标、撤销与重做。检查图片写入 `artifacts/rendering-check.png`。

运行 `./scripts/check-beautification.sh` 可检查美化输出、透明圆角、阴影边缘、画布坐标和切换样式后的撤销重做。验证记录见 `BEAUTIFICATION-QA.md`。

产品演示的专项检查：

```sh
./scripts/check-demo-recorder.sh
./scripts/check-demo-video.sh
./scripts/check-interactive-demo.sh
```

分别覆盖录制写入与项目模型、真实短片导出及 VFR 静态段效果、交互播放器与离线导出。这些单元和合成媒体检查已通过；真实安装版桌面操作的结果与边界见 [VERIFICATION.md](VERIFICATION.md)。

## 标志与应用图标

已采用 A「开角」：蓝色画框在右上打开一角，搭配纯白 macOS 图标底。主窗口、菜单栏和应用图标使用同一标志。矢量、黑白版本、字标组合及网页图标位于 `Design/Logo/Final/`，使用与重建说明见其中的 `GUIDE.md`。

`python3 scripts/make-icons.py` 可重建图标资源；常规构建直接使用 `Resources/` 内的 PNG 与 ICNS，不需要图像生成服务。

## 实现来源

- 项目源代码由本项目独立编写，以公开可见的产品行为作为需求参考。
- 未导入 iShot 源码、反编译代码、二进制、图标、图片、界面文件或文案。
- 本次实现使用苹果公开系统框架：AppKit、ScreenCaptureKit、AVFoundation、Core Image、Core Graphics、WebKit、Carbon（全局快捷键）；没有外部代码依赖。
- 截图功能参考：[iShot](https://www.better365.cn/ishot.html)；产品演示功能与交互参考：[Screen Studio](https://screen.studio/)、[Cap](https://cap.so/)、[Arcade](https://www.arcade.software/product/interactive-demo)、[Supademo](https://supademo.com/features/guided-demos)。未复用这些项目的代码或资产。
- API 文档：[SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)。

前期曾只读检查已安装 iShot 的版本、依赖和类名以判断技术可分析性；项目没有采用其反汇编或反编译实现。这里记录实际开发过程，不宣称严格的隔离式 clean-room 开发。

长截图与 OCR 不在当前版本范围内。
