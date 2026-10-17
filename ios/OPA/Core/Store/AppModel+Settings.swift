import Foundation
import SwiftUI

// Settings (optimistic edits that roll back on failure), models, memory, devices.

extension AppModel {
    // MARK: Settings

    func loadSettings() async {
        if let res = try? await request("settings.get"), let s = try? res.decode(Settings.self) { acceptServerSettings(s) }
    }

    func loadModels() async {
        if let res = try? await request("models.list"), let m = try? res.decode(ModelsList.self) { models = m }
    }

    /// Sends a partial settings object (deep-merged on the host).
    ///
    /// The screen shows the edit at once (`settings` = what the host last confirmed + the unconfirmed edits).
    /// When the host refuses or cannot be reached the edit is dropped, so `settings` goes back to the host's value —
    /// no optimistic value is left behind — and `settingsSync` becomes `.failed(message)`.
    func updateSettings(_ patch: JSONValue) {
        settingsPatchCounter += 1
        let id = settingsPatchCounter
        pendingSettingsPatches.append((id, patch))
        savedResetTask?.cancel()
        settingsSync = .saving
        recomputeSettings()
        Task {
            do {
                let res = try await request("settings.set", patch)
                // The host answers with the full merged settings; if it did not, assume it applied our edit.
                acceptServerSettings((try? res.decode(Settings.self)) ?? Self.settings(serverSettings, applying: patch))
                finishSettingsPatch(id, error: nil)
            } catch {
                finishSettingsPatch(id, error: error.localizedDescription)
            }
        }
    }

    private func finishSettingsPatch(_ id: Int, error: String?) {
        pendingSettingsPatches.removeAll { $0.id == id }
        if let error {
            settingsBatchError = error
            showToast("设置未同步：\(error)")
        }
        recomputeSettings()   // a failed edit is no longer part of the displayed value
        guard pendingSettingsPatches.isEmpty else { return }   // still saving other edits
        if let e = settingsBatchError {
            settingsSync = .failed(e)
        } else {
            settingsSync = .saved
            savedResetTask?.cancel()
            savedResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.settingsSync == .saved else { return }
                self.settingsSync = .idle
            }
        }
        settingsBatchError = nil
    }

    /// The host's settings changed (response, `settings.changed` event, `settings.get`).
    func acceptServerSettings(_ s: Settings) {
        serverSettings = s
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: DefaultsKey.settings) }
        recomputeSettings()
    }

    /// `settings` = the host's value with the still-unconfirmed edits applied on top.
    private func recomputeSettings() {
        var merged = serverSettings
        for p in pendingSettingsPatches { merged = Self.settings(merged, applying: p.patch) }
        if merged != settings { settings = merged }
    }

    nonisolated static func settings(_ s: Settings, applying patch: JSONValue) -> Settings {
        guard let current = try? JSONValue(encoding: s), let merged = try? current.deepMerging(patch).decode(Settings.self) else { return s }
        return merged
    }

    // MARK: Memory

    func loadMemories() async {
        if let res = try? await request("memory.list"), let items = try? res["items"]?.decode([Memory].self) {
            memories = items.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// `memory.changed` arrived live: refresh the cached list shortly (burst-safe) even if no screen is looking.
    func scheduleMemoryReload() {
        guard canUseHost else { return }
        memoryReloadTask?.cancel()
        memoryReloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.loadMemories()
        }
    }

    func addMemory(_ text: String, kind: Memory.Kind) async {
        do {
            let res = try await request("memory.add", ["text": .string(text), "kind": .string(kind.rawValue)])
            if let m = try? res.decode(Memory.self) { withAnimation(spring) { memories.insert(m, at: 0) } }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func deleteMemory(_ id: String) async {
        let backup = memories
        withAnimation(spring) { memories.removeAll { $0.id == id } }
        do {
            try await request("memory.delete", ["id": .string(id)])
        } catch {
            memories = backup
            showToast(error.localizedDescription)
        }
    }

    // MARK: Devices

    func loadDevices() async {
        if let res = try? await request("devices.list"), let d = try? res["devices"]?.decode([PairedDevice].self) {
            devices = d
        }
    }
}
