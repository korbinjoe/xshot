import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class DemoStudioWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var project: DemoProject
    private let directory: URL
    private let onNewRecording: () -> Void
    private let mode = NSSegmentedControl(labels: ["演示视频", "交互步骤"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSTableView()
    private let listTitle = NSTextField(labelWithString: "缩放片段")
    private let listEmptyState = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let center = NSView()
    private let inspector = NSStackView()
    private let video = DemoVideoPreview(frame: .zero)
    private let interactive = InteractiveDemoPreview(frame: .zero)
    private let playButton = NSButton()
    private let timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let trimRangeLabel = NSTextField(labelWithString: "")
    private let trimDurationLabel = NSTextField(labelWithString: "")
    private let trimIn = NSButton()
    private let trimOut = NSButton()
    private let resetTrim = NSButton()
    private let previewMode = NSSegmentedControl(labels: ["编辑", "预览"], trackingMode: .selectOne, target: nil, action: nil)
    private let projectTitle = NSTextField(string: "")
    private let stepTitle = NSTextField(string: "")
    private let stepBody = NSTextField(string: "")
    private let nextStep = NSPopUpButton()
    private let zoomStart = NSTextField(string: "")
    private let zoomEnd = NSTextField(string: "")
    private let zoomAmount = NSPopUpButton()
    private let zoomEnabled = NSButton(checkboxWithTitle: "启用此片段", target: nil, action: nil)
    private let autoZoom = NSButton(checkboxWithTitle: "自动聚焦", target: nil, action: nil)
    private let showCursor = NSButton(checkboxWithTitle: "显示鼠标", target: nil, action: nil)
    private let showClicks = NSButton(checkboxWithTitle: "点击提示", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "更改自动保存到本机")
    private let progress = NSProgressIndicator()
    private let cancelExport = NSButton(title: "取消导出", target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private var selected = 0
    private var refreshing = false
    private var undoHistory: [DemoProject] = []
    private var redoHistory: [DemoProject] = []
    private var exporter: DemoVideoRenderer?
    private var exportTask: Task<Void, Never>?
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var pendingSave: DispatchWorkItem?
    private var isSteps: Bool { mode.selectedSegment == 1 }
    var isExporting: Bool { exporter != nil }
    var projectDirectory: URL { directory }

    init(project: DemoProject, directory: URL, onNewRecording: @escaping () -> Void) {
        self.project = project
        self.directory = directory
        self.onNewRecording = onNewRecording
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1220, screen.width - 80), height: min(760, screen.height - 80)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = project.title
        window.representedURL = directory
        window.subtitle = "产品演示"
        window.minSize = NSSize(width: 1000, height: 660)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        window.delegate = self
        buildInterface()
        video.configure(project: project, directory: directory)
        var lastPlaying: Bool?
        video.onTimeChange = { [weak self] time, playing in
            guard let self else { return }
            self.timeSlider.doubleValue = time
            self.updatePlaybackTime(time)
            if lastPlaying != playing {
                self.playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "暂停" : "播放")
                self.playButton.setAccessibilityLabel(playing ? "暂停预览" : "播放预览")
                lastPlaying = playing
            }
        }
        video.onFocusPicked = { [weak self] point in
            guard let self, !self.isSteps, self.project.zooms.indices.contains(self.selected) else { return }
            self.edit { $0.zooms[self.selected].focus = point }
            self.video.allowsFocusPicking = false
            self.status.stringValue = "焦点已更新"
        }
        interactive.onHotspotMoved = { [weak self] point in
            guard let self, self.isSteps, self.project.steps.indices.contains(self.selected) else { return }
            self.edit { $0.steps[self.selected].hotspot = point }
        }
        refreshAll()
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let header = NSVisualEffectView()
        header.material = .titlebar
        header.blendingMode = .withinWindow
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(changeDemoMode)
        mode.setAccessibilityLabel("演示类型")
        let new = button("新录制", symbol: "record.circle", action: #selector(newRecording))
        let folder = button("项目文件", symbol: "folder", action: #selector(showProject))
        let export = button("导出…", symbol: "square.and.arrow.up", action: #selector(exportProject))
        export.bezelColor = .controlAccentColor
        configureIcon(undoButton, symbol: "arrow.uturn.backward", label: "撤销演示编辑", action: #selector(undoEdit))
        configureIcon(redoButton, symbol: "arrow.uturn.forward", label: "重做演示编辑", action: #selector(redoEdit))
        let headerStack = NSStackView(views: [mode, undoButton, redoButton, flexible(), new, folder, export])
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        listTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        listTitle.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        list.addTableColumn(column)
        list.headerView = nil
        list.rowHeight = 76
        list.intercellSpacing = NSSize(width: 0, height: 6)
        list.style = .sourceList
        list.dataSource = self
        list.delegate = self
        list.setAccessibilityLabel("演示步骤与缩放片段")
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        emptyTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 11)
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        let emptyAdd = button("添加聚焦片段", symbol: "plus", action: #selector(addItem))
        listEmptyState.setViews([emptyTitle, emptyDetail, emptyAdd], in: .center)
        listEmptyState.orientation = .vertical
        listEmptyState.alignment = .centerX
        listEmptyState.spacing = 10
        let add = icon("plus", label: "添加步骤或缩放片段", action: #selector(addItem))
        let up = icon("arrow.up", label: "上移步骤", action: #selector(moveStepUp))
        let down = icon("arrow.down", label: "下移步骤", action: #selector(moveStepDown))
        let remove = icon("minus", label: "移除所选步骤或片段", action: #selector(removeItem))
        let listActions = NSStackView(views: [add, flexible(), up, down, remove])
        listActions.spacing = 6
        listActions.alignment = .centerY
        [listTitle, scroll, listActions, listEmptyState].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview($0) }
        NSLayoutConstraint.activate([
            listTitle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            listTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: listTitle.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: listActions.topAnchor, constant: -8),
            listActions.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            listActions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            listActions.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            listEmptyState.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            listEmptyState.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            listEmptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyDetail.widthAnchor.constraint(equalTo: listEmptyState.widthAnchor)
        ])

        center.wantsLayer = true
        center.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        configureIcon(playButton, symbol: "play.fill", label: "播放预览", action: #selector(togglePlay))
        timeSlider.target = self
        timeSlider.action = #selector(seekVideo)
        timeSlider.isContinuous = true
        timeSlider.setAccessibilityLabel("视频播放位置")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.widthAnchor.constraint(equalToConstant: 126).isActive = true
        timeLabel.setAccessibilityLabel("保留片段播放进度与导出时长")
        previewMode.selectedSegment = 0
        previewMode.target = self
        previewMode.action = #selector(changePreviewMode)
        previewMode.setAccessibilityLabel("交互步骤编辑或预览")
        let playback = NSStackView(views: [playButton, timeSlider, timeLabel, previewMode])
        playback.spacing = 10
        playback.alignment = .centerY
        [video, interactive, playback].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; center.addSubview($0) }
        for view in [video as NSView, interactive] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -12),
                view.topAnchor.constraint(equalTo: center.topAnchor, constant: 12),
                view.bottomAnchor.constraint(equalTo: playback.topAnchor, constant: -12)
            ])
        }
        NSLayoutConstraint.activate([
            playback.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 16),
            playback.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -16),
            playback.heightAnchor.constraint(equalToConstant: 32),
            playback.bottomAnchor.constraint(equalTo: center.bottomAnchor, constant: -12)
        ])

        let inspectorContainer = NSScrollView()
        inspectorContainer.hasVerticalScroller = true
        inspectorContainer.autohidesScrollers = true
        inspectorContainer.drawsBackground = false
        let inspectorDocument = DemoInspectorDocumentView()
        inspectorDocument.translatesAutoresizingMaskIntoConstraints = false
        inspectorContainer.documentView = inspectorDocument
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 14
        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspectorDocument.addSubview(inspector)
        NSLayoutConstraint.activate([
            inspectorDocument.widthAnchor.constraint(equalTo: inspectorContainer.contentView.widthAnchor),
            inspector.leadingAnchor.constraint(equalTo: inspectorDocument.leadingAnchor, constant: 18),
            inspector.trailingAnchor.constraint(equalTo: inspectorDocument.trailingAnchor, constant: -18),
            inspector.topAnchor.constraint(equalTo: inspectorDocument.topAnchor, constant: 18),
            inspector.bottomAnchor.constraint(equalTo: inspectorDocument.bottomAnchor, constant: -18)
        ])
        configureTrimButton(trimIn, title: "设为入点", symbol: "arrow.right.to.line", action: #selector(markTrimIn))
        configureTrimButton(trimOut, title: "设为出点", symbol: "arrow.left.to.line", action: #selector(markTrimOut))
        configureTrimButton(resetTrim, title: "恢复整段", symbol: "arrow.uturn.backward", action: #selector(restoreFullVideo))
        trimIn.toolTip = "剪掉当前播放位置之前的内容，原片保留"
        trimOut.toolTip = "剪掉当前播放位置之后的内容，原片保留"
        trimRangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trimRangeLabel.textColor = .secondaryLabelColor
        trimDurationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        for (field, label) in [(projectTitle, "演示名称"), (stepTitle, "步骤标题"), (stepBody, "步骤说明"), (zoomStart, "缩放开始秒数"), (zoomEnd, "缩放结束秒数")] {
            field.delegate = self
            field.target = self
            field.action = #selector(commitFields)
            field.font = .systemFont(ofSize: 12)
            field.setAccessibilityLabel(label)
        }
        stepBody.usesSingleLineMode = false
        stepBody.cell?.wraps = true
        stepBody.lineBreakMode = .byWordWrapping
        stepBody.heightAnchor.constraint(equalToConstant: 80).isActive = true
        zoomAmount.addItems(withTitles: ["1.3×", "1.5×", "1.8×", "2.0×", "2.5×", "3.0×"])
        zoomAmount.target = self
        zoomAmount.action = #selector(changeZoomAmount)
        zoomAmount.setAccessibilityLabel("所选片段缩放倍数")
        for control in [autoZoom, showCursor, showClicks, zoomEnabled] {
            control.target = self
            control.action = #selector(changeOptions)
        }
        nextStep.target = self
        nextStep.action = #selector(changeDestination)
        nextStep.setAccessibilityLabel("热点跳转目标")

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        progress.isHidden = true
        cancelExport.target = self
        cancelExport.action = #selector(cancelExporting)
        cancelExport.bezelStyle = .inline
        cancelExport.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, flexible(), progress, cancelExport])
        footer.alignment = .centerY
        footer.spacing = 10
        [header, sidebar, center, inspectorContainer, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; content.addSubview($0) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor), header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 52),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16), headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor), sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 202), sidebar.bottomAnchor.constraint(equalTo: footer.topAnchor),
            center.topAnchor.constraint(equalTo: header.bottomAnchor), center.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            center.trailingAnchor.constraint(equalTo: inspectorContainer.leadingAnchor), center.bottomAnchor.constraint(equalTo: footer.topAnchor),
            inspectorContainer.topAnchor.constraint(equalTo: header.bottomAnchor), inspectorContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspectorContainer.widthAnchor.constraint(equalToConstant: 234), inspectorContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func refreshAll() {
        refreshing = true
        defer { refreshing = false }
        let count = isSteps ? project.steps.count : project.zooms.count
        selected = max(0, min(selected, count - 1))
        listTitle.stringValue = isSteps ? "操作步骤 · \(count)" : "缩放片段 · \(count)"
        list.reloadData()
        listEmptyState.isHidden = isSteps || count > 0
        emptyTitle.stringValue = "尚无聚焦片段"
        emptyDetail.stringValue = "画面会按原比例播放。\n在需要强调的位置添加片段，\n再点击画面选择焦点。"
        if count > 0 { list.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        video.isHidden = isSteps
        interactive.isHidden = !isSteps
        [playButton, timeSlider, timeLabel].forEach { $0.isHidden = isSteps }
        previewMode.isHidden = !isSteps
        let range = project.videoRange()
        timeSlider.minValue = range.start
        timeSlider.maxValue = max(range.start + 0.001, range.lastFrameTime)
        timeSlider.doubleValue = range.clampedPreviewTime(video.currentTime)
        updatePlaybackTime(video.currentTime)
        projectTitle.stringValue = project.title
        window?.title = project.title
        autoZoom.state = project.autoZoom ? .on : .off
        showCursor.state = project.showCursor ? .on : .off
        showClicks.state = project.showClicks ? .on : .off
        inspector.arrangedSubviews.forEach { inspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        addInspector(label("演示名称"), projectTitle, rule())
        if isSteps {
            if project.steps.indices.contains(selected) {
                let step = project.steps[selected]
                stepTitle.stringValue = step.title
                stepBody.stringValue = step.body
                nextStep.removeAllItems()
                nextStep.addItem(withTitle: "下一步 / 完成")
                for (index, item) in project.steps.enumerated() { nextStep.addItem(withTitle: "\(index + 1). \(item.title)") }
                nextStep.selectItem(at: step.nextStepID.flatMap { id in project.steps.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
                addInspector(label("步骤标题"), stepTitle, label("说明"), stepBody, label("点击热点后"), nextStep)
                let clear = button("移除热点", symbol: "circle.slash", action: #selector(clearHotspot))
                clear.isEnabled = step.hotspot != nil
                addInspector(clear, note("点击画面放置热点，拖动可调整位置。选“预览”即可像访客一样点击体验。"))
            } else { addInspector(note("没有步骤。点击左下角 ＋ 添加截图，或重新录制操作。")) }
            updateInteractive()
        } else {
            trimRangeLabel.stringValue = "原片 \(Self.preciseTime(range.start)) → \(Self.preciseTime(range.end))"
            trimDurationLabel.stringValue = String(format: "导出时长 %.2f 秒", range.duration)
            trimDurationLabel.setAccessibilityLabel(trimDurationLabel.stringValue)
            resetTrim.isEnabled = project.trimStart != nil || project.trimEnd != nil
            let marks = NSStackView(views: [trimIn, trimOut])
            marks.distribution = .fillEqually
            marks.spacing = 6
            addInspector(label("保留范围"), trimDurationLabel, trimRangeLabel, marks, resetTrim, rule())
            addInspector(label("画面效果"), autoZoom, showCursor, showClicks, rule())
            if project.zooms.indices.contains(selected) {
                let zoom = project.zooms[selected]
                zoomEnabled.state = zoom.enabled ? .on : .off
                zoomStart.stringValue = String(format: "%.2f", zoom.start)
                zoomEnd.stringValue = String(format: "%.2f", zoom.end)
                let amounts = [1.3, 1.5, 1.8, 2.0, 2.5, 3.0]
                zoomAmount.selectItem(at: amounts.enumerated().min(by: { abs($0.element - zoom.amount) < abs($1.element - zoom.amount) })?.offset ?? 2)
                addInspector(label("所选缩放片段"), zoomEnabled, label("开始 · 原片秒数"), zoomStart, label("结束 · 原片秒数"), zoomEnd,
                             label("放大倍数"), zoomAmount, button("在画面中定位", symbol: "scope", action: #selector(pickFocus)))
            } else { addInspector(note("点击会自动生成缩放片段。也可在左下角 ＋ 为当前播放位置添加一段。")) }
            video.project = project
        }
        undoButton.isEnabled = !undoHistory.isEmpty
        redoButton.isEnabled = !redoHistory.isEmpty
        if !isExporting { status.stringValue = project.recordingNotice ?? "更改自动保存到本机 · 视频 \(String(format: "%.2f", range.duration)) 秒 · \(project.steps.count) 个步骤" }
    }

    private func updatePlaybackTime(_ sourceTime: Double) {
        let range = project.videoRange()
        timeLabel.stringValue = "\(Self.playbackTime(max(0, sourceTime - range.start))) / \(Self.playbackTime(range.duration))"
        timeLabel.toolTip = "原片位置 \(Self.preciseTime(sourceTime)) · 仅播放保留范围"
        trimIn.isEnabled = sourceTime > range.start + 0.0001 && range.end - sourceTime >= DemoVideoTiming.frameDuration
        trimOut.isEnabled = sourceTime - range.start >= DemoVideoTiming.frameDuration && sourceTime < range.end - 0.0001
    }

    private func updateInteractive() {
        interactive.show(project: project, directory: directory, selectedStep: selected, editing: previewMode.selectedSegment == 0)
    }

    private func edit(_ mutation: (inout DemoProject) -> Void, refresh: Bool = true) {
        undoHistory.append(project)
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        mutation(&project)
        if refresh { save() } else { scheduleSave() }
        if refresh { refreshAll() }
        else {
            video.project = project
            if isSteps { updateInteractive() }
            undoButton.isEnabled = true
            redoButton.isEnabled = false
        }
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do { try project.save(to: directory) }
        catch { showError(error) }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Termination may bypass window closing and its delayed autosave work item.
    /// Commit the field editor and persist synchronously before allowing either.
    func flushPendingChanges() -> Bool {
        guard persistFields(includeTiming: true) else { return false }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try project.save(to: directory)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { isSteps ? project.steps.count : project.zooms.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 5
        cell.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 8)
        let title: String
        let detail: String
        if isSteps {
            title = "\(row + 1). \(project.steps[row].title)"
            detail = project.steps[row].hotspot == nil ? "结果画面" : "点击热点继续"
        } else {
            let zoom = project.zooms[row]
            title = "\(Self.time(zoom.start)) – \(Self.time(zoom.end))"
            let range = project.videoRange()
            if zoom.end <= range.start || zoom.start >= range.end { detail = "保留范围外 · 不会导出" }
            else { detail = zoom.enabled ? String(format: "%.1f× · 点击聚焦", zoom.amount) : "已停用" }
        }
        let text = NSTextField(labelWithString: title)
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: detail)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let textStack = NSStackView(views: [text, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        if isSteps {
            cell.orientation = .horizontal
            cell.alignment = .centerY
            let image = NSImageView()
            image.image = thumbnail(for: project.steps[row].imageName)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.widthAnchor.constraint(equalToConstant: 52).isActive = true
            image.heightAnchor.constraint(equalToConstant: 38).isActive = true
            cell.addArrangedSubview(image)
        }
        cell.addArrangedSubview(textStack)
        text.widthAnchor.constraint(lessThanOrEqualToConstant: isSteps ? 104 : 164).isActive = true
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: isSteps ? 104 : 164).isActive = true
        cell.setAccessibilityLabel("\(title)，\(detail)")
        return cell
    }

    private func thumbnail(for name: String) -> NSImage? {
        if let cached = thumbnailCache.object(forKey: name as NSString) { return cached }
        guard let url = try? DemoProject.resource(name, in: directory),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 120,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache.countLimit = 60
        thumbnailCache.setObject(image, forKey: name as NSString)
        return image
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing, list.selectedRow >= 0 else { return }
        selected = list.selectedRow
        if !isSteps, project.zooms.indices.contains(selected) {
            let zoom = project.zooms[selected]
            video.pause()
            video.seek(to: min(zoom.start + 0.55, max(zoom.start, zoom.end - 0.01)))
        }
        refreshAll()
    }

    @objc private func changeDemoMode() { video.pause(); video.allowsFocusPicking = false; selected = 0; refreshAll() }
    @objc private func changePreviewMode() { updateInteractive() }
    @objc private func togglePlay() { if video.isPlaying { video.pause() } else { video.play() } }
    @objc private func seekVideo() {
        let destination = timeSlider.doubleValue
        video.pause()
        video.seek(to: destination)
    }
    @objc private func markTrimIn() {
        guard persistFields(includeTiming: true) else { return }
        let time = video.currentTime
        let range = project.videoRange()
        guard time > range.start, range.end - time >= DemoVideoTiming.frameDuration else { return }
        video.pause()
        edit { $0.trimStart = time }
        status.stringValue = "已剪去片头 · 原片保留，可随时恢复整段"
    }
    @objc private func markTrimOut() {
        guard persistFields(includeTiming: true) else { return }
        let time = video.currentTime
        let range = project.videoRange()
        guard time - range.start >= DemoVideoTiming.frameDuration, time < range.end else { return }
        video.pause()
        edit { $0.trimEnd = time }
        status.stringValue = "已剪去片尾 · 原片保留，可随时恢复整段"
    }
    @objc private func restoreFullVideo() {
        guard persistFields(includeTiming: true) else { return }
        video.pause()
        edit { $0.trimStart = nil; $0.trimEnd = nil }
        status.stringValue = "已恢复整段视频"
    }
    @objc private func pickFocus() { video.allowsFocusPicking = true; status.stringValue = "点击画面选择焦点 · 当前显示完整画面" }
    @objc private func newRecording() { video.pause(); onNewRecording() }
    @objc private func showProject() { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    @objc private func changeOptions() {
        edit { project in
            project.autoZoom = autoZoom.state == .on
            project.showCursor = showCursor.state == .on
            project.showClicks = showClicks.state == .on
            if project.zooms.indices.contains(selected) { project.zooms[selected].enabled = zoomEnabled.state == .on }
        }
    }
    @objc private func changeZoomAmount() {
        guard project.zooms.indices.contains(selected) else { return }
        edit { $0.zooms[selected].amount = [1.3, 1.5, 1.8, 2.0, 2.5, 3.0][max(0, zoomAmount.indexOfSelectedItem)] }
    }
    @objc private func changeDestination() {
        guard project.steps.indices.contains(selected) else { return }
        edit { $0.steps[selected].nextStepID = nextStep.indexOfSelectedItem > 0 ? $0.steps[nextStep.indexOfSelectedItem - 1].id : nil }
    }
    @objc private func clearHotspot() {
        guard project.steps.indices.contains(selected) else { return }
        edit { $0.steps[selected].hotspot = nil }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== zoomStart, field !== zoomEnd else { return }
        _ = persistFields(includeTiming: false)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === zoomStart || field === zoomEnd { commitFields() }
    }
    @objc private func commitFields() { _ = persistFields(includeTiming: true) }
    @discardableResult private func persistFields(includeTiming: Bool) -> Bool {
        guard !refreshing else { return true }
        let newTitle = projectTitle.stringValue.isEmpty ? "未命名演示" : projectTitle.stringValue
        var updated = project
        updated.title = newTitle
        if isSteps, updated.steps.indices.contains(selected) {
            updated.steps[selected].title = stepTitle.stringValue
            updated.steps[selected].body = stepBody.stringValue
        } else if includeTiming, updated.zooms.indices.contains(selected) {
            let original = project.zooms[selected]
            let start = zoomStart.stringValue == String(format: "%.2f", original.start) ? original.start : Double(zoomStart.stringValue)
            let parsedEnd = zoomEnd.stringValue == String(format: "%.2f", original.end) ? original.end : Double(zoomEnd.stringValue)
            guard let start, let parsedEnd, start.isFinite, parsedEnd.isFinite, start >= 0,
                  parsedEnd <= project.duration + 0.0051, min(parsedEnd, project.duration) > start else {
                zoomStart.stringValue = String(format: "%.2f", project.zooms[selected].start)
                zoomEnd.stringValue = String(format: "%.2f", project.zooms[selected].end)
                status.stringValue = "起止时间需位于视频内，且结束晚于开始；已恢复原值"
                return false
            }
            updated.zooms[selected].start = start
            updated.zooms[selected].end = min(parsedEnd, project.duration)
        }
        guard updated != project else { return true }
        edit({ $0 = updated }, refresh: false)
        window?.title = newTitle
        list.reloadData()
        return true
    }

    @objc private func undoEdit() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(project); project = previous; save(); refreshAll()
    }
    @objc private func redoEdit() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(project); project = next; save(); refreshAll()
    }
    @objc private func addItem() {
        if !isSteps {
            let start = min(max(0, video.currentTime - 0.25), max(0, project.duration - 0.6))
            edit { $0.zooms.append(DemoZoom(start: start, end: min(project.duration, start + 3), focus: .center)); selected = $0.zooms.count - 1 }
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let source = panel.url, let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            let name = "steps/\(UUID().uuidString).png"
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("steps"), withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            edit { $0.steps.append(DemoStep(imageName: name, title: "新步骤", hotspot: .center)); selected = $0.steps.count - 1 }
        } catch { showError(error) }
    }
    @objc private func removeItem() {
        if isSteps {
            guard project.steps.indices.contains(selected) else { return }
            edit { project in
                let id = project.steps.remove(at: selected).id
                for index in project.steps.indices where project.steps[index].nextStepID == id { project.steps[index].nextStepID = nil }
            }
        } else {
            guard project.zooms.indices.contains(selected) else { return }
            edit { $0.zooms.remove(at: selected) }
        }
    }
    @objc private func moveStepUp() { moveStep(-1) }
    @objc private func moveStepDown() { moveStep(1) }
    private func moveStep(_ offset: Int) {
        guard isSteps, project.steps.indices.contains(selected + offset) else { return }
        edit { project in
            project.steps.swapAt(selected, selected + offset)
            selected += offset
        }
    }

    @objc private func exportProject() {
        guard !isExporting, let window else { return }
        guard persistFields(includeTiming: true) else { return }
        save(); video.pause()
        let steps = isSteps
        let panel = NSSavePanel()
        panel.allowedContentTypes = steps ? [.html] : [.mpeg4Movie]
        panel.nameFieldStringValue = project.title + (steps ? ".html" : ".mp4")
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let destination = panel.url else { return }
            if steps {
                do {
                    try InteractiveDemoExporter.export(project: self.project, directory: self.directory, to: destination)
                    self.exportFinished(destination)
                } catch { self.showError(error) }
            } else { self.exportVideo(to: destination) }
        }
    }

    private func exportVideo(to destination: URL) {
        let renderer = DemoVideoRenderer()
        exporter = renderer
        progress.doubleValue = 0
        progress.isHidden = false
        cancelExport.isHidden = false
        status.stringValue = "正在导出 MP4 · \(String(format: "%.2f", project.videoRange().duration)) 秒…"
        let snapshot = project
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await renderer.export(project: snapshot, directory: directory, to: destination) { [weak self] value in
                    self?.progress.doubleValue = value
                    self?.status.stringValue = "正在导出 MP4 · \(Int(value * 100))%"
                }
                self.exportFinished(destination)
            } catch DemoVideoError.cancelled { self.status.stringValue = "导出已取消，原始录制已保留" }
            catch is CancellationError { self.status.stringValue = "导出已取消，原始录制已保留" }
            catch { self.showError(error) }
            self.exporter = nil
            self.exportTask = nil
            self.progress.isHidden = true
            self.cancelExport.isHidden = true
        }
    }
    @objc private func cancelExporting() { exporter?.cancel() }
    func cancelPendingExport() async { exporter?.cancel(); await exportTask?.value }
    private func exportFinished(_ url: URL) {
        status.stringValue = "已导出 \(url.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard flushPendingChanges() else { return false }
        if isExporting {
            let alert = NSAlert()
            alert.messageText = "导出仍在进行"
            alert.informativeText = "关闭窗口会取消本次导出，原始项目与编辑仍保留。"
            alert.addButton(withTitle: "继续导出")
            alert.addButton(withTitle: "取消并关闭")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            exporter?.cancel()
        }
        video.pause(); return true
    }
    func windowWillClose(_ notification: Notification) { video.pause(); save() }

    private func addInspector(_ views: NSView...) {
        for view in views {
            inspector.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        }
    }
    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }
    private func rule() -> NSView { let box = NSBox(); box.boxType = .separator; return box }
    private func flexible() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(title)
        return button
    }
    private func configureTrimButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.setAccessibilityLabel(title)
    }
    private func icon(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(); configureIcon(button, symbol: symbol, label: label, action: action); return button
    }
    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    private func showError(_ error: Error) {
        status.stringValue = "操作未完成：\(error.localizedDescription)"
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    private static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    private static func preciseTime(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
    private static func playbackTime(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
}

private final class DemoInspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}
