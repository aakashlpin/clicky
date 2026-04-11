//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AppKit
import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var multicaAgentRegistry: MulticaAgentRegistry
    @State private var emailInput: String = ""
    @State private var selectedDelegationTarget: DelegationTarget = {
        let storedKind = UserDefaults.standard.string(forKey: "ClickyDelegationTargetKind")
        let storedAgentName = UserDefaults.standard.string(forKey: "ClickyMulticaDefaultAgentName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if storedKind == "multica" && !storedAgentName.isEmpty {
            return .multica(assigneeAgentName: storedAgentName)
        }
        return .localWorkspace
    }()
    @State private var selectedMulticaDefaultAgentName: String = UserDefaults.standard.string(forKey: "ClickyMulticaDefaultAgentName") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                modelPickerRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                delegationTargetSection
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                WorkspaceInventorySectionView(workspaceInventoryStore: companionManager.workspaceInventoryStore)
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                dmFarzaButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .onAppear {
            reloadDelegationPreferencesFromUserDefaults()
            reconcileSelectedMulticaAgentName()
        }
        .task {
            await multicaAgentRegistry.refreshAvailableAgents()
        }
        .onChange(of: multicaAvailableAgentNames) { _, _ in
            reconcileSelectedMulticaAgentName()
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Flowee")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Flowee.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Flowee.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Flowee.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Flowee will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Flowee Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Flowee")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Delegation Target

    private var delegationTargetSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Delegation target")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DS.Spacing.xs) {
                delegationTargetOptionButton(for: .localWorkspace)
                delegationTargetOptionButton(for: .multica(assigneeAgentName: selectedMulticaDefaultAgentName))
            }
            .padding(DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )

            if selectedDelegationTarget.isMulticaTarget {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("Default agent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Menu {
                        if multicaAvailableAgentNames.isEmpty {
                            Text("No Multica agents available")
                        } else {
                            ForEach(multicaAvailableAgentNames, id: \.self) { multicaAgentName in
                                Button(multicaAgentName) {
                                    setSelectedMulticaDefaultAgentName(multicaAgentName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Text(multicaAgentPickerLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(multicaAvailableAgentNames.isEmpty ? DS.Colors.disabledText : DS.Colors.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(multicaAvailableAgentNames.isEmpty ? DS.Colors.disabledText : DS.Colors.textTertiary)
                        }
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(multicaAvailableAgentNames.isEmpty)
                    .pointerCursor(isEnabled: !multicaAvailableAgentNames.isEmpty)
                }
            }
        }
    }

    private func delegationTargetOptionButton(for delegationTarget: DelegationTarget) -> some View {
        let isSelected = selectedDelegationTarget.hasSameKind(as: delegationTarget)

        return Button(action: {
            setSelectedDelegationTarget(delegationTarget)
        }) {
            Text(delegationTarget.displayLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : DS.Colors.surface2)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var multicaAgentPickerLabel: String {
        if multicaAvailableAgentNames.isEmpty {
            return "No Multica agents available"
        }

        if !selectedMulticaDefaultAgentName.isEmpty {
            return selectedMulticaDefaultAgentName
        }

        return multicaAvailableAgentNames[0]
    }

    private var multicaAvailableAgentNames: [String] {
        multicaAgentRegistry.availableAgents.map(\.name)
    }

    private func setSelectedDelegationTarget(_ delegationTarget: DelegationTarget) {
        selectedDelegationTarget = delegationTarget
        companionManager.updateDelegationRoutingPreference(delegationTarget)
    }

    private func setSelectedMulticaDefaultAgentName(_ multicaAgentName: String) {
        selectedMulticaDefaultAgentName = multicaAgentName
        UserDefaults.standard.set(multicaAgentName, forKey: "ClickyMulticaDefaultAgentName")
    }

    private func reloadDelegationPreferencesFromUserDefaults() {
        let storedKind = UserDefaults.standard.string(forKey: "ClickyDelegationTargetKind")
        let storedAgentName = UserDefaults.standard.string(forKey: "ClickyMulticaDefaultAgentName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if storedKind == "multica" && !storedAgentName.isEmpty {
            selectedDelegationTarget = .multica(assigneeAgentName: storedAgentName)
        } else if storedKind == "localWorkspace" {
            selectedDelegationTarget = .localWorkspace
        } else {
            selectedDelegationTarget = companionManager.currentDelegationRoutingPreference
        }
        selectedMulticaDefaultAgentName = UserDefaults.standard.string(forKey: "ClickyMulticaDefaultAgentName") ?? ""
        companionManager.updateDelegationRoutingPreference(selectedDelegationTarget)
    }

    private func reconcileSelectedMulticaAgentName() {
        guard !multicaAvailableAgentNames.isEmpty else {
            selectedMulticaDefaultAgentName = ""
            UserDefaults.standard.removeObject(forKey: "ClickyMulticaDefaultAgentName")
            return
        }

        if multicaAvailableAgentNames.contains(selectedMulticaDefaultAgentName) {
            return
        }

        setSelectedMulticaDefaultAgentName(multicaAvailableAgentNames[0])
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM us.")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — We read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Flowee")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

private struct WorkspaceEditorDraft {
    var name: String = ""
    var path: String = ""
    var workspaceDescription: String = ""
    var isEnabled: Bool = true
}

private struct WorkspaceInventorySectionView: View {
    @ObservedObject var workspaceInventoryStore: WorkspaceInventoryStore
    @State private var isExpanded = false
    @State private var isAddingWorkspace = false
    @State private var editingWorkspaceID: UUID?
    @State private var workspaceEditorDraft = WorkspaceEditorDraft()
    @State private var workspaceEditorErrorText: String?

    var body: some View {
        VStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workspaces")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)

                        Text(summaryText)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if workspaceInventoryStore.workspaces.isEmpty {
                        Text("No workspaces added yet. Flowee will only delegate into repos you add here.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(workspaceInventoryStore.workspaces) { workspace in
                            workspaceRow(for: workspace)
                        }
                    }

                    if isAddingWorkspace {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New Workspace")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)

                            workspaceEditor
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 0.5)
                        )
                    }

                    if let workspaceEditorErrorText {
                        Text(workspaceEditorErrorText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: {
                        beginAddingWorkspace()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Add Workspace")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private var summaryText: String {
        let allowedWorkspaceCount = workspaceInventoryStore.enabledWorkspaces.count
        if allowedWorkspaceCount == 1 {
            return "1 allowed workspace"
        }
        return "\(allowedWorkspaceCount) allowed workspaces"
    }

    @ViewBuilder
    private func workspaceRow(for workspace: WorkspaceInventoryStore.WorkspaceRecord) -> some View {
        let isEditingCurrentWorkspace = editingWorkspaceID == workspace.id
        let validationStatus = workspaceInventoryStore.validationStatus(for: workspace)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)

                        if workspace.isEnabled {
                            statusBadge(text: "Allowed", color: DS.Colors.success)
                        } else {
                            statusBadge(text: "Disabled", color: DS.Colors.textTertiary)
                        }

                        if validationStatus != .valid, let warningText = validationStatus.userFacingDescription {
                            statusBadge(text: warningText, color: DS.Colors.warning)
                        }
                    }

                    Text(workspace.path)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if !workspace.workspaceDescription.isEmpty {
                        Text(workspace.workspaceDescription)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button(action: {
                        beginEditingWorkspace(workspace)
                    }) {
                        Text(isEditingCurrentWorkspace ? "Editing" : "Edit")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        removeWorkspace(workspace)
                    }) {
                        Text("Remove")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if isEditingCurrentWorkspace {
                workspaceEditor
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 0.5)
        )
    }

    private var workspaceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            workspaceEditorTextField(
                title: "Name",
                text: $workspaceEditorDraft.name,
                placeholder: "Workspace name"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                Text(workspaceEditorDraft.path)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)

                Button(action: {
                    chooseFolderForCurrentEditor()
                }) {
                    Text("Choose Folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            workspaceEditorTextField(
                title: "Description",
                text: $workspaceEditorDraft.workspaceDescription,
                placeholder: "Optional context about this codebase"
            )

            HStack {
                Text("Allowed for delegation")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Toggle("", isOn: $workspaceEditorDraft.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(DS.Colors.accent)
                    .scaleEffect(0.8)
            }

            HStack(spacing: 8) {
                Button(action: {
                    saveCurrentWorkspaceEditor()
                }) {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: {
                    cancelEditing()
                }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.top, 2)
    }

    private func workspaceEditorTextField(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
            )
    }

    private func beginAddingWorkspace() {
        workspaceEditorErrorText = nil

        guard let folderPath = selectWorkspaceFolder(currentPath: nil) else {
            return
        }

        isAddingWorkspace = true
        editingWorkspaceID = nil
        workspaceEditorDraft = WorkspaceEditorDraft(
            name: URL(fileURLWithPath: folderPath).lastPathComponent,
            path: folderPath,
            workspaceDescription: "",
            isEnabled: true
        )
    }

    private func beginEditingWorkspace(_ workspace: WorkspaceInventoryStore.WorkspaceRecord) {
        workspaceEditorErrorText = nil
        isAddingWorkspace = false
        editingWorkspaceID = workspace.id
        workspaceEditorDraft = WorkspaceEditorDraft(
            name: workspace.name,
            path: workspace.path,
            workspaceDescription: workspace.workspaceDescription,
            isEnabled: workspace.isEnabled
        )
    }

    private func cancelEditing() {
        isAddingWorkspace = false
        editingWorkspaceID = nil
        workspaceEditorDraft = WorkspaceEditorDraft()
        workspaceEditorErrorText = nil
    }

    private func chooseFolderForCurrentEditor() {
        guard let selectedFolderPath = selectWorkspaceFolder(currentPath: workspaceEditorDraft.path) else {
            return
        }

        workspaceEditorDraft.path = selectedFolderPath
        if workspaceEditorDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspaceEditorDraft.name = URL(fileURLWithPath: selectedFolderPath).lastPathComponent
        }
    }

    private func saveCurrentWorkspaceEditor() {
        workspaceEditorErrorText = nil

        if workspaceEditorDraft.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspaceEditorErrorText = "Pick a folder before saving this workspace."
            return
        }

        if let editingWorkspaceID,
           let existingWorkspace = workspaceInventoryStore.workspaces.first(where: { $0.id == editingWorkspaceID }) {
            do {
                try workspaceInventoryStore.updateWorkspace(
                    workspaceID: existingWorkspace.id,
                    name: workspaceEditorDraft.name,
                    path: workspaceEditorDraft.path,
                    workspaceDescription: workspaceEditorDraft.workspaceDescription,
                    isEnabled: workspaceEditorDraft.isEnabled,
                    lastUsedDelegationRuntimeID: existingWorkspace.lastUsedDelegationRuntimeID
                )
                cancelEditing()
            } catch {
                workspaceEditorErrorText = error.localizedDescription
            }
            return
        }

        do {
            try workspaceInventoryStore.addWorkspace(
                name: workspaceEditorDraft.name,
                path: workspaceEditorDraft.path,
                workspaceDescription: workspaceEditorDraft.workspaceDescription,
                isEnabled: workspaceEditorDraft.isEnabled
            )
            cancelEditing()
        } catch {
            workspaceEditorErrorText = error.localizedDescription
        }
    }

    private func removeWorkspace(_ workspace: WorkspaceInventoryStore.WorkspaceRecord) {
        workspaceEditorErrorText = nil
        do {
            try workspaceInventoryStore.removeWorkspace(workspaceID: workspace.id)
            if editingWorkspaceID == workspace.id {
                cancelEditing()
            }
        } catch {
            workspaceEditorErrorText = error.localizedDescription
        }
    }

    private func selectWorkspaceFolder(currentPath: String?) -> String? {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Workspace"
        openPanel.message = "Select a repo or local code workspace Flowee is allowed to delegate into."

        if let currentPath, !currentPath.isEmpty {
            openPanel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        let response = openPanel.runModal()
        guard response == .OK else { return nil }
        return openPanel.url?.path
    }
}
