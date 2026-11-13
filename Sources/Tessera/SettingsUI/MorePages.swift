import AppKit
import SwiftUI
import TesseraCore
import UniformTypeIdentifiers

// MARK: - Apps

struct AppsPage: View {
    private var prefs: Preferences { .shared }

    var body: some View {
        Form {
            Section(L("Don't tile these apps")) {
                ForEach(prefs.excludedApps) { app in
                    HStack {
                        Image(nsImage: AppIcons.icon(bundleID: app.bundleID)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        if app.isDefault {
                            Text(L("Default")).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18), in: Capsule())
                        }
                        Spacer()
                        Button(L("Remove")) {
                            prefs.excludedApps.removeAll { $0.bundleID == app.bundleID }
                            SettingsEffects.retile()
                        }
                        .controlSize(.small)
                    }
                }
                Button(L("Choose from Applications…"), action: chooseApps)
            }
            Section(L("Always float these windows")) {
                if prefs.floatRules.isEmpty {
                    Text(L("None yet. Open a dialog that gets tiled by mistake and press %@.", ShortcutCenter.shared.label(for: .alwaysFloat)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(prefs.floatRules) { rule in
                    HStack {
                        Image(nsImage: AppIcons.icon(bundleID: rule.bundleID)).resizable().frame(width: 20, height: 20)
                        Text(rule.appName)
                        Text("“\(rule.titleWords)…”").foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Remove")) { prefs.floatRules.removeAll { $0.id == rule.id } }.controlSize(.small)
                    }
                }
            }
            Section(L("Apps that can't shrink")) {
                Text(L("Tessera learns the smallest size an app accepts, then moves split lines to make room. Stored only on this Mac."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(prefs.learnedMinimums.keys.sorted(), id: \.self) { bundleID in
                    let minimum = prefs.learnedMinimums[bundleID] ?? LearnedMinimum()
                    HStack {
                        Image(nsImage: AppIcons.icon(bundleID: bundleID)).resizable().frame(width: 20, height: 20)
                        Text(prefs.learnedMinimumNames[bundleID] ?? bundleID)
                        Text(sizeText(minimum)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button(L("Forget")) { prefs.learnedMinimums.removeValue(forKey: bundleID) }.controlSize(.small)
                        Button(L("Never Learn")) {
                            prefs.neverLearn[bundleID] = prefs.learnedMinimumNames[bundleID] ?? bundleID
                            prefs.learnedMinimums.removeValue(forKey: bundleID)
                        }
                        .controlSize(.small)
                    }
                }
                if !prefs.learnedMinimums.isEmpty {
                    Button(L("Forget All")) {
                        prefs.learnedMinimums.removeAll()
                        SettingsEffects.retile()
                    }
                }
                if !prefs.neverLearn.isEmpty {
                    Text(L("Never learned for")).font(.caption.weight(.semibold))
                    ForEach(prefs.neverLearn.keys.sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(prefs.neverLearn[bundleID] ?? bundleID)
                            Spacer()
                            Button(L("Learn Again")) { prefs.neverLearn.removeValue(forKey: bundleID) }.controlSize(.small)
                        }
                    }
                }
                if !prefs.hiddenRoomNotices.isEmpty {
                    Text(L("“Needs more room” notices hidden for")).font(.caption.weight(.semibold))
                    ForEach(prefs.hiddenRoomNotices.keys.sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(prefs.hiddenRoomNotices[bundleID] ?? bundleID)
                            Spacer()
                            Button(L("Show Again")) { prefs.hiddenRoomNotices.removeValue(forKey: bundleID) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sizeText(_ minimum: LearnedMinimum) -> String {
        let width = minimum.width.map { "\(Int($0))" } ?? L("Any")
        let height = minimum.height.map { "\(Int($0))" } ?? L("Any")
        return "\(width) × \(height)"
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Don't Tile")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            prefs.setExcluded(bundleID, name: name, excluded: true)
        }
        SettingsEffects.retile()
    }
}

// MARK: - Setups

struct SetupsPage: View {
    private var store: SetupStore { .shared }
    private var runner: SetupRunner { .shared }
    @State private var newName = ""
    @State private var editing: UUID?
    @State private var editName = ""
    @State private var confirmDelete: Setup?

    var body: some View {
        Form {
            if !AppModel.shared.licenseState.hasFullVersion {
                Section { Text(L("Setups come with the full version.")).foregroundStyle(.secondary) }
            }
            Section {
                Text(L("A setup is a named arrangement of apps: which app sits in which tile, on which screen, with your layout and sizes. Opening one launches the apps and puts them in place. Apps that aren't in the setup are hidden, never quit. Only apps and layout are stored — never window titles or documents."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L("Name, like “Coding” or “Calls 📞”"), text: $newName)
                    Button(L("Save this arrangement")) {
                        runner.saveCurrent(named: newName.trimmingCharacters(in: .whitespaces))
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(store.setups) { setup in
                Section {
                    HStack {
                        if editing == setup.id {
                            TextField(L("Name"), text: $editName).onSubmit { rename(setup) }
                            Button(L("Done")) { rename(setup) }
                        } else {
                            Text(setup.name).font(.headline)
                            statusBadge(setup)
                            Spacer()
                            Button(L("Open")) { runner.open(setup) }
                        }
                    }
                    Text(L("Screens: %@", setup.screens.map(\.screenName).joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(setup.allApps.map(\.name).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(L("Shortcut"))
                        Spacer()
                        ShortcutRecorder(combo: setup.shortcut) { combo in
                            var updated = setup
                            updated.shortcut = combo
                            store.update(updated)
                            ShortcutCenter.shared.reload()
                        }
                    }
                    HStack {
                        Button(L("Rename")) {
                            editName = setup.name
                            editing = setup.id
                        }
                        Button(L("Update from What's on Screen")) { runner.updateFromScreen(setup) }
                        Spacer()
                        Button(L("Delete"), role: .destructive) { confirmDelete = setup }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .alert(
            L("Delete this setup?"),
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { setup in
            Button(L("Delete"), role: .destructive) { store.delete(setup.id) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { setup in
            Text(L("“%@” will be removed. Your apps aren't affected.", setup.name))
        }
    }

    @ViewBuilder private func statusBadge(_ setup: Setup) -> some View {
        switch runner.status(of: setup) {
        case .onScreen:
            Text(L("ON SCREEN")).font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case .changed:
            Text(L("CHANGED")).font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
            Button(L("Put Back")) { runner.open(setup) }.controlSize(.mini)
            Button(L("Update")) { runner.updateFromScreen(setup) }.controlSize(.mini)
        case .idle:
            EmptyView()
        }
    }

    private func rename(_ setup: Setup) {
        let name = editName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            var updated = setup
            updated.name = name
            store.update(updated)
        }
        editing = nil
    }
}

// MARK: - Activity

struct ActivityPage: View {
    private var prefs: Preferences { .shared }

    var body: some View {
        let counts = prefs.activity
        Form {
            Section {
                Toggle(L("Count activity"), isOn: Binding(get: { prefs.countActivity }, set: { prefs.countActivity = $0 }))
                Text(L("Only numbers are stored, on this Mac. Never window titles or app names."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Since %@", counts.since.formatted(date: .abbreviated, time: .omitted))) {
                stat(L("Windows arranged"), counts.windowsArranged)
                stat(L("Swaps"), counts.swaps)
                stat(L("Layout changes"), counts.layoutChanges)
                stat(L("Shortcuts used"), counts.shortcutsUsed)
                stat(L("Tab View switches"), counts.tabViewSwitches)
                stat(L("Focus sessions"), counts.focusSessions)
                stat(L("No peek sessions"), counts.noPeekSessions)
                stat(L("Clean Space sessions"), counts.cleanSpaceSessions)
                stat(L("Setups opened"), counts.setupsOpened)
            }
            Section {
                Button(L("Reset Activity")) { prefs.activity = ActivityCounts() }
            }
        }
        .formStyle(.grouped)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        LabeledContent(title) { Text("\(value)").monospacedDigit() }
    }
}

// MARK: - License

struct LicensePage: View {
    private var license: LicenseManager { .shared }
    private var model: AppModel { .shared }
    @State private var key = ""
    @State private var confirmDeactivate = false

    var body: some View {
        Form {
            Section {
                switch model.licenseState {
                case .unlicensedBuild:
                    Label(L("This build is fully unlocked."), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .trial(let remaining):
                    Label(L("Free trial: %ld hours left", Int(remaining / 3600)), systemImage: "clock")
                case .trialEnded:
                    Label(L("Your free trial has ended. Tessera won't tile until a license is active on this Mac."), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .licensed:
                    Label(L("Active on this Mac (%@).", license.maskedKey ?? ""), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case .revoked:
                    Label(L("This key was refunded or deactivated. Enter another key to keep tiling."), systemImage: "xmark.seal.fill").foregroundStyle(.red)
                }
            }
            if AppConfig.licensingEnabled {
                if model.licenseState != .licensed {
                    Section(L("Activate")) {
                        HStack {
                            TextField(L("License key"), text: $key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button(L("Activate")) {
                                Task { if await license.activate(key: key) { key = "" } }
                            }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.busy)
                        }
                        if let error = license.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button(L("Buy %@…", AppConfig.appName)) { license.buy() }
                        Text(L("Lost your key? It's in the receipt email from your purchase."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section(L("Move to another Mac")) {
                        Text(L("Deactivate here, then enter the key on the new Mac."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("Deactivate…")) { confirmDeactivate = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(L("Deactivate this Mac?"), isPresented: $confirmDeactivate) {
            Button(L("Deactivate"), role: .destructive) { Task { await license.deactivate() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Tessera will stop tiling here until a key is entered again."))
        }
    }
}

// MARK: - About

struct AboutPage: View {
    @State private var report: Diagnostics.Kind?
    @State private var showingWhatsNew = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: AppIconStyle(rawValue: Preferences.shared.appIcon)?.image(size: 128) ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text(AppConfig.appName).font(.title2.weight(.semibold))
                        Text(L("Version %@ (%@)", AppConfig.version, AppConfig.build)).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button(L("Check for Updates…")) { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.isAvailable)
                Button(L("What's New")) { showingWhatsNew = true }
                if let website = AppConfig.websiteURL {
                    Link(L("Website"), destination: website)
                }
                if let docs = AppConfig.docsURL {
                    Link(L("Help and guides"), destination: docs)
                }
            }
            Section(L("Feedback")) {
                Button(L("Report a Problem…")) { report = .problem }
                Button(L("Suggest a Feature…")) { report = .feature }
            }
            Section(L("Privacy")) {
                Text(L("Tessera uses Accessibility only to move and resize windows. It doesn't capture screenshots, read document contents or save window titles. Shortcuts are registered with macOS, so it never reads your typing. It works offline, connecting only to check a license and look for updates."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { report.map { ReportKind(kind: $0) } }, set: { report = $0?.kind })) { item in
            ReportSheet(kind: item.kind)
        }
        .sheet(isPresented: $showingWhatsNew) { WhatsNewView() }
    }
}

struct ReportKind: Identifiable {
    let kind: Diagnostics.Kind
    var id: String { kind == .problem ? "problem" : "feature" }
}

struct ReportSheet: View {
    let kind: Diagnostics.Kind
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeDiagnostics = true

    private var subject: String {
        kind == .problem ? L("%@ problem report", AppConfig.appName) : L("%@ feature idea", AppConfig.appName)
    }

    private var body_: String { Diagnostics.report(kind: kind, message: message, includeDiagnostics: includeDiagnostics) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .problem ? L("Report a Problem") : L("Suggest a Feature")).font(.title3.weight(.semibold))
            TextEditor(text: $message)
                .font(.system(size: 13))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            if kind == .problem {
                Toggle(L("Include diagnostics"), isOn: $includeDiagnostics)
            }
            DisclosureGroup(L("Review everything that will be sent")) {
                ScrollView {
                    Text(body_).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            HStack {
                Button(L("Copy Report")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body_, forType: .string)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Menu(L("Email")) {
                    Button(L("Apple Mail")) { send(.appleMail) }
                    Button(L("Gmail")) { send(.gmail) }
                    Button(L("Outlook.com")) { send(.outlook) }
                } primaryAction: {
                    send(.appleMail)
                }
                .fixedSize()
                .disabled(AppConfig.supportEmail.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func send(_ mailer: Diagnostics.Mailer) {
        Diagnostics.send(body_, subject: subject, via: mailer)
        dismiss()
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("What's New in %@", AppConfig.appName)).font(.title2.weight(.semibold))
            ForEach(WhatsNew.notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Version %@", note.version)).font(.headline)
                    ForEach(note.items, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle").font(.system(size: 13))
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Continue")) {
                    if let onDone { onDone() } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
