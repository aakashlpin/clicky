//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a CGEvent tap so modifier-only shortcuts like ctrl + option
//  behave more like a real system-wide voice tool, and so escape can be consumed
//  when Clicky needs to stop audio playback without affecting the frontmost app.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    enum PickerNavigationEvent {
        case moveUp
        case moveDown
        case moveLeft
        case moveRight
        case confirmSelection
        case cancelSelection
    }

    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    let stopSpeechPlaybackPublisher = PassthroughSubject<Void, Never>()
    let pickerNavigationPublisher = PassthroughSubject<PickerNavigationEvent, Never>()
    private static let escapeKeyCode: UInt16 = 53
    private static let copyKeyCode: UInt16 = 8
    private static let returnKeyCode: UInt16 = 36
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    var shouldConsumeEscapeKey: (() -> Bool)?
    var shouldConsumeMarkdownTranscriptCopyShortcut: (() -> Bool)?
    var shouldConsumePickerNavigationInput: (() -> Bool)?
    let markdownTranscriptCopyPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var isConsumingEscapeKey = false
    private var isConsumingMarkdownTranscriptCopyShortcut = false
    private var isConsumingPickerNavigationInput = false
    private var consumedPickerNavigationKeyCode: UInt16?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        isConsumingEscapeKey = false
        isConsumingMarkdownTranscriptCopyShortcut = false
        isConsumingPickerNavigationInput = false
        consumedPickerNavigationKeyCode = nil

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if eventKeyCode == Self.escapeKeyCode {
            if shouldConsumePickerNavigationInput?() == true {
                if eventType == .keyDown {
                    isConsumingPickerNavigationInput = true
                    consumedPickerNavigationKeyCode = eventKeyCode
                    pickerNavigationPublisher.send(.cancelSelection)
                    return nil
                }

                if eventType == .keyUp && isConsumingPickerNavigationInput && consumedPickerNavigationKeyCode == eventKeyCode {
                    isConsumingPickerNavigationInput = false
                    consumedPickerNavigationKeyCode = nil
                    return nil
                }
            }

            if eventType == .keyDown, shouldConsumeEscapeKey?() == true {
                isConsumingEscapeKey = true
                stopSpeechPlaybackPublisher.send(())
                return nil
            }

            if eventType == .keyUp && isConsumingEscapeKey {
                isConsumingEscapeKey = false
                return nil
            }

            if eventType == .keyDown {
                stopSpeechPlaybackPublisher.send(())
            }
            return Unmanaged.passUnretained(event)
        }

        if shouldConsumePickerNavigationInput?() == true {
            switch eventKeyCode {
            case Self.upArrowKeyCode, Self.downArrowKeyCode, Self.leftArrowKeyCode, Self.rightArrowKeyCode, Self.returnKeyCode:
                if eventType == .keyDown {
                    isConsumingPickerNavigationInput = true
                    consumedPickerNavigationKeyCode = eventKeyCode

                    switch eventKeyCode {
                    case Self.upArrowKeyCode:
                        pickerNavigationPublisher.send(.moveUp)
                    case Self.downArrowKeyCode:
                        pickerNavigationPublisher.send(.moveDown)
                    case Self.leftArrowKeyCode:
                        pickerNavigationPublisher.send(.moveLeft)
                    case Self.rightArrowKeyCode:
                        pickerNavigationPublisher.send(.moveRight)
                    case Self.returnKeyCode:
                        pickerNavigationPublisher.send(.confirmSelection)
                    default:
                        break
                    }
                    return nil
                }

                if eventType == .keyUp && isConsumingPickerNavigationInput && consumedPickerNavigationKeyCode == eventKeyCode {
                    isConsumingPickerNavigationInput = false
                    consumedPickerNavigationKeyCode = nil
                    return nil
                }
            default:
                break
            }
        }

        if eventKeyCode == Self.copyKeyCode {
            let normalizedModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
            let matchesMarkdownTranscriptCopyShortcut = normalizedModifierFlags == [.control, .option]

            if eventType == .keyDown,
               matchesMarkdownTranscriptCopyShortcut,
               shouldConsumeMarkdownTranscriptCopyShortcut?() == true {
                isConsumingMarkdownTranscriptCopyShortcut = true
                markdownTranscriptCopyPublisher.send(())
                return nil
            }

            if eventType == .keyUp && isConsumingMarkdownTranscriptCopyShortcut {
                isConsumingMarkdownTranscriptCopyShortcut = false
                return nil
            }
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
