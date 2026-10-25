# XShot · 开角

已采用用户选择的 A「开角」：在完整的画框上打开一角，表达“取出一帧”。形状与获选 v3 一致；配色、字标和应用包装从该轮廓延伸。

## 文件入口

| 用途 | 文件 |
|---|---|
| 编辑矢量主标 | `masters/xshot-symbol-color.svg` |
| 黑 / 白 / 深色主标 | `masters/xshot-symbol-{black,white,ink}.svg` |
| 横向字标 | `masters/xshot-horizontal-{color,black,white}.svg` |
| 上下字标 | `masters/xshot-stacked-{color,black,white}.svg` |
| 独立文字 | `masters/xshot-wordmark.svg` |
| 小尺寸，收紧留白 | `masters/xshot-symbol-small.svg` |
| macOS 图标矢量 | `masters/xshot-app-icon.svg` |
| 完整网页图标 | `exports/web/`：SVG、ICO、16/32/48 PNG、180/192/512 PNG、manifest、head snippet |
| 应用图标各尺寸 | `exports/app-icon-sizes/` |
| 应用情境展示 | `presentation.html`，`exports/presentation/` |

仓库 `Resources/XShot.icns` 和 `Resources/XShot-icon.png` 用于应用；`Resources/Logo/` 内有应用标志与菜单栏模板图片。主标全部为可编辑路径，没有位图或字体依赖。

## 色彩

| 名称 | HEX | RGB | CMYK 近似值 | 作用 |
|---|---|---|---|---|
| XShot Blue | `#3478F6` | 52, 120, 246 | 79, 51, 0, 4 | 标志、主操作 |
| Ink | `#161B25` | 22, 27, 37 | 41, 27, 0, 85 | 名称、深色背景 |
| White | `#FFFFFF` | 255, 255, 255 | 0, 0, 0, 0 | 底色、反白 |

CMYK 为计算近似，不是印刷打样；尚未指定专色或 Pantone。数字应用以 HEX 为准。

蓝 / 白对比约 4.07:1，蓝 / Ink 约 4.24:1；标志和较大图形可用。普通小字号正文使用 Ink / 白，其对比约 17.25:1。深色界面也可使用白色版本，菜单栏由 macOS 的 template 图像机制决定颜色。

## 比例与留白

- 主标画布为 256，轮廓为 192 × 192；最小净空为一条主框宽度，即 28 单位。
- 16 px 起可使用独立符号；菜单栏提供 18 / 36 px 两份 template 位图。独立字标建议横向至少 160 px，低于此尺寸改用符号。
- `small.svg` 只将视口收紧为 `24 24 208 208`，不改变获选形状。白色版本保持同一轮廓，便于在实际 UI 中保持识别一致。
- macOS 图标为 1024 画布；白色主体 824 × 824，外留白 100；标志实体宽 576，约为主体的 70%。图标没有厚边框、重阴影或渐变。
- 保持横向 / 上下组合的相对位置；不要拉伸、倾斜、填满断角、增加相机或剪刀细节。

## 字体与来源

XShot 字标为本项目直接构造的几何路径；没有使用或分发第三方字体。X 两条斜线使用 60°，h / o / t 保持同一主干宽度，S 独立校正曲线。应用正文继续使用系统字体，不由该字标文件替代。

## 生成与验证

在仓库根目录执行 `python3 scripts/make-icons.py` 重建主标和应用 PNG / ICNS。依赖 Python 3、macOS `iconutil` 和 logo-design 的 `render_png.py`；已使用本机 Chrome 后端，不下载依赖。技能安装路径不同可传 `--renderer-script`。

`python3 Design/Logo/Final/make-kit-sources.py` 重建字标、情境展示规范与本地检查页。网页图标由技能 `export_variants.py --web-icons` 生成。

实际查看了 1024 px 图标、256/128/64/32/16 px 梯度、18/36 px 黑白模板与横向/上下字标。结构审计：符号、应用图标、横向组合与独立字标均 100/100；上下组合为 99/100，信息项来自有意上移的视觉重心。没有未闭合形状、字体、滤镜、描边依赖或位图；ICNS 各表示与 PNG 尺寸已核对。

以上是绘制与显示检查，不是商标注册审查；未做商标数据库或反向图片检索。
