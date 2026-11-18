import MIOCore
import SwiftUI

struct BluetoothAccessView: View {
    var body: some View {
        TabView {
            BluetoothHostPane().tabItem { Text("접속 받기") }
            BluetoothRemotePane().tabItem { Text("다른 Mac에 연결") }
        }
        .padding(16)
        .frame(width: 462, height: 320)
    }
}

private struct BluetoothHostPane: View {
    @EnvironmentObject private var host: BluetoothHost

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("블루투스 원격 제어 허용", isOn: Binding(get: { host.enabled }, set: { host.setEnabled($0) }))
                .toggleStyle(.switch)
            switch host.status {
            case .available:
                VStack(alignment: .leading, spacing: 5) {
                    Text("기기 이름 \(host.name)").font(.headline)
                    Text("다른 Mac의 AdvancedMIO에서 이 기기를 고르고 아래 6자리 코드를 직접 입력하세요.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(host.code)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .tracking(5)
                        .accessibilityLabel("접속 코드 \(host.code.map(String.init).joined(separator: " "))")
                    Spacer()
                    Button("새 코드") { host.rotateCode() }
                        .help("기존 코드로 연결한 기기에 새 코드를 다시 입력해야 합니다.")
                }
                Label(host.remotes.isEmpty ? "연결된 기기 없음"
                      : "연결된 기기 \(host.remotes.count)대 · 코드 인증 \(host.authenticatedCount)대",
                      systemImage: host.remotes.isEmpty ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(host.remotes.isEmpty ? Color.secondary : Color.green)
                if let event = host.lastRemoteEvent {
                    Label(event, systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                }
            case .starting:
                ProgressView().controlSize(.small)
                Text("블루투스 접속을 준비하고 있습니다.").foregroundStyle(.secondary)
            case .off:
                Text("이 Mac의 블루투스 원격 제어가 꺼져 있습니다.").foregroundStyle(.secondary)
            case .unavailable(let message), .failed(let message):
                Text(message).foregroundStyle(.secondary)
                Button("다시 시도") { host.retry() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }
}

private struct BluetoothRemotePane: View {
    @ObservedObject private var remote = BluetoothRemote.shared
    @State private var codeDraft = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch remote.phase {
            case .idle, .scanning:
                browser
            case .connecting, .authenticating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(remote.phase == .connecting ? "\(remote.deviceName)에 연결 중" : "접속 코드 확인 중")
                    Spacer()
                    Button("취소") { remote.close() }
                }
            case .enteringCode:
                deviceHeader
                Text("연결할 Mac에 표시된 6자리 코드를 입력하세요.").foregroundStyle(.secondary)
                HStack {
                    SecureField("6자리 접속 코드", text: Binding(get: { codeDraft }, set: { input in
                        codeDraft = String(input.filter { "0123456789".contains($0) }.prefix(6))
                    }))
                    .font(.system(.body, design: .monospaced))
                    .focused($codeFocused)
                    .onAppear { codeFocused = true }
                    Button("인증") {
                        remote.authenticate(codeDraft)
                        codeDraft = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(codeDraft.count != 6)
                }
            case .connected:
                deviceHeader
                Label("연결됨 · 창을 닫아도 연결은 유지됩니다 (메뉴 바에서도 제어)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    ForEach(BluetoothControlAction.allCases, id: \.self) { action in
                        Button(action.title) { remote.send(action) }
                    }
                    if remote.sending { ProgressView().controlSize(.small) }
                }
                .disabled(remote.sending)
                if let action = remote.lastAction {
                    Label("\(action.title) 완료", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let message = remote.message { Text(message).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .onDisappear { codeDraft = "" }      // the connection stays up; only 연결 끊기 drops it
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("주변 AdvancedMIO 기기").font(.headline)
                Spacer()
                if remote.phase == .scanning {
                    ProgressView().controlSize(.small).accessibilityLabel("검색 중")
                    Button("취소") { remote.close() }
                } else {
                    Button("기기 검색") { remote.search() }
                }
            }
            if !remote.devices.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(remote.devices) { device in
                            HStack {
                                Text(device.name)
                                Spacer()
                                Button("연결") { remote.connect(to: device) }
                                    .accessibilityLabel("\(device.name)에 연결")
                            }
                        }
                    }
                    .padding(3)
                }
            }
        }
    }

    private var deviceHeader: some View {
        HStack {
            Text(remote.deviceName).font(.headline)
            Spacer()
            Button("연결 끊기") { remote.close(); codeDraft = "" }
        }
    }
}
