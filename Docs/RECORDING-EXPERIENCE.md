# XShot 录制体验改进

日期：2026-10-25。本文件记录改造前的问题、公开产品参考、本轮实现及验证边界。代码实现、合成媒体检查和真实桌面实测分别记录；另见 [VERIFICATION.md](../VERIFICATION.md)。

后续鼠标镜头卡顿修复已将新录制与导出升级为 60 fps，并改用连续镜头路径及显示同步 GPU 预览，详见 [流畅度诊断与验收](DEMO-SMOOTHNESS.md)。下文的 30 fps 媒体数据和安装哈希保留为此前录制交互改造的历史验收结果。

## 改造前的三步体验

本轮基线结合当前界面与录制相关代码整理。截图保存在 `artifacts/recording-experience/before/`，用于与改进后的同一路径比较。

### 1. 准备录制：只能选择显示器

准备页只有显示器和项目名称，不能选择单个窗口或框选区域，也没有录制目标预览。用户要演示一个小窗口时，必须先录入整屏，再依赖自动缩放突出内容；整屏原片最高宽度为 1920 像素，小字可能在缩小过程中失去细节。

![改造前的录制准备页](../artifacts/recording-experience/before/01-prepare.png)

### 2. 开始录制：倒计时留在准备页

点击开始后，三秒倒计时只更新准备页底部的状态文字。准备页直到倒计时结束才隐藏；用户切换到要演示的应用后，看不到独立的目标屏倒计时。录制中的浮动控制器只有时长、步骤数和“完成”，不能暂停或直接重录。

![改造前位于准备页内的倒计时](../artifacts/recording-experience/before/02-countdown.png)

### 3. 进入编辑：没有首尾裁剪

停止录制后会打开编辑器，已有视频预览、缩放片段和交互步骤编辑。但视频只有整段播放范围，没有首尾裁剪；切换到目标应用、准备操作及结束时的等待也会保留在导出中。已有“打开项目…”依赖文件选择器，缺少最近项目入口。

![改造前的演示编辑器](../artifacts/recording-experience/before/03-editor.png)

## 一手产品与开源参考

本轮只查阅官方网站、官方帮助文档及项目自己的 GitHub 仓库，**未安装或实际操作这些竞品**。下表表示公开资料描述的行为，不是本机实测结论，也不表示 XShot 将实现其全部能力。搜索中的同名站点不作为 Screen Studio 的来源；此处使用 `screen.studio`。

