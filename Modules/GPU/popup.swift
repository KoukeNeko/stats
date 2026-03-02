//
//  popup.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private let processHeight: CGFloat = 22
    private var processes: ProcessesView? = nil
    private var processesView: NSView? = nil
    private var processesHeightConstraint: NSLayoutConstraint? = nil
    private var processesInitialized: Bool = false

    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(ModuleType.GPU.stringValue)_processes", defaultValue: 8)
    }
    private var processesHeight: CGFloat {
        (self.processHeight * CGFloat(self.numberOfProcesses)) + (self.numberOfProcesses == 0 ? 0 : Constants.Popup.separatorHeight + 22)
    }
    private var showTemperatureInMainState: Bool {
        Store.shared.bool(key: "\(ModuleType.GPU.stringValue)_showTemperatureInMain", defaultValue: false)
    }
    private var showPowerInMainState: Bool {
        Store.shared.bool(key: "\(ModuleType.GPU.stringValue)_showPowerInMain", defaultValue: false)
    }
    private var showPowerInDetailsState: Bool {
        Store.shared.bool(key: "\(ModuleType.GPU.stringValue)_showPowerInDetails", defaultValue: false)
    }

    public init() {
        super.init(ModuleType.GPU, frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: 0))

        self.orientation = .vertical
        self.spacing = Constants.Popup.margins

        self.addArrangedSubview(self.initProcesses())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func disappear() {
        self.processes?.setLock(false)
    }

    internal func infoCallback(_ value: GPUs) {
        if self.gpuViews().count != value.list.count {
            self.gpuViews().forEach { $0.removeFromSuperview() }
        }

        value.list.reversed().forEach { (gpu: GPU_Info) in
            if let view = self.gpuViews().first(where: { $0.value.id == gpu.id }) {
                view.update(gpu)
                view.setMainMetricVisibility(
                    showTemperature: self.showTemperatureInMainState,
                    showPower: self.showPowerInMainState
                )
                view.setDetailsPowerVisibility(showPower: self.showPowerInDetailsState)
            } else {
                let view = GPUView(
                    width: self.frame.width,
                    gpu: gpu,
                    showTemperatureInMain: self.showTemperatureInMainState,
                    showPowerInMain: self.showPowerInMainState,
                    showPowerInDetails: self.showPowerInDetailsState,
                    detailsToggle: { [weak self] in
                        self?.updateProcessesVisibility()
                    },
                    callback: self.recalculateHeight
                )
                self.insertArrangedSubview(view, at: self.gpuInsertIndex())
            }
        }

        self.updateProcessesVisibility()
        self.recalculateHeight()
    }

    internal func processCallback(_ list: [TopProcess]?) {
        guard let list else { return }

        DispatchQueue.main.async(execute: {
            if !(self.window?.isVisible ?? false) && self.processesInitialized {
                return
            }

            self.processes?.clear("-")
            for i in 0..<min(list.count, self.processes?.count ?? 0) {
                let process = list[i]
                let value = process.usage >= 100 ? "\(Int(process.usage.rounded()))%" : String(format: "%.1f%%", process.usage)
                self.processes?.set(i, process, [value])
            }

            self.processesInitialized = true
        })
    }

    internal func numberOfProcessesUpdated() {
        if self.processes?.count == self.numberOfProcesses { return }

        DispatchQueue.main.async(execute: {
            self.processesView?.removeFromSuperview()
            self.processesView = nil
            self.processes = nil
            self.processesHeightConstraint = nil
            self.addArrangedSubview(self.initProcesses())
            self.updateProcessesVisibility()
            self.processesInitialized = false
            self.recalculateHeight()
        })
    }

    private func gpuViews() -> [GPUView] {
        self.arrangedSubviews.compactMap { $0 as? GPUView }
    }

    private func gpuInsertIndex() -> Int {
        guard let processView = self.processesView,
              let index = self.arrangedSubviews.firstIndex(of: processView) else {
            return self.arrangedSubviews.count
        }
        return index
    }

    private func initProcesses() -> NSView {
        let initialHeight: CGFloat = self.numberOfProcesses == 0 ? 0 : self.processesHeight
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: initialHeight))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.masksToBounds = true

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: initialHeight)
        heightConstraint.isActive = true
        self.processesHeightConstraint = heightConstraint

        if self.numberOfProcesses > 0 {
            let separator = separatorView(
                localizedString("Top GPU processes"),
                origin: NSPoint(x: 0, y: self.processesHeight-Constants.Popup.separatorHeight),
                width: self.frame.width
            )
            let container: ProcessesView = ProcessesView(
                frame: NSRect(x: 0, y: 0, width: self.frame.width, height: separator.frame.origin.y),
                values: [(localizedString("GPU usage"), NSColor.systemBlue)],
                n: self.numberOfProcesses
            )
            self.processes = container
            view.addSubview(separator)
            view.addSubview(container)
        } else {
            self.processes = nil
        }

        self.processesView = view
        return view
    }

    private func updateProcessesVisibility() {
        let visible = self.numberOfProcesses > 0 && self.gpuViews().contains(where: { $0.isDetailsVisible })
        self.processesView?.isHidden = !visible
        self.processesHeightConstraint?.constant = visible ? self.processesHeight : 0
        self.recalculateHeight()
    }

    private func refreshMainMetricsVisibility() {
        self.gpuViews().forEach {
            $0.setMainMetricVisibility(
                showTemperature: self.showTemperatureInMainState,
                showPower: self.showPowerInMainState
            )
        }
        self.recalculateHeight()
    }

    private func refreshDetailsPowerVisibility() {
        self.gpuViews().forEach {
            $0.setDetailsPowerVisibility(showPower: self.showPowerInDetailsState)
        }
        self.recalculateHeight()
    }

    private func recalculateHeight() {
        let h = self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +) - self.spacing
        if self.frame.size.height != h && h >= 0 {
            self.setFrameSize(NSSize(width: self.frame.width, height: h))
            self.sizeCallback?(self.frame.size)
        }
    }

    // MARK: - Settings

    public override func settings() -> NSView? {
        let view = SettingsContainerView()

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Show temperature on the main section"), component: switchView(
                action: #selector(self.toggleShowTemperatureInMain),
                state: self.showTemperatureInMainState
            )),
            PreferencesRow(localizedString("Show power on the main section"), component: switchView(
                action: #selector(self.toggleShowPowerInMain),
                state: self.showPowerInMainState
            )),
            PreferencesRow(localizedString("Show power in details"), component: switchView(
                action: #selector(self.toggleShowPowerInDetails),
                state: self.showPowerInDetailsState
            ))
        ]))

        return view
    }

    @objc private func toggleShowTemperatureInMain(_ sender: NSControl) {
        Store.shared.set(key: "\(ModuleType.GPU.stringValue)_showTemperatureInMain", value: controlState(sender))
        self.refreshMainMetricsVisibility()
    }

    @objc private func toggleShowPowerInMain(_ sender: NSControl) {
        Store.shared.set(key: "\(ModuleType.GPU.stringValue)_showPowerInMain", value: controlState(sender))
        self.refreshMainMetricsVisibility()
    }

    @objc private func toggleShowPowerInDetails(_ sender: NSControl) {
        Store.shared.set(key: "\(ModuleType.GPU.stringValue)_showPowerInDetails", value: controlState(sender))
        self.refreshDetailsPowerVisibility()
    }
}

