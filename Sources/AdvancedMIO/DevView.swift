import MIOCore
import SwiftUI

/// The SOURCE column's third tab: a short status of the developer tools.
struct DevSummaryCard: View {
    @EnvironmentObject var lab: DevLab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("개발자 모드").font(.system(size: 14, weight: .bold))
            Text("울림 지수의 가중치 λ를 귀로 맞추는 곳입니다. 헤드폰(에어팟)으로 두 소리를 번갈아 듣고 덜 울리는 쪽을 고르면, 그 선택을 가장 잘 설명하는 λ를 계산합니다.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.white.opacity(0.1))
            row("현재 λ", String(format: "%.0f", lab.lateWeight) + (abs(lab.lateWeight - RoomOptimizer.defaultLateWeight) < 0.5 ? " (기본값)" : ""))
            row("기록된 투표", "\(lab.votes.count)")
        }
        .padding(16).card()
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.system(size: 12)).foregroundStyle(Theme.text2); Spacer()
                 Text(v).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()) }
    }
}

/// The A/B listening test and the weight fit.
struct DevPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var lab: DevLab
    @EnvironmentObject var resonance: ResonanceLab

    private var headphones: [AudioDeviceInfo] {
        model.outputDevices.filter { $0.transport != .virtual && $0.transport != .aggregate }
    }
    private var roomName: String { lab.roomChoice == .mine ? "mine" : "synthetic" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("같은 노래를 두 가지 지연 설정으로 방에서 녹음했다면 어떻게 들릴지 합성해 헤드폰으로 들려줍니다. 어느 쪽이 덜 울리는지 고르세요.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                roomCard
                liveCard
                Text("울림 지수 청취 시험").font(.system(size: 20, weight: .bold, design: .rounded)).padding(.top, 6)
                playbackCard
                trialCard
                weightCard
            }
            .padding(.bottom, 16)
        }
        .onAppear {
            lab.load()
            if lab.outputUID == nil {
                lab.outputUID = (headphones.first { $0.transport == .bluetooth && $0.name.localizedCaseInsensitiveContains("airpods") }
                                 ?? headphones.first { $0.transport == .bluetooth })?.uid
            }
        }
        .onDisappear { lab.stop(); resonance.stop() }
    }

    // MARK: Cards

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("울림 지수 고르기").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("후보 정의 하나를 고르고 슬라이더를 움직이세요. 왼쪽 끝은 그 정의로 울림이 가장 작게 나오는 지연 설정, 오른쪽 끝은 크게 나오는 설정에서 테스트 음원을 들은 소리입니다. 에어팟을 끼고, 슬라이더가 귀로 느끼는 울림과 가장 잘 맞는 후보가 어느 것인지 알려 주세요.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(ResonanceMetric.allCases) { m in
                    Button { resonance.metric = m } label: {
                        let on = resonance.metric == m
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Theme.cyan : Theme.text3)
                                Text(m.title).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                            }
                            if on { Text(m.summary).font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(on ? 0.1 : 0.04)))
                    }
                    .buttonStyle(.plain)
                }
            }
            sliderBlock
            if let m = resonance.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.pink) }
        }
        .padding(16).card()
    }

    private var sliderBlock: some View {
        let metric = resonance.metric
        let device = headphones.first { $0.uid == lab.outputUID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("장치").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Picker("", selection: Binding(get: { lab.outputUID ?? "" }, set: { lab.outputUID = $0.isEmpty ? nil : $0 })) {
                    Text("선택").tag("")
                    ForEach(headphones, id: \.uid) { Text("\($0.name) · \($0.transport.label)").tag($0.uid) }
                }
                .labelsHidden().frame(maxWidth: 300).disabled(resonance.playing)
                chip(resonance.playing ? "정지" : (resonance.preparing ? "준비 중…" : "재생"), selected: resonance.playing,
                     enabled: resonance.playing || (!resonance.preparing && device != nil && !model.running)) {
                    if resonance.playing { resonance.stop() }
                    else if let d = device {
                        resonance.setRoom(lab.chosenRoom, name: roomName)
                        resonance.play(on: d)
                    }
                }
            }
            HStack(spacing: 10) {
                Text("음량").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Slider(value: $resonance.volume, in: 0.05...1).frame(maxWidth: 240).tint(Theme.cyan)
                Text("\(Int(resonance.volume * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text2)
            }
            if model.running { Text("지금 라우팅 중입니다. 정지하면 재생할 수 있습니다.").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.pink) }
            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                Text("덜 울림").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                Slider(value: Binding(get: { Double(resonance.position) }, set: { resonance.position = Int($0.rounded()) }),
                       in: 0...Double(ResonanceLab.steps - 1), step: 1)
                    .tint(Theme.cyan).disabled(!resonance.playing)
                Text("많이 울림").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            }
            HStack {
                Text("단계 \(resonance.position + 1) / \(ResonanceLab.steps)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3)
                Spacer()
                if let v = resonance.currentValue {
                    Text(String(format: "%.\(metric.digits)f", v) + (metric.unit.isEmpty ? "" : " " + metric.unit))
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                }
            }
            Text("방은 아래 '방 모델' 선택을 따릅니다. 에어팟 외 다른 장치에서도 재생되지만 스피커가 아니라 헤드폰으로 들어야 합니다. 후보를 바꾸면 새로 만드느라 몇 초 걸립니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var roomCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("방 모델").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                chip("내 방 (마지막 캘리브레이션)", selected: lab.roomChoice == .mine, enabled: lab.hasMyRoom) { lab.chooseRoom(.mine) }
                chip("합성 방", selected: lab.roomChoice == .synthetic) { lab.chooseRoom(.synthetic) }
            }
            Text(lab.hasMyRoom ? "캘리브레이션에서 식별한 내 방의 스피커 응답을 씁니다."
                               : "아직 캘리브레이션한 방이 없습니다. 합성한 방으로 시험합니다 (캘리브레이션을 한 번 하면 내 방을 쓸 수 있습니다).")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).card()
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("재생").font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 10) {
                Text("장치").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Picker("", selection: Binding(get: { lab.outputUID ?? "" }, set: { lab.outputUID = $0.isEmpty ? nil : $0 })) {
                    Text("선택").tag("")
                    ForEach(headphones, id: \.uid) { Text("\($0.name) · \($0.transport.label)").tag($0.uid) }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            HStack(spacing: 10) {
                Text("음량").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Slider(value: $lab.volume, in: 0.05...1).frame(maxWidth: 240).tint(Theme.cyan)
                Text("\(Int(lab.volume * 100))%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text2)
            }
            Text("귀를 보호하려고 낮게 시작합니다. 스피커가 아니라 헤드폰으로 들어야 합니다. 라우팅이 켜져 있으면 정지한 뒤 쓰세요.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            if model.running {
                Text("지금 라우팅 중입니다. 정지하면 재생할 수 있습니다.").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.pink)
            }
        }
        .padding(16).card()
    }

    private var trialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("A / B 비교").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("투표 \(lab.votes.count)개").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            if lab.trial == nil {
                HStack(spacing: 10) {
                    chip(lab.preparing ? "준비 중…" : "시험 시작", selected: false, enabled: !lab.preparing && lab.outputUID != nil && !model.running) {
                        lab.nextTrial(devices: model.outputDevices)
                    }
                    if lab.outputUID == nil { Text("재생 장치를 먼저 고르세요").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                }
            } else {
                HStack(spacing: 8) {
                    chip("A 듣기", selected: lab.playing == .a) { lab.play(.a, devices: model.outputDevices) }
                    chip("B 듣기", selected: lab.playing == .b) { lab.play(.b, devices: model.outputDevices) }
                    chip("정지", selected: false) { lab.stop() }
                }
                Text("A와 B는 같은 위치에서 이어서 바뀝니다. 몇 번 오가며 들어 보세요.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                HStack(spacing: 8) {
                    Text("어느 쪽이 덜 울리나요?").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    chip("A", selected: false, enabled: !lab.preparing) { lab.vote(.a, room: roomName, devices: model.outputDevices) }
                    chip("B", selected: false, enabled: !lab.preparing) { lab.vote(.b, room: roomName, devices: model.outputDevices) }
                    chip("차이 없음", selected: false, enabled: !lab.preparing) { lab.vote(.same, room: roomName, devices: model.outputDevices) }
                }
            }
            if let m = lab.message { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.pink) }
        }
        .padding(16).card()
    }

    private var weightCard: some View {
        let f = lab.fit
        let enough = f.decisive >= 10
        let changed = abs(f.weight - lab.lateWeight) >= 0.5
        return VStack(alignment: .leading, spacing: 10) {
            Text("가중치 λ").font(.system(size: 12.5, weight: .semibold))
            Text("울림 지수 = 대역 dB 분산 + λ × 늦은 에너지 비율. 지금 \(fmt(lab.lateWeight)) (기본 \(fmt(RoomOptimizer.defaultLateWeight))).")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            if f.decisive == 0 {
                Text("투표가 쌓이면 여기서 제안값을 계산합니다. 10개 이상부터 적용할 수 있고, 많을수록 믿을 만합니다.")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("판정한 투표 \(f.decisive)개 (차이 없음 \(f.same)개) → 제안 λ = \(fmt(f.weight))")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.cyan)
                Text("귀의 선택과 일치: 제안값 \(Int((f.agreementAtFit * 100).rounded()))% · 기본값 \(Int((f.agreementAtDefault * 100).rounded()))%")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                if !enough { Text("아직 \(10 - f.decisive)개 더 필요합니다.").font(.system(size: 11)).foregroundStyle(Theme.text3) }
            }
            HStack(spacing: 8) {
                chip("제안값 적용", selected: false, enabled: enough && changed && model.calPhase == .idle) { lab.applyFit() }
                chip("기본값(\(fmt(RoomOptimizer.defaultLateWeight)))으로", selected: false,
                     enabled: abs(lab.lateWeight - RoomOptimizer.defaultLateWeight) >= 0.5 && model.calPhase == .idle) { lab.resetWeight() }
                chip("투표 기록 지우기", selected: false, enabled: !lab.votes.isEmpty) { lab.clearVotes() }
            }
            Text("적용한 값은 이후 모든 캘리브레이션의 점수 계산에 쓰이고 앱을 껐다 켜도 유지됩니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .padding(16).card()
    }

    private func fmt(_ v: Double) -> String { String(format: "%.0f", v) }

    private func chip(_ text: String, selected: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.9)) : AnyShapeStyle(Color.white.opacity(0.09))))
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
    }
}

