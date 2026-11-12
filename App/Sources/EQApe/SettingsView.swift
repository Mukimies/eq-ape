import AppKit
import EQApeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        let uids = app.settings.profiles.keys.sorted {
                            (app.settings.profiles[$0]?.deviceName ?? $0).localizedCaseInsensitiveCompare(app.settings.profiles[$1]?.deviceName ?? $1) == .orderedAscending
                        }
                        if uids.isEmpty {
                            Text("No devices yet. Choose a config file for the current output device to create its profile.")
                                .foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(uids, id: \.self) { uid in
                            if let p = app.settings.profiles[uid] {
                                ProfileRow(app: app, uid: uid, profile: p)
                                if uid != uids.last { Divider().padding(.vertical, 8) }
                            }
                        }
                        if let uid = app.status.deviceUID, app.settings.profiles[uid] == nil {
                            Divider().padding(.vertical, 8)
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(app.status.deviceName ?? uid).font(.headline)
                                    Text("Current output, no profile: audio is left untouched").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Choose Config File…") { app.chooseConfig(forUID: uid) }
                                    .accessibilityIdentifier("settings.current.choose")
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Output devices").font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Launch EQ Ape at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                            .accessibilityIdentifier("settings.launchAtLogin")
                        HStack {
                            Button("Open Settings Folder") { app.openSettingsFolder() }.accessibilityIdentifier("settings.openSettingsFolder")
                            Button("Open Editor Backups") { app.openBackupsFolder() }.accessibilityIdentifier("settings.openBackups")
                        }
                        if app.controller.settingsReadOnly {
                            Text("Development run (--no-engine): changes here are not saved to settings.json.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let e = app.status.settingsError {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("General").font(.headline)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EQ Ape needs the macOS audio-capture permission to receive the sound other apps send to your output device (a Core Audio process tap). It is not a microphone recording, and audio never leaves your Mac.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("macOS asks the first time the engine starts. Answer the prompt promptly: while it is open, no app on the Mac can start new audio. If you declined, allow EQ Ape in System Settings, then choose Reload in the menu.")
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                        Button("Open Privacy & Security Settings…") { app.openPrivacySettings() }.accessibilityIdentifier("settings.privacy")
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Audio-capture permission").font(.headline)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 620)
    }
}

struct ProfileRow: View {
    @ObservedObject var app: AppModel
    let uid: String
    let profile: DeviceProfile
    /// Accessibility identifier stem: "settings.profile.<device UID>".
    var pid: String { "settings.profile.\(uid)" }

    func update(_ change: (inout DeviceProfile) -> Void) {
        var p = profile
        change(&p)
        app.controller.setProfile(uid: uid, p)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(profile.deviceName.isEmpty ? uid : profile.deviceName).font(.headline)
                if uid == app.status.deviceUID {
                    Text("current output").font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                } else if app.currentDevices[uid] == nil {
                    Text("not connected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: { v in update { $0.enabled = v } }))
                    .toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("EQ enabled for \(profile.deviceName)")
                    .accessibilityIdentifier("\(pid).enabled")
            }
            HStack(spacing: 8) {
                Text("Config").foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                Text(profile.configPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "none")
                    .lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Choose…") { app.chooseConfig(forUID: uid) }.accessibilityIdentifier("\(pid).choose")
                Button("Edit…") { if let p = profile.configPath { WindowManager.shared.openEditor(path: p) } }
                    .disabled(profile.configPath == nil)
                    .accessibilityIdentifier("\(pid).edit")
            }
            HStack(spacing: 8) {
                Text("Anti-clip").foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                Toggle("Automatic anti-clipping gain", isOn: Binding(get: { profile.headroomEnabled }, set: { v in update { $0.headroomEnabled = v } }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("\(pid).antiClip")
                    .help("Lowers the level by the largest boost of the whole EQ (every filter, high-pass included) plus the headroom, so a steady tone at full scale stays below 0 dBFS. It does not make clipping impossible: the EQ's phase shifts can raise short peaks of already loud music by a few dB. The clip light shows when that happens.")
                Spacer()
                Text("Headroom").foregroundStyle(.secondary)
                Stepper(value: Binding(get: { profile.headroomDB }, set: { v in update { $0.headroomDB = (v * 10).rounded() / 10 } }),
                        in: 0...12, step: 0.5) {
                    Text(String(format: "%.1f dB", profile.headroomDB)).font(.system(size: 12).monospacedDigit()).frame(width: 54, alignment: .trailing)
                }
                .disabled(!profile.headroomEnabled)
                .accessibilityLabel("Headroom")
                .accessibilityIdentifier("\(pid).headroom")
                .accessibilityValue(String(format: "%.1f dB", profile.headroomDB))
                Button("Remove") { app.controller.setProfile(uid: uid, nil) }
                    .help("Forget this device: its audio is left untouched")
                    .accessibilityIdentifier("\(pid).remove")
            }
        }
    }
}

struct FirstRunView: View {
    @ObservedObject var app: AppModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "slider.vertical.3").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Welcome to EQ Ape").font(.title2.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("macOS will ask for the audio-capture permission when the EQ starts: answer it right away, because while it is open no app can start new audio.", systemImage: "1.circle")
                Label("Choose your Equalizer APO config file (for example a REW export); you can edit it later in the editor.", systemImage: "2.circle")
                Label("Your real output device stays the selected macOS output, so volume keys and switching outputs keep working; EQ Ape processes its sound in place.", systemImage: "3.circle")
            }
            .fixedSize(horizontal: false, vertical: true)
            .labelStyle(.titleAndIcon)
            HStack {
                Spacer()
                Button("Not Now") { FirstRun.completed = true; close() }.accessibilityIdentifier("firstRun.notNow")
                Button("Choose Config File…") {
                    FirstRun.completed = true
                    close()
                    app.chooseConfig()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("firstRun.choose")
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