private class GPUView: NSStackView {
    private enum Stat {
        static let temperature = "GPU temperature"
        static let utilization = "GPU utilization"
        static let render = "Render utilization"
        static let tiler = "Tiler utilization"
        static let memory = "Memory utilization"
        static let power = "GPU power"
        static let encode = "Encode utilization"
        static let decode = "Decode utilization"
        static let blit = "Blit utilization"
        static let compute = "Compute utilization"
    }

    public var value: GPU_Info
    public var isDetailsVisible: Bool { self.detailsState }

    private var detailsView: GPUDetails
    private let circleSize: CGFloat = 50
    private let chartSize: CGFloat = 60
    private let statsHeight: CGFloat

    private var showTemperatureInMain: Bool
    private var showPowerInMain: Bool
    private var showPowerInDetails: Bool

    private var detailsState: Bool {
        get { Store.shared.bool(key: "\(ModuleType.GPU.stringValue)_\(self.value.id)_details", defaultValue: false) }
        set { Store.shared.set(key: "\(ModuleType.GPU.stringValue)_\(self.value.id)_details", value: newValue) }
    }

    private var stateView: NSView? = nil
    private var circleRow: NSStackView? = nil
    private var chartRow: NSStackView? = nil
    private var circlesByID: [String: HalfCircleGraphView] = [:]
    private var chartsByID: [String: LineChartView] = [:]

    private var maxObservedPower: Double = 1

    private var detailsToggle: (() -> Void)?
    public var sizeCallback: (() -> Void)

