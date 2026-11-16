import SwiftUI
import AppKit

struct BackupView: View {
    @ObservedObject var m: DeviceManager
    @State private var volumes: [VolumeInfo] = []
    @State private var freeBytes: Int64? = nil
    @State private var restoreTarget: BackupEntry?

    private var usedOnDevice: Int64 { max(0, m.details.totalDiskBytes - m.details.freeDiskBytes) }
    private var lowSpace: Bool { if let f = freeBytes, usedOnDevice > 0, m.backups.isEmpty { return f < usedOnDevice }; return false }
    private var folderName: String { "\(m.deviceKind) Backups" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    IconTile(symbol: "clock.arrow.circlepath", color: .orange, size: 46)
                        .shadow(color: Color.orange.opacity(0.4), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Backups").font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("BETA").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(.orange)
                        }
                        Text("Save a full copy of \(m.deviceName) — messages, app data, settings and the photos stored on it.")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where backups are kept").font(.headline)
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.backupFolder.lastPathComponent).font(.system(size: 13, weight: .semibold))
                                Text((m.backupFolder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Change…") { choose() }.disabled(m.backupRunning)
                        }
                        if !volumes.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(volumes) { v in
                                    Button {
                                        m.backupFolder = v.url.appendingPathComponent(folderName)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "externaldrive.fill").font(.system(size: 11))
                                            Text(v.name).font(.system(size: 12, weight: .medium))
                                            Text(v.readOnly ? "read-only" : "\(Fmt.bytes(v.free)) free").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(v.readOnly || v.isFAT || m.backupRunning)
                                    .opacity(v.readOnly || v.isFAT ? 0.5 : 1)
                                    .help(v.isFAT ? "FAT32 drives can't hold backups (files over 4 GB). Use exFAT or APFS." : v.format)
                                }
                            }
                        }
                        if let free = freeBytes {
                            Label(lowSpace ? "This disk has \(Fmt.bytes(free)) free, but the \(m.deviceKind) holds \(Fmt.bytes(usedOnDevice)). A first backup may not fit."
                                           : "\(Fmt.bytes(free)) free on this disk.",
                                  systemImage: lowSpace ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(lowSpace ? Color.orange : Color.green)
                        }
                    }
                }

                Card {
                    if m.backupRunning {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(m.backupStopping ? "Stopping…" : "Backing up \(m.deviceName)").font(.headline)
                                Spacer()
                                if let p = m.backupPercent {
                                    Text("\(Int(p * 100))%").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                                        .contentTransition(.numericText())
                                }
                            }
                            if let p = m.backupPercent { GlowProgressBar(fraction: p) }
                            else { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
                            HStack {
                                Text(m.backupPhase).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Stop") { m.stopBackup() }.buttonStyle(SoftButtonStyle()).disabled(m.backupStopping)
                            }
                            Text("Keep the \(m.deviceKind) connected and unlocked. The first backup can take a long time; later ones only copy what changed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .transition(.opacity)
                    } else {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.backups.isEmpty ? "No backup in this folder yet" : "Ready to update the backup").font(.headline)
                                if !m.backupMessage.isEmpty {
                                    Label(m.backupMessage, systemImage: m.backupFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .font(.callout).foregroundStyle(m.backupFailed ? Color.orange : Color.green)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Nothing on the \(m.deviceKind) is changed or removed.").font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { m.startBackup() } label: { Label("Back Up Now", systemImage: "arrow.down.circle.fill") }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(m.isExporting || m.afcBusy || m.tools?.backup == nil)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: m.backupRunning)

                if !m.backups.isEmpty {
                    Text("Backups in this folder").font(.headline).padding(.top, 4)
                    ForEach(m.backups) { b in
                        Card {
                            HStack(spacing: 12) {
                                IconTile(symbol: b.deviceName.lowercased().contains("ipad") ? "ipad" : "iphone", color: .blue, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.deviceName).font(.system(size: 13, weight: .semibold))
                                    Text([b.date.map { Fmt.date.string(from: $0) } ?? "Date unknown",
                                          b.iosVersion.isEmpty ? nil : "iOS \(b.iosVersion)",
                                          b.encrypted ? "Encrypted" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if b.encrypted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.path]) }
                                    .buttonStyle(SoftButtonStyle())
                                Button("Restore…") { restoreTarget = b }
                                    .buttonStyle(SoftButtonStyle())
                                    .disabled(m.backupRunning || m.isExporting || m.afcBusy || m.tools?.backup == nil || b.date == nil)
                            }
                        }
                    }
                }

                Text("Backups use the same format as Finder. Restore puts a backup back onto the connected device and has not yet been verified on a real device. If the device has backup encryption turned on, the backup is protected with that password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(m.deviceName)
        .navigationSubtitle("")
        .sheet(item: $restoreTarget) { RestoreSheet(m: m, entry: $0) }
        .onAppear { volumes = VolumeInfo.external(); freeBytes = VolumeInfo.freeSpace(at: m.backupFolder); m.refreshBackups() }
        .onChange(of: m.backupFolder) { freeBytes = VolumeInfo.freeSpace(at: $0) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumes = VolumeInfo.external() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumes = VolumeInfo.external() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for backups"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { m.backupFolder = url }
    }
}

/// The confirmation shown before a restore. Nothing starts until the user ticks the box and types RESTORE.
struct RestoreSheet: View {
    @ObservedObject var m: DeviceManager
    let entry: BackupEntry
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var typed = ""
    @State private var password = ""

    private var ready: Bool { understood && typed.trimmingCharacters(in: .whitespaces).uppercased() == "RESTORE" && (!entry.encrypted || !password.isEmpty) }
    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.orange).frame(width: 18)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.counterclockwise", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore \(m.deviceName) from a backup?").font(.title2.weight(.bold))
                    Text("Backup of \(entry.deviceName)" + (entry.date.map { ", made \(Fmt.date.string(from: $0))" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                point("exclamationmark.triangle.fill", "Settings, messages and app data on \(m.deviceName) are replaced with what is in this backup. Anything newer than the backup can be lost, and this cannot be undone.")
                point("location.slash.fill", "Find My must be turned off on the \(m.deviceKind) first (Settings, your name, Find My).")
                point("cable.connector", "Keep the \(m.deviceKind) plugged in and unlocked until it restarts. Unplugging part-way can leave it incomplete.")
                point("clock.arrow.circlepath", "If there is anything on it you want to keep, make a fresh backup first.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
            if entry.encrypted {
                SecureField("Backup password", text: $password).textFieldStyle(.roundedBorder)
            }
            Toggle("I understand that this replaces data on \(m.deviceName)", isOn: $understood)
            HStack {
                Text("Type RESTORE to confirm:").font(.callout)
                TextField("RESTORE", text: $typed).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Restore Now") {
                    m.startRestore(entry, password: entry.encrypted ? password : nil)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
