import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var repairer = MailboxRepairer()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                extensionSection
                repairSection
                if !repairer.backups.isEmpty { backupSection }
                UpdateSection()
            }
            .padding(20)
        }
        .onReceive(ticker) { _ in repairer.refresh() }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "v\(info?["CFBundleShortVersionString"] as? String ?? "?")"
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("KoMailFix").font(.largeTitle.bold())
                    Text(version).foregroundStyle(.secondary)
                }
                Text("Mail 앱에서 한글 첨부파일 이름이 ????로 깨지는 문제를 고칩니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 메일 확장

    private var extensionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("새로 여는 메일은 확장 프로그램이 자동으로 고쳐서 보여줍니다. 한 번만 켜 두면 이 앱을 열어둘 필요는 없습니다.")
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Mail 실행 → 설정(⌘,) → 확장 프로그램")
                    Text("2. 왼쪽 목록에서 **KoMailFix** 체크")
                    Text("3. 깨졌던 메일을 다시 열어 확인")
                }
                .font(.callout)
                Text("보내는 메일의 한글 첨부파일 이름은 NFC(완성형)로 바꿔 보냅니다. Mail은 이름을 자모가 분리된 NFD로 보내서 Windows에서 ㅎㅏㄴㄱㅡㄹ처럼 보일 수 있습니다. 작성 창의 **서명** 옵션이 켜져 있을 때만 동작하며, 실제로 서명하지는 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Mail 열기") { repairer.openMail() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("메일 확장 프로그램", systemImage: "puzzlepiece.extension")
        }
    }

    // MARK: - 기존 메일 복구

    private var repairSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("이미 받아둔 메일의 원본(.emlx)과 Mail이 풀어 저장한 첨부파일 이름을 고칩니다. 고치기 전에 원본을 백업합니다.")

                if !repairer.hasAccess {
                    accessNotice
                } else {
                    repairControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("기존 메일 복구", systemImage: "wrench.and.screwdriver")
        }
    }

    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("메일 폴더를 읽으려면 전체 디스크 접근 권한이 필요합니다.", systemImage: "lock")
                .foregroundStyle(.orange)
            Text("시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 KoMailFix를 켠 뒤 앱을 다시 실행해 주세요.")
                .font(.callout)
            HStack {
                Button("설정 열기") { repairer.openFullDiskAccessSettings() }
                Button("다시 확인") { repairer.refresh() }
            }
        }
    }

    @ViewBuilder
    private var repairControls: some View {
        HStack {
            Button("검사") { repairer.scan() }
                .disabled(isBusy)
            if case .scanning(let checked) = repairer.phase {
                ProgressView().controlSize(.small)
                Text("메일 \(checked)개 확인 중…").foregroundStyle(.secondary)
            }
            if repairer.phase == .working {
                ProgressView().controlSize(.small)
                Text("복구 중…").foregroundStyle(.secondary)
            }
        }

        statusMessage

        if !repairer.candidates.isEmpty {
            Text("고칠 메일 \(repairer.candidates.count)개").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(repairer.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.mailbox).font(.caption).foregroundStyle(.secondary)
                        ForEach(candidate.fixes, id: \.self) { fix in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(fix.broken).strikethrough().foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption)
                                Text(fix.repaired)
                            }
                            .font(.callout)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if repairer.mailRunning {
                HStack {
                    Label("복구하려면 Mail을 종료해야 합니다.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Mail 종료") { repairer.quitMail() }
                }
            }
            Button("백업 후 복구") { repairer.repairAll() }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || repairer.mailRunning)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch repairer.phase {
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch repairer.phase {
        case .scanning, .working: return true
        default: return false
        }
    }

    // MARK: - 백업

    private var backupSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(repairer.backups) { backup in
                    HStack {
                        Text(backup.manifest.date.formatted(date: .abbreviated, time: .standard))
                        Text("메일 \(backup.manifest.files.count)개").foregroundStyle(.secondary)
                        Spacer()
                        Button("되돌리기") { repairer.restore(backup) }
                            .disabled(isBusy || repairer.mailRunning)
                    }
                }
                Button("백업 폴더 열기") { repairer.revealBackups() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("백업", systemImage: "clock.arrow.circlepath")
        }
    }
}

// MARK: - 업데이트

/// 업데이트 확인 · 자동 확인 켜고 끄기. 업데이트 뒤에는 Mail을 다시 열어야 새 확장이 적용된다
private struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("자동으로 업데이트 확인", isOn: Binding(get: { updater.automaticallyChecks },
                                                          set: { updater.automaticallyChecks = $0 }))
                    Spacer()
                    Button("업데이트 확인…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
                Text("이 앱을 열 때 새 버전이 있는지 확인하고, 있으면 설치할지 묻습니다. 업데이트한 뒤에는 Mail을 종료했다가 다시 열어야 새 확장이 적용됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label("업데이트", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}
