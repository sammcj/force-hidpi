// BrightnessSliderView.swift
//
// Custom NSView containing a brightness slider, designed to sit as the
// `view` of an NSMenuItem. Matches the metrics used by Apple's control
// centre volume / brightness rows.

import AppKit

final class BrightnessSliderView: NSView {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let onChange: (Float) -> Void

    init(initial: Float, onChange: @escaping (Float) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        build(initial: initial)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Update the slider without triggering the change callback.
    func setValue(_ value: Float) {
        slider.floatValue = value
        valueLabel.stringValue = Self.format(value)
    }

    // MARK: - Layout

    private func build(initial: Float) {
        iconView.image = NSImage(systemSymbolName: "sun.max",
                                 accessibilityDescription: "Brightness")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor

        slider.minValue = 0
        slider.maxValue = 1
        slider.floatValue = initial
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.controlSize = .small

        valueLabel.stringValue = Self.format(initial)
        valueLabel.font = .menuBarFont(ofSize: NSFont.smallSystemFontSize)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        for v in [iconView, slider, valueLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),

            slider.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 34),
        ])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = sender.floatValue
        valueLabel.stringValue = Self.format(v)
        onChange(v)
    }

    private static func format(_ v: Float) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}
