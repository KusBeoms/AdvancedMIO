import SwiftUI

enum SideTab { case source, spatial }

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHistory = false
    @State private var presetNameDraft = ""
    @State private var askPresetName = false
    @State private var sideTab: SideTab = CommandLine.arguments.contains("--demo-spatial") ? .spatial : .source

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                header
                if let e = model.error { errorBanner(e) }
                ForEach(model.latencyAlerts) { latencyBanner($0) }
                HStack(alignment: .top, spacing: 18) {
                    sourceColumn.frame(width: 300)
                    outputsColumn
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
                footer
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 620)
        .sheet(isPresented: Binding(get: { model.calPhase != .idle }, set: { if !$0 { model.closeCalibration() } })) {
            CalibrationSheet().environmentObject(model)
        }
        .sheet(isPresented: $showHistory) { CalibrationHistorySheet().environmentObject(model) }
        .alert("프리셋 저장", isPresented: $askPresetName) {
            TextField("이름 (예: 거실)", text: $presetNameDraft)
            Button("저장") { model.savePreset(named: presetNameDraft) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("켜 둔 기기, 지연, 음량, EQ, 공간 배치를 함께 저장합니다. 같은 이름이면 덮어씁니다.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accentDiagonal)
                Symbol("waveform.path", size: 18, weight: .bold).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Theme.violet.opacity(0.5), radius: 10, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("AdvancedMIO").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("멀티 입출력 · 기기별 싱크 지연").font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            StatusPill(running: model.capturing, armed: model.running)
            settingsMenu
            Button { model.refresh() } label: {
                Symbol("arrow.clockwise", size: 13)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain).help("장치 목록 새로고침")
            startButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)      // room for the hidden title bar's traffic lights
        .padding(.bottom, 16)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("지연 변화 경고 표시", isOn: Binding(get: { model.latencyWarningsEnabled }, set: { model.setLatencyWarnings($0) }))
            Toggle("전역 단축키 (⌃⌥⌘ S · Z · 1–9)", isOn: Binding(get: { model.hotkeysEnabled }, set: { model.setHotkeys($0) }))
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        } label: {
            Symbol("gearshape", size: 13)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("설정")
    }

    /// Display only: nothing is changed. Hidden by × (until the latency moves again) or switched off for good.
    private func latencyBanner(_ a: LatencyAlert) -> some View {
        HStack(spacing: 10) {
            Symbol("clock.badge.exclamationmark", size: 14).foregroundStyle(Color(hex: 0xFFB84D))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(a.name): 하드웨어 지연이 \(Int(a.fromMs.rounded())) → \(Int(a.toMs.rounded())) ms 로 바뀌었습니다")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(a.toMs > a.fromMs ? "소리가 다른 기기보다 늦어졌을 수 있습니다. 지연을 다시 맞춰 보세요." : "소리가 다른 기기보다 빨라졌을 수 있습니다. 지연을 다시 맞춰 보세요.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button("경고 끄기") { model.setLatencyWarnings(false) }
                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
            Button { model.dismissLatencyAlert(a.uid) } label: { Symbol("xmark", size: 10, weight: .bold) }
                .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0xFFB84D).opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xFFB84D).opacity(0.4)))
        .padding(.horizontal, 22).padding(.bottom, 12)
    }

    private var startButton: some View {
        Button { model.toggleRunning() } label: {
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small).tint(.white) }
                else { Symbol(model.running ? "stop.fill" : "play.fill", size: 12) }
                Text(model.running ? "정지" : "시작")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22).frame(height: 36)
            .background(Capsule().fill(model.running ? AnyShapeStyle(LinearGradient(colors: [Theme.pink, Color(hex: 0xFF8A5C)], startPoint: .leading, endPoint: .trailing))
                                                      : AnyShapeStyle(Theme.accent)))
            .shadow(color: (model.running ? Theme.pink : Theme.violet).opacity(0.5), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(model.busy)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Symbol("exclamationmark.triangle.fill", size: 14).foregroundStyle(Theme.pink)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button { model.error = nil } label: { Symbol("xmark", size: 10, weight: .bold) }
                .buttonStyle(.plain).foregroundStyle(Theme.text2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pink.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.pink.opacity(0.4)))
        .padding(.horizontal, 22).padding(.bottom, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Columns

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(Theme.text2)
            Spacer()
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 4)
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                sideTabButton(.source, "SOURCE")
                sideTabButton(.spatial, "공간음향")
                Spacer()
                if model.spatialOn { Text("ON").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.cyan) }
            }
            .padding(.horizontal, 4)
            switch sideTab {
            case .source: SourceCard().environmentObject(model)
            case .spatial: SpatialCard().environmentObject(model)
            }
            Spacer(minLength: 0)
        }
    }

    private func sideTabButton(_ tab: SideTab, _ title: String) -> some View {
        let selected = sideTab == tab
        return Button { sideTab = tab } label: {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(selected ? 1.2 : 0.8)
                .foregroundStyle(selected ? Color.white : Theme.text2)
                .padding(.horizontal, 11).frame(height: 24)
                .background(Capsule().fill(selected ? Theme.violet.opacity(0.6) : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ symbol: String, _ title: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Symbol(symbol, size: 11)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(accent ? AnyShapeStyle(Theme.accent.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.09))))
        }
        .buttonStyle(.plain)
    }

    private var presetMenu: some View {
        Menu {
            ForEach(model.presets) { p in
                Button { model.applyPreset(p.id) } label: {
                    Text(model.activePresetID == p.id ? "✓ \(p.name)" : p.name)
                }
            }
            if !model.presets.isEmpty { Divider() }
            Button("현재 설정을 프리셋으로 저장…") { presetNameDraft = model.activePreset?.name ?? ""; askPresetName = true }
            if !model.presets.isEmpty {
                Menu("프리셋 삭제") {
                    ForEach(model.presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p.id) } }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Symbol("square.stack.3d.up", size: 11)
                Text(model.activePreset?.name ?? "프리셋")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.09)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("기기 조합·지연·음량·EQ·공간 배치를 이름 붙여 저장하고 불러옵니다")
    }

    private var outputsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("OUTPUTS", "가장 늦은 기기에 자동 정렬")
            HStack(spacing: 8) {
                presetMenu
                pill("arrow.counterclockwise", "모두 자동") { model.allAuto() }
                    .disabled(!model.canAllAuto).opacity(model.canAllAuto ? 1 : 0.35)
                    .help("모든 기기를 장치가 보고하는 하드웨어 지연으로 되돌립니다")
                pill("arrow.down.to.line", "최저 지연 0으로") { model.zeroMinLag() }
                    .disabled(!model.canZeroLag).opacity(model.canZeroLag ? 1 : 0.35)
                    .help("켜 둔 기기 중 가장 낮은 지연이 0이 되도록 모두 같은 만큼 내립니다. 기기 간 차이(들리는 싱크)는 그대로입니다")
                Spacer(minLength: 0)
                pill("clock.arrow.circlepath", model.calHistory.isEmpty ? "기록" : "기록 \(model.calHistory.count)") { showHistory = true }
                    .help(model.calibrationStaleReason.map { "재측정 권장: \($0)" } ?? "지난 캘리브레이션 결과와 비교")
                pill("waveform.badge.magnifyingglass", model.calibrationStaleReason == nil ? "룸 캘리브레이션" : "룸 캘리브레이션 ●", accent: true) { model.openCalibration() }
                    .disabled(!model.canCalibrate).opacity(model.canCalibrate ? 1 : 0.35)
                    .help("마이크로 기기별 소리 도착 시간을 재서 지연을 자동으로 계산합니다 (출력 2개 이상 + 마이크 필요)")
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.outputDevices) { d in OutputCard(device: d).environmentObject(model) }
                    if model.outputDevices.isEmpty { emptyState("출력 장치가 없습니다") }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Symbol("info.circle", size: 12, weight: .regular).foregroundStyle(Theme.text3)
            Text("제어 센터(또는 시스템 설정 ▸ 사운드)에서 출력을 ")
            + Text("AdvancedMIO").foregroundColor(Theme.cyan)
            + Text(" 로 고르면, 그 소리가 여기서 켠 장치들로 지연과 함께 나갑니다.")
            Spacer()
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 26).padding(.bottom, 14)
    }
}
