import AppKit
import Foundation

/// ~/Library/Mail 에 이미 저장된 메일의 깨진 첨부파일 이름을 백업 후 고친다.
@MainActor
final class MailboxRepairer: ObservableObject {

    struct Candidate: Identifiable {
        var id: URL { url }
        let url: URL
        let mailbox: String
        let fixes: [MIMEFilenameRepair.Fix]
    }

    struct Backup: Identifiable {
        var id: URL { folder }
        let folder: URL
        let manifest: Manifest
    }

    struct Manifest: Codable {
        struct File: Codable { let original: String; let backup: String }
        struct Rename: Codable { let from: String; let to: String }
        var date = Date()
        var files: [File] = []
        var renames: [Rename] = []
    }

    enum Phase: Equatable {
        case idle
        case scanning(checked: Int)
        case scanned
        case working
        case finished(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var candidates: [Candidate] = []
    @Published var backups: [Backup] = []
    @Published var hasAccess = false
    @Published var mailRunning = false

    static let mailBundleID = "com.apple.mail"

    let mailFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")

    let backupRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("KoMailFix/Backups")
    }()

    init() {
        refresh()
        loadBackups()
    }

    func refresh() {
        hasAccess = (try? FileManager.default.contentsOfDirectory(atPath: mailFolder.path)) != nil
        mailRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailBundleID).isEmpty
    }

    /// 가장 최신 V<숫자> 폴더
    private var dataFolder: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mailFolder.path)) ?? []
        let latest = names.filter { $0.hasPrefix("V") && Int($0.dropFirst()) != nil }
            .max { Int($0.dropFirst())! < Int($1.dropFirst())! }
        return latest.map { mailFolder.appendingPathComponent($0) }
    }

    // MARK: - 검사

    func scan() {
        refresh()
        guard let root = dataFolder else {
            phase = .failed("메일 데이터 폴더를 찾지 못했습니다. 전체 디스크 접근 권한을 확인해 주세요.")
            return
        }
        candidates = []
        phase = .scanning(checked: 0)

        Task.detached(priority: .userInitiated) {
            var found: [Candidate] = []
            var checked = 0
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let url = files?.nextObject() as? URL {
                guard url.pathExtension == "emlx" else { continue }
                checked += 1
                if checked % 500 == 0 {
                    let n = checked
                    await MainActor.run { self.phase = .scanning(checked: n) }
                }
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                      let emlx = EMLX(data),
                      let result = MIMEFilenameRepair.repair(emlx.message) else { continue }
                found.append(Candidate(url: url, mailbox: Self.mailboxName(url, root: root), fixes: result.attachmentFixes))
            }
            let total = checked
            let results = found
            await MainActor.run {
                self.candidates = results
                self.phase = results.isEmpty ? .finished("메일 \(total)개를 검사했고, 고칠 첨부파일 이름이 없습니다.") : .scanned
            }
        }
    }

    nonisolated private static func mailboxName(_ url: URL, root: URL) -> String {
        let parts = url.path.dropFirst(root.path.count).split(separator: "/")
        let boxes = parts.filter { $0.hasSuffix(".mbox") }.map { $0.dropLast(5) }
        return boxes.isEmpty ? "?" : boxes.joined(separator: " › ")
    }

    // MARK: - 복구

    func repairAll() {
        refresh()
        guard !mailRunning else {
            phase = .failed("Mail을 먼저 종료해 주세요.")
            return
        }
        let targets = candidates
        phase = .working

        Task.detached(priority: .userInitiated) {
            let outcome = Self.repair(targets, backupRoot: self.backupRoot)
            await MainActor.run {
                self.candidates = []
                self.loadBackups()
                switch outcome {
                case .success(let (count, renamed)):
                    self.phase = .finished("메일 \(count)개의 첨부파일 이름을 고쳤습니다 (풀어둔 첨부파일 \(renamed)개 이름 변경). Mail을 다시 열어 확인해 주세요.")
                case .failure(let error):
                    self.phase = .failed("복구 중 오류: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func repair(_ targets: [Candidate], backupRoot: URL) -> Result<(Int, Int), Error> {
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let folder = backupRoot.appendingPathComponent(stamp.string(from: Date()))
        var manifest = Manifest()
        var repaired = 0

        func saveManifest() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }

        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, target) in targets.enumerated() {
                guard let data = try? Data(contentsOf: target.url),
                      var emlx = EMLX(data),
                      let result = MIMEFilenameRepair.repair(emlx.message) else { continue }

                let backup = folder.appendingPathComponent("\(index)-\(target.url.lastPathComponent)")
                try fm.copyItem(at: target.url, to: backup)
                manifest.files.append(.init(original: target.url.path, backup: backup.path))
                try saveManifest()

                emlx.message = result.data
                try emlx.data.write(to: target.url)
                repaired += 1

                for fix in result.attachmentFixes {
                    let dir = EMLX.attachmentDirectory(for: target.url, partID: fix.partID)
                    let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    guard files.count == 1, let file = files.first else { continue }
                    let newName = fix.repaired.replacingOccurrences(of: "/", with: "-")
                    let dest = dir.appendingPathComponent(newName)
                    guard file.lastPathComponent != newName, !fm.fileExists(atPath: dest.path) else { continue }
                    try fm.moveItem(at: file, to: dest)
                    manifest.renames.append(.init(from: file.path, to: dest.path))
                }
            }
            try saveManifest()
            return .success((repaired, manifest.renames.count))
        } catch {
            try? saveManifest()
            return .failure(error)
        }
    }

    // MARK: - 백업 / 되돌리기

    func loadBackups() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        backups = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else { return nil }
            return Backup(folder: folder, manifest: manifest)
        }
        .sorted { $0.manifest.date > $1.manifest.date }
    }

    func restore(_ backup: Backup) {
        refresh()
        guard !mailRunning else {
            phase = .failed("Mail을 먼저 종료해 주세요.")
            return
        }
        let fm = FileManager.default
        var failures = 0
        for rename in backup.manifest.renames.reversed() {
            do { try fm.moveItem(atPath: rename.to, toPath: rename.from) } catch { failures += 1 }
        }
        for file in backup.manifest.files {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file.backup))
                try data.write(to: URL(fileURLWithPath: file.original))
            } catch { failures += 1 }
        }
        if failures == 0 {
            try? fm.moveItem(at: backup.folder, to: backup.folder.appendingPathExtension("restored"))
            phase = .finished("백업 시점으로 되돌렸습니다 (메일 \(backup.manifest.files.count)개).")
        } else {
            phase = .failed("되돌리는 중 \(failures)건 실패했습니다. 백업 폴더는 그대로 남겨 두었습니다.")
        }
        loadBackups()
    }

    // MARK: - 바로가기

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func openMail() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.mailBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func quitMail() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.mailBundleID).forEach { $0.terminate() }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(backupRoot)
    }
}
