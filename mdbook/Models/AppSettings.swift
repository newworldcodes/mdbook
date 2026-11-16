//
//  AppSettings.swift
//  mdbook
//
//  Reading and writing preferences, kept in user defaults: text size (zoom), typeface,
//  focus mode and typewriter mode.
//

import AppKit
import Observation
import SwiftUI

enum ReadingFont: String, CaseIterable, Identifiable, Sendable {
    case system, serif, rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "San Francisco"
        case .serif: "New York (Serif)"
        case .rounded: "SF Rounded"
        }
    }

    var systemDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        }
    }
}

@Observable
final class AppSettings {
    static let defaultTextSize: Double = 16
    static let textSizes: ClosedRange<Double> = 11...28

    private enum Key {
        static let textSize = "textSize"
        static let font = "readingFont"
        static let focusMode = "focusMode"
        static let typewriterMode = "typewriterMode"
    }

    var textSize: Double {
        didSet { UserDefaults.standard.set(textSize, forKey: Key.textSize) }
    }
    var font: ReadingFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: Key.font) }
    }
    /// Dims everything but the paragraph being edited.
    var focusMode: Bool {
        didSet { UserDefaults.standard.set(focusMode, forKey: Key.focusMode) }
    }
    /// Keeps the line being edited in the middle of the window.
    var typewriterMode: Bool {
        didSet { UserDefaults.standard.set(typewriterMode, forKey: Key.typewriterMode) }
    }

    init() {
        let defaults = UserDefaults.standard
        let size = defaults.double(forKey: Key.textSize)
        textSize = size == 0 ? Self.defaultTextSize : min(max(size, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        font = defaults.string(forKey: Key.font).flatMap(ReadingFont.init(rawValue:)) ?? .system
        focusMode = defaults.bool(forKey: Key.focusMode)
        typewriterMode = defaults.bool(forKey: Key.typewriterMode)
    }

    /// Multiplier for every text size in the editor and preview.
    var scale: CGFloat { CGFloat(textSize / Self.defaultTextSize) }

    var canZoomIn: Bool { textSize < Self.textSizes.upperBound }
    var canZoomOut: Bool { textSize > Self.textSizes.lowerBound }

    func zoomIn() { textSize = min(textSize + 1, Self.textSizes.upperBound) }
    func zoomOut() { textSize = max(textSize - 1, Self.textSizes.lowerBound) }
    func resetZoom() { textSize = Self.defaultTextSize }
}

extension EnvironmentValues {
    /// Scales the rendered preview's text sizes (1 = 16 pt body text).
    @Entry var markdownTextScale: CGFloat = 1
    @Entry var markdownFontDesign: Font.Design = .default
}

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.textSize, in: AppSettings.textSizes, step: 1)
                        Text("\(Int(settings.textSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Typeface", selection: $settings.font) {
                    ForEach(ReadingFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
            }
            Section("Writing") {
                Toggle("Focus mode", isOn: $settings.focusMode)
                Text("Dims everything except the paragraph you're editing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Typewriter mode", isOn: $settings.typewriterMode)
                Text("Keeps the line you're editing in the middle of the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