    open override var intrinsicContentSize: CGSize {
        CGSize(width: self.bounds.width, height: self.bounds.height)
    }

    public init(
        width: CGFloat,
        gpu: GPU_Info,
        showTemperatureInMain: Bool,
        showPowerInMain: Bool,
        showPowerInDetails: Bool,
        detailsToggle: (() -> Void)? = nil,
        callback: @escaping (() -> Void)
    ) {
        self.value = gpu
        self.detailsView = GPUDetails(width: width, value: gpu, showPower: showPowerInDetails)
        self.showTemperatureInMain = showTemperatureInMain
        self.showPowerInMain = showPowerInMain
        self.showPowerInDetails = showPowerInDetails
        self.statsHeight = (self.circleSize + 20) + (self.chartSize + 20)
        self.detailsToggle = detailsToggle
        self.sizeCallback = callback

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fillProportionally
        self.spacing = 0
        self.wantsLayer = true
        self.layer?.cornerRadius = 2

        self.addArrangedSubview(self.title())
        self.addArrangedSubview(self.stats())
        self.addArrangedSubview(NSView())

        if self.detailsState {
            self.insertArrangedSubview(self.detailsView, at: 1)
        }

        self.syncStats(self.value)

        let h = self.arrangedSubviews.map({ $0.bounds.height }).reduce(0, +)
        self.setFrameSize(NSSize(width: self.frame.width, height: h))
        self.sizeCallback()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = (isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }

    public func setMainMetricVisibility(showTemperature: Bool, showPower: Bool) {
        self.showTemperatureInMain = showTemperature
        self.showPowerInMain = showPower
        self.syncStats(self.value)
    }

    public func setDetailsPowerVisibility(showPower: Bool) {
        guard self.showPowerInDetails != showPower else { return }

        self.showPowerInDetails = showPower
        let wasVisible = self.detailsState
        self.detailsView = GPUDetails(width: self.frame.width, value: self.value, showPower: self.showPowerInDetails)

        guard wasVisible else { return }

        if let view = self.arrangedSubviews.first(where: { $0 is GPUDetails }) {
            view.removeFromSuperview()
        }
        self.insertArrangedSubview(self.detailsView, at: 1)
        self.setFrameSize(NSSize(
            width: self.frame.width,
            height: self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +)
        ))
        self.sizeCallback()
        self.detailsToggle?()
    }

