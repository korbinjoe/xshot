# XShot

独立实现的原生 macOS 截图工具。第一版范围是框选截图、标注、复制与 PNG 保存、桌面贴图。

## 运行

双击 `Run XShot.command`，或运行 `./scripts/build.sh` 后打开 `dist/XShot.app`。需要 Apple Silicon Mac、macOS 14 或更新系统和 Xcode Command Line Tools。

构建后可将 `dist/XShot.app` 拖入“应用程序”，再从聚焦搜索 XShot 启动。

全局快捷键为 **⌥X（Option + X）**，左手即可操作；菜单栏也提供截图入口。首次截图需允许 XShot 访问屏幕，刚授权后若无法截图，请重新打开应用。未授权时仍可打开本地图片进行标注。

拖动选择区域，可拖动选区或四角调整；Enter 进入标注，Esc 取消。每次框选限制在单块显示器内。

标注支持矩形、箭头、画笔、文字与马赛克，可调整颜色和线宽；⌘Z 撤销、⌘⇧Z 重做、⌘C 复制、⌘S 保存。文字点击后输入，回车提交；提交后的对象暂不支持单独选中编辑，可撤销后重画。

编辑器顶部为图标工具栏与复制、保存、贴图按钮；底部显示尺寸及缩放。默认画布随窗口自动适配；手动缩放后可点击“适合窗口”恢复。

点击右上的“美化”，可选择原图、轻影、留白、展示四种预设，或调整背景、留白、圆角、阴影与细边框。透明、纯白、雾灰、深灰及蓝色渐变背景均可用。效果同步用于画布预览、复制、PNG保存和贴图；开启阴影时会自动留出足够空间，底部显示实际输出尺寸。选择“原图”或“恢复原图”即可关闭美化，原图与已有标注保留。

贴图支持拖动、缩放、复制、保存和多窗口并存。右下角悬浮条提供复制、保存和更多；右键或“更多”可选择缩放比例、透明度或关闭；菜单栏可统一隐藏或显示贴图。

运行 `./scripts/check-rendering.sh` 可检查导出像素、方向、透明度、标注坐标、撤销与重做。检查图片写入 `artifacts/rendering-check.png`。

运行 `./scripts/check-beautification.sh` 可检查美化输出、透明圆角、阴影边缘、画布坐标和切换样式后的撤销重做。验证记录见 `BEAUTIFICATION-QA.md`。

## 标志与应用图标

已采用 A「开角」：蓝色画框在右上打开一角，搭配纯白 macOS 图标底。主窗口、菜单栏和应用图标使用同一标志。矢量、黑白版本、字标组合及网页图标位于 `Design/Logo/Final/`，使用与重建说明见其中的 `GUIDE.md`。

`python3 scripts/make-icons.py` 可重建图标资源；常规构建直接使用 `Resources/` 内的 PNG 与 ICNS，不需要图像生成服务。

## 实现来源

- 项目源代码由本项目独立编写，以公开可见的产品行为作为需求参考。
- 未导入 iShot 源码、反编译代码、二进制、图标、图片、界面文件或文案。
- 本次实现使用苹果公开系统框架：AppKit、ScreenCaptureKit、Core Graphics、Carbon（全局快捷键）；没有外部代码依赖。
- 功能参考：<https://www.better365.cn/ishot.html>。
- API 文档：<https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager>。

前期曾只读检查已安装 iShot 的版本、依赖和类名以判断技术可分析性；项目没有采用其反汇编或反编译实现。这里记录实际开发过程，不宣称严格的隔离式 clean-room 开发。

长截图、OCR、录屏不在本版本范围内。