| 参考 | 公开资料确认的行为 | 对 XShot 的具体启发 |
| --- | --- | --- |
| [Screen Studio：窗口录制](https://screen.studio/guide/recording-single-window)、[区域录制](https://screen.studio/guide/recording-area) | 窗口可点击或从列表选择；区域可拖选或输入尺寸。 | 用明确的录制模式与目标反馈，让用户开始前知道会录到什么。 |
| [Screen Studio：录制控制](https://screen.studio/guide/managing-recording-in-progress)、[结束录制](https://screen.studio/guide/starting-finishing-the-recording) | 浮动控制器显示时间，并提供完成、暂停、重录和删除；还可从菜单栏、Dock 和全局快捷键结束。 | 将暂停、继续、完成集中在易找到的控件内，保持快捷键入口。 |
| [Screen Studio：保存项目](https://screen.studio/guide/saving-your-project) | 项目可留待后续编辑或导出；“最近打开”及“显示以前的项目”帮助找回作品。 | 已有本地项目自动保存应配合最近项目和 Finder 入口，减少手动找文件。 |
| [CleanShot X：Screen Recording](https://cleanshot.com/screen-recording) | 快速录制后可进入原生 Studio 编辑；可裁去错误、调整缩放、光标和背景，并导出视频或 GIF。 | 录制结束应直接进入可用预览；优先补齐去掉准备和收尾片段的最短路径。 |
| [Cap：Studio Mode](https://cap.so/docs/recording/studio-mode)、[GitHub 仓库](https://github.com/CapSoftware/Cap) | 支持屏幕、窗口、区域选源及暂停、继续、重录；停止后打开本地项目；源媒体和编辑配置保留，导出不替代项目。 | 将录制与后续编辑连起来；裁剪只保存编辑参数，原始录屏保持可恢复。 |
| [Cap：Camera & Microphone](https://cap.so/docs/recording/camera-and-mic) | 可选择麦克风，并在开始前用输入电平确认音频来源。 | 声音选项必须对应真实采集能力；未来加入录音时，要同时提供设备与状态反馈。 |
| [Screenity：GitHub 仓库](https://github.com/alyssaxuu/screenity)、[倒计时](https://help.screenity.io/recording/how-to-set-or-disable-the-countdown-before-recording)、[暂停](https://help.screenity.io/recording/how-to-pause-or-resume-a-recording)、[重录](https://help.screenity.io/recording/how-to-restart-a-recording) | 页面中央显示可取消的倒计时；暂停后有清晰提示；重录会先提示当前进度将丢失。 | 倒计时应出现在所选屏幕上；暂停状态要可辨认；XShot 重录目标进一步保留上一条录制。 |
| [QuickRecorder：GitHub 仓库](https://github.com/lihaoyun6/QuickRecorder) | 原生 ScreenCaptureKit 录制器，公开支持屏幕、窗口、应用及无驱动系统音频；麦克风和系统音可分轨。 | 作为原生 macOS 采集交互的参考，尤其是目标选择与将来的音频工作流。 |

Cap 主体代码采用 AGPLv3，部分采集 crate 采用 MIT；Screenity 当前 MV3 版本采用 GPLv3；QuickRecorder 采用 AGPLv3。此处只参考公开可观察的行为，由 XShot 独立实现；不导入其代码、图标、界面素材或品牌文案。

## 本轮实现与验收范围

下列主路径已实现，真实桌面操作的确认范围见文末。

| 环节 | 目标行为 | 验收重点 |
| --- | --- | --- |
| 范围选择 | 在准备页明确区分“屏幕 / 窗口 / 区域”，支持选择目标窗口或框选单块显示器内的区域。 | 录制内容、输出尺寸和鼠标/点击坐标与所选范围一致；Retina 缩放与跨屏坐标正确。 |
| 目标预览 | 显示当前选择的名称、尺寸与画面预览，重新选择后同步更新。 | 用户能在开始前确认目标；过期窗口或失效范围要有清晰反馈，不能悄悄回退为整屏。 |
| 独立倒计时 | 点击开始立即隐藏准备页，在目标屏上显示倒计时，并提供取消入口。 | 切换到目标应用后仍可见；取消不创建可误认的成品；倒计时和 XShot 控件不进入视频。 |
| 暂停与继续 | 浮动控制器提供暂停/继续，明确显示当前状态；暂停不增加有效录制时长或自动步骤。 | 继续后视频时间、鼠标轨迹、点击和步骤保持同步；暂停期间的等待与操作不进入结果。 |
| 保留旧 take 的重录 | 录制中可重新开始，已录内容先按独立项目保存，再进入新一条录制。 | 新旧项目互不覆盖；新录制失败或取消时仍可找回上一条；提示清楚旧内容的保存位置。 |
| 最近项目 | 准备页可看见并重新打开最近的本地演示项目，提供 Finder 入口。 | 重启应用后仍可找回；项目移动、删除或无效时给出明确反馈。 |
| 首尾裁剪 | 编辑器可设置视频保留的开始和结束时间，预览及 MP4 导出应用相同范围。 | 原始录屏不改写；重开项目保留裁剪参数；导出时长、镜头、光标与点击效果对应同一时间范围。 |

音频录制不属于上述本轮目标。当前无音频的边界需要继续在准备页和文档中明确展示；增加麦克风或系统音选项时，必须一起完成采集、保存、预览、导出和设备反馈链路。

## 最终验证记录

构建与安装：`scripts/build.sh` 通过，已更新 `/Applications/XShot.app`；最终安装版与 `dist` 可执行文件 SHA-256 相同，为 `7c91389fcba14ead9474aeab6ab1d184956c7876345b4ac1215afb672d3f54c3`。原应用备份于 `artifacts/recording-experience/XShot-before.app`。屏幕录制授权已重新关联并实际生效。

专项检查均通过：录制媒体管线、视频预览/导出、离线交互步骤、截图像素与美化回归。新增录制检查覆盖暂停时间剔除、暂停时停止、静态画面恢复、鼠标/点击同步及首帧超时；新增视频检查覆盖旧项目兼容、裁剪保存、两个不同起点的画面与效果、预览回拖与重播、取消保护及 Rec.709 色彩。`trim-1.mp4` 经 ffprobe 确认 640×360、30 fps、39 帧、零起点和 1.300 秒。

桌面走查中已发现并修复目标列表后台刷新造成的身份错配：下拉项现在携带明确的窗口/显示器身份，开始或框选前取消过期刷新；同时修复退出时可能继续重录、区域选择并发及最小区域校验不一致。续验收又修复两处问题：播放条定位先捕获目标位置，避免暂停回调重置滑块；屏幕/区域开始时不再激活旧应用，避免覆盖刚选好的画面。此前中间构建及受其他窗口活动影响的样本不计作纯净画面证据。

| 实际操作 | 结果与证据 |
| --- | --- |
| 独立窗口录制、暂停、继续、完成 | MOV 为 1600×1056、24.982 秒，可完整解码，无录制警告；21.004 秒暂停期间的阶段 3/4 未进入源视频，保存画面仅阶段 1/2/5。见 `window-media-verification.json`。 |
| 重启并从最近项目继续编辑 | 实际通过最近项目菜单重开窗口项目，编辑器及原片可用。 |
| 定位、设入点/出点、原生面板导出 | 持久化保留范围约 8.232–18.351 秒；导出 1600×1056、30 fps、304 帧、10.118 秒，与范围差不足 1ms。见 `trim-media-verification.json`。 |
| 区域框选与录制 | 770×450 pt 选区输出 1540×900 px，24.433 秒、475 个源帧，全解码通过，无警告；专用画面阶段 1→2 可见。见 `region-final-verification.json`。 |
| 重录保存上一条 | 两个独立项目及 MOV 均存在，目录、文件 inode 与 SHA 不同，上一条没有被覆盖。见 `region-retake-preservation.json`。 |
| 取消倒计时 | 开始后立刻用应用内 ⌥R 取消，返回准备页；项目目录数量前后均为 12，没有创建录制。见 `countdown-cancel.json`。 |

上述 JSON 位于 `artifacts/recording-experience/`。区域录制如实包含系统“screencaptureui 无法打开”提示及截图工具菜单遮挡，不能将该样本描述为纯净的专用画面，也没有将系统截图工具故障当作本应用错误。原片的源帧、时间戳和修改时间与导出前一致；缺少导出前 SHA，因此不声称已验证真实原片逐字节不变。

新增 `scripts/check-demo-studio.sh` 通过真实 NSControl action 复现并保护定位修复，覆盖暂停定位 1.5 秒、播放中定位 2.5 秒并暂停、裁剪持久化 1.5–2.5 秒、合成原片字节不变。它使用隐藏窗口与项目副本，不替代上述桌面走查。

![窗口录制准备](../artifacts/recording-experience/after/01-window-prepare.png)
![暂停控制条](../artifacts/recording-experience/after/02-paused-hud.png)
![实际裁剪后的编辑器](../artifacts/recording-experience/after/03-trimmed-editor.png)

可访问性：准备页的范围、目标、名称、倒计时、状态及预览有原生标签；录制提供菜单与全局快捷键。暂停使用文字、图标和虚线边框共同反馈。本轮自动化没有派发真实全局鼠标点击，因此没有验证物理鼠标生成步骤和缩放；VoiceOver、多显示器、长时录制及全局快捷键的物理键盘入口也尚未验证。专用浮动测试程序已退出，用户验收前打开的项目已恢复，安装版保留在权限就绪的主入口。

单元检查、合成媒体、界面可见及真实桌面操作应分别记录证据边界；构建成功不能替代实际录制和导出验证。