    private func title() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: 24))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true

        let width: CGFloat = self.value.model.widthOfString(usingFont: NSFont.systemFont(ofSize: 13, weight: .regular)) + 16
        let labelView: NSTextField = TextView(frame: NSRect(x: 0, y: (view.frame.height-16)/2, width: width - 8, height: 16))
        labelView.alignment = .center
        labelView.textColor = .secondaryLabelColor
        labelView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        labelView.stringValue = self.value.model

        let stateView: NSView = NSView(frame: NSRect(x: width - 8, y: (view.frame.height-7)/2, width: 6, height: 6))
        stateView.wantsLayer = true
        stateView.layer?.backgroundColor = (self.value.state ? NSColor.systemGreen : NSColor.systemRed).cgColor
        stateView.toolTip = localizedString("GPU \(self.value.state ? "enabled" : "disabled")")
        stateView.layer?.cornerRadius = 4

        let details = localizedString("Details").uppercased()
        let w = details.widthOfString(usingFont: NSFont.systemFont(ofSize: 9, weight: .regular)) + 8
        let button = NSButtonWithPadding()
        button.frame = CGRect(x: view.frame.width - w, y: 2, width: w, height: view.frame.height-2)
        button.verticalPadding = 9
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.action = #selector(self.showDetails)
        button.target = self
        button.toolTip = localizedString("Details")
        button.title = details
        button.font = NSFont.systemFont(ofSize: 9, weight: .regular)

        view.addSubview(labelView)
        view.addSubview(stateView)
        view.addSubview(button)
        self.stateView = stateView

        return view
    }

    private func stats() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.statsHeight))
        let container: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.statsHeight))
        container.orientation = .vertical
        container.spacing = 0

        let circles: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.circleSize + 20))
        circles.orientation = .horizontal
        circles.distribution = .fillEqually
        circles.alignment = .bottom
        circles.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 0, right: 10)
        circles.heightAnchor.constraint(equalToConstant: circles.bounds.height).isActive = true
        self.circleRow = circles

        let charts: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.frame.width, height: self.chartSize + 20))
        charts.orientation = .horizontal
        charts.distribution = .fillEqually
        charts.spacing = Constants.Popup.margins
        charts.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.margins,
            left: Constants.Popup.margins,
            bottom: Constants.Popup.margins,
            right: Constants.Popup.margins
        )
        charts.heightAnchor.constraint(equalToConstant: charts.bounds.height).isActive = true
        self.chartRow = charts

        container.addArrangedSubview(circles)
        container.addArrangedSubview(charts)

        view.addSubview(container)

        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        container.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true

        return view
    }

    private func desiredStats(for gpu: GPU_Info) -> [(String, Double)] {
        var stats: [(String, Double)] = []

        if let value = gpu.utilization {
            stats.append((Stat.utilization, value))
        }
        if let value = gpu.renderUtilization {
            stats.append((Stat.render, value))
        }
        if let value = gpu.tilerUtilization {
            stats.append((Stat.tiler, value))
        }
        if self.showTemperatureInMain, let value = gpu.temperature {
            stats.append((Stat.temperature, value))
        }
        if self.showPowerInMain, let value = gpu.power {
            stats.append((Stat.power, value))
        }

        return stats
    }

    private func circle(for id: String) -> HalfCircleGraphView {
        if let view = self.circlesByID[id] {
            return view
        }
        let circle = HalfCircleGraphView(frame: NSRect(x: 0, y: 0, width: self.circleSize, height: self.circleSize))
        circle.id = id
        circle.toolTip = localizedString(id)
        self.circlesByID[id] = circle
        self.circleRow?.addArrangedSubview(circle)
        return circle
    }

    private func chart(for id: String) -> LineChartView {
        if let view = self.chartsByID[id] {
            return view
        }
        let chart = LineChartView(frame: NSRect(x: 0, y: 0, width: 100, height: self.chartSize), num: 120)
        chart.isTooltipEnabled = false
        chart.wantsLayer = true
        chart.layer?.backgroundColor = NSColor.lightGray.withAlphaComponent(0.1).cgColor
        chart.layer?.cornerRadius = 3
        chart.id = id
        chart.toolTip = localizedString(id)
        self.chartsByID[id] = chart
        self.chartRow?.addArrangedSubview(chart)
        return chart
    }

    private func removeStat(_ id: String) {
        if let circle = self.circlesByID[id] {
            circle.removeFromSuperview()
            self.circlesByID.removeValue(forKey: id)
        }
        if let chart = self.chartsByID[id] {
            chart.removeFromSuperview()
            self.chartsByID.removeValue(forKey: id)
        }
    }

    private func syncStats(_ gpu: GPU_Info) {
        let stats = self.desiredStats(for: gpu)
        let expected = Set(stats.map { $0.0 })
        let existing = Set(self.circlesByID.keys)

        for id in existing.subtracting(expected) {
            self.removeStat(id)
        }

        for (id, value) in stats {
            self.updateStat(id: id, value: value, gpu: gpu)
        }

        self.addHistory(gpu)
    }

    private func updateStat(id: String, value: Double, gpu: GPU_Info) {
        let circle = self.circle(for: id)
        let chart = self.chart(for: id)

        switch id {
        case Stat.temperature:
            circle.setValue(value)
            circle.setText(temperature(value))
            circle.toolTip = "\(localizedString(id)): \(temperature(value))"
            chart.suffix = UnitTemperature.current.symbol
        case Stat.power:
            self.maxObservedPower = max(self.maxObservedPower, value)
            let ratio = value / max(self.maxObservedPower, 1)
            circle.setValue(ratio)
            circle.setText(String(format: "%.1fW", value))
            circle.toolTip = "\(localizedString(id)): \(String(format: "%.2f", value))W"
            chart.suffix = "W"
        case Stat.memory:
            let percent = Int((value * 100).rounded())
            circle.setValue(value)
            circle.setText("\(percent)%")
            if let used = gpu.memoryUsed, let total = gpu.memoryTotal {
                let usedString = Units(bytes: used).getReadableMemory(style: .memory)
                let totalString = Units(bytes: total).getReadableMemory(style: .memory)
                circle.toolTip = "\(localizedString(id)): \(usedString)/\(totalString) (\(percent)%)"
            } else {
                circle.toolTip = "\(localizedString(id)): \(percent)%"
            }
        default:
            let percent = Int((value * 100).rounded())
            circle.setValue(value)
            circle.setText("\(percent)%")
            circle.toolTip = "\(localizedString(id)): \(percent)%"
        }
    }

    private func addHistory(_ gpu: GPU_Info) {
        if let value = gpu.temperature, let chart = self.chartsByID[Stat.temperature] {
            chart.addValue(self.convertTemperatureValue(value))
        }
        if let value = gpu.utilization, let chart = self.chartsByID[Stat.utilization] {
            chart.addValue(value)
        }
        if let value = gpu.renderUtilization, let chart = self.chartsByID[Stat.render] {
            chart.addValue(value)
        }
        if let value = gpu.tilerUtilization, let chart = self.chartsByID[Stat.tiler] {
            chart.addValue(value)
        }
        if let value = gpu.power, let chart = self.chartsByID[Stat.power] {
            chart.addValue(value)
        }
    }

    private func convertTemperatureValue(_ value: Double) -> Double {
        let measurement = Measurement(value: value, unit: UnitTemperature.celsius)
        return measurement.converted(to: UnitTemperature.current).value
    }

    public func update(_ gpu: GPU_Info) {
        self.value = gpu
        self.detailsView.update(gpu)

        if self.window?.isVisible ?? false {
            self.stateView?.layer?.backgroundColor = (gpu.state ? NSColor.systemGreen : NSColor.systemRed).cgColor
            self.stateView?.toolTip = localizedString("GPU \(gpu.state ? "enabled" : "disabled")")
        }

        self.syncStats(gpu)
    }

    @objc private func showDetails() {
        self.detailsState = !self.detailsState

        if let view = self.arrangedSubviews.first(where: { $0 is GPUDetails }) {
            view.removeFromSuperview()
        } else {
            self.insertArrangedSubview(self.detailsView, at: 1)
        }

        self.setFrameSize(NSSize(
            width: self.frame.width,
            height: self.arrangedSubviews.map({ $0.bounds.height + self.spacing }).reduce(0, +)
        ))
        self.sizeCallback()
        self.detailsToggle?()
    }
}

private class GPUDetails: NSView {
    private var status: NSTextField? = nil
    private var fanSpeed: NSTextField? = nil
    private var coreClock: NSTextField? = nil
    private var memoryClock: NSTextField? = nil
    private var temperature: NSTextField? = nil
    private var power: NSTextField? = nil
    private var utilization: NSTextField? = nil
    private var renderUtilization: NSTextField? = nil
    private var tilerUtilization: NSTextField? = nil
    private var encodeUtilization: NSTextField? = nil
    private var decodeUtilization: NSTextField? = nil
    private var blitUtilization: NSTextField? = nil
    private var computeUtilization: NSTextField? = nil
    private var memoryUsed: NSTextField? = nil
    private var memoryAllocated: NSTextField? = nil
    private var memoryTotal: NSTextField? = nil
    private var memoryUtilization: NSTextField? = nil
    private var throttling: NSTextField? = nil

    open override var intrinsicContentSize: CGSize {
        CGSize(width: self.bounds.width, height: self.bounds.height)
    }

    init(width: CGFloat, value: GPU_Info, showPower: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        let grid: NSGridView = NSGridView(frame: NSRect(
            x: Constants.Popup.margins,
            y: Constants.Popup.margins,
            width: self.frame.width - (Constants.Popup.margins * 2),
            height: 0
        ))
        grid.yPlacement = .center
        grid.xPlacement = .leading
        grid.rowSpacing = 0
        grid.columnSpacing = 0

        var count: CGFloat = 0

        let addRow: (String, String) -> [NSTextField] = { key, val in
            let row = self.keyValueRow(key, val)
            grid.addRow(with: row)
            count += 1
            return row
        }

        if let value = value.vendor {
            _ = addRow("\(localizedString("Vendor")):", value)
        }

        _ = addRow("\(localizedString("Model")):", value.model)

        if let value = value.cores {
            _ = addRow("\(localizedString("Cores")):", "\(value)")
        }

        let state = value.state ? localizedString("Active") : localizedString("Non active")
        self.status = addRow("\(localizedString("Status")):", state).last

        if let value = value.fanSpeed {
            self.fanSpeed = addRow("\(localizedString("Fan speed")):", "\(value)%").last
        }
        if let value = value.coreClock {
            self.coreClock = addRow("\(localizedString("Core clock")):", "\(value)MHz").last
        }
        if let value = value.memoryClock {
            self.memoryClock = addRow("\(localizedString("Memory clock")):", "\(value)MHz").last
        }

        if let value = value.temperature {
            self.temperature = addRow("\(localizedString("Temperature")):", Kit.temperature(Double(value))).last
        }
        if showPower, let value = value.power {
            self.power = addRow("\(localizedString("Power")):", String(format: "%.2fW", value)).last
        }
        if let value = value.utilization {
            self.utilization = addRow("\(localizedString("Utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.renderUtilization {
            self.renderUtilization = addRow("\(localizedString("Render utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.tilerUtilization {
            self.tilerUtilization = addRow("\(localizedString("Tiler utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.encodeUtilization {
            self.encodeUtilization = addRow("\(localizedString("Encode utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.decodeUtilization {
            self.decodeUtilization = addRow("\(localizedString("Decode utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.blitUtilization {
            self.blitUtilization = addRow("\(localizedString("Blit utilization")):", "\(Int(value*100))%").last
        }
        if let value = value.computeUtilization {
            self.computeUtilization = addRow("\(localizedString("Compute utilization")):", "\(Int(value*100))%").last
        }

        if let value = value.memoryUsed {
            self.memoryUsed = addRow("\(localizedString("Memory used")):", Units(bytes: value).getReadableMemory(style: .memory)).last
        }
        if let value = value.memoryAllocated {
            self.memoryAllocated = addRow("\(localizedString("Memory allocated")):", Units(bytes: value).getReadableMemory(style: .memory)).last
        }
        if let value = value.memoryTotal {
            self.memoryTotal = addRow("\(localizedString("Memory total")):", Units(bytes: value).getReadableMemory(style: .memory)).last
        }
        if let value = value.memoryUtilization {
            self.memoryUtilization = addRow("\(localizedString("Memory utilization")):", "\(Int(value*100))%").last
        }

        if let value = value.throttling {
            self.throttling = addRow("\(localizedString("Throttling")):", value ? localizedString("Yes") : localizedString("No")).last
        }

        self.setFrameSize(NSSize(width: self.frame.width, height: (16 * count) + Constants.Popup.margins))
        self.heightAnchor.constraint(equalToConstant: self.frame.height).isActive = true
        grid.setFrameSize(NSSize(width: grid.frame.width, height: self.frame.height - Constants.Popup.margins))
        grid.heightAnchor.constraint(equalToConstant: self.frame.height - Constants.Popup.margins).isActive = true
        self.addSubview(grid)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func keyValueRow(_ key: String, _ value: String) -> [NSTextField] {
        [
            LabelField(frame: NSRect(x: 0, y: 0, width: 0, height: 16), key),
            ValueField(frame: NSRect(x: 0, y: 0, width: 0, height: 16), value)
        ]
    }

    public func update(_ gpu: GPU_Info) {
        self.status?.stringValue = gpu.state ? localizedString("Active") : localizedString("Non active")

        if let value = gpu.fanSpeed {
            self.fanSpeed?.stringValue = "\(value)%"
        }
        if let value = gpu.coreClock {
            self.coreClock?.stringValue = "\(value)MHz"
        }
        if let value = gpu.memoryClock {
            self.memoryClock?.stringValue = "\(value)MHz"
        }

        if let value = gpu.temperature {
            self.temperature?.stringValue = Kit.temperature(Double(value))
        }
        if let value = gpu.power {
            self.power?.stringValue = String(format: "%.2fW", value)
        }
        if let value = gpu.utilization {
            self.utilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.renderUtilization {
            self.renderUtilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.tilerUtilization {
            self.tilerUtilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.encodeUtilization {
            self.encodeUtilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.decodeUtilization {
            self.decodeUtilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.blitUtilization {
            self.blitUtilization?.stringValue = "\(Int(value*100))%"
        }
        if let value = gpu.computeUtilization {
            self.computeUtilization?.stringValue = "\(Int(value*100))%"
        }

        if let value = gpu.memoryUsed {
            self.memoryUsed?.stringValue = Units(bytes: value).getReadableMemory(style: .memory)
        }
        if let value = gpu.memoryAllocated {
            self.memoryAllocated?.stringValue = Units(bytes: value).getReadableMemory(style: .memory)
        }
        if let value = gpu.memoryTotal {
            self.memoryTotal?.stringValue = Units(bytes: value).getReadableMemory(style: .memory)
        }
        if let value = gpu.memoryUtilization {
            self.memoryUtilization?.stringValue = "\(Int(value*100))%"
        }

        if let value = gpu.throttling {
            self.throttling?.stringValue = value ? localizedString("Yes") : localizedString("No")
        }
    }
}
