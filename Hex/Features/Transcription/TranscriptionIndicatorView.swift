//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.

import AppKit
import Inject
import Pow
import SwiftUI

struct TranscriptionIndicatorView: View {
  @ObserveInjection var inject
  
  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    /// The LLM is rewriting the transcript (purple, so slow rewrites are told apart from slow speech-to-text).
    case rewriting
    case prewarming
  }

  var status: Status
  var meter: Meter
  /// A Legacy dictation: a thin multicolour rim turns around the capsule (still with Reduce Motion), and one
  /// shine sweeps it when Legacy switches on. The fill keeps its status colour; a sparkle replaces the level bar.
  var isSuper = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var superSweep = 0

  let transcribeBaseColor: Color = .blue
  let rewriteBaseColor: Color = .purple
  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording:
      return mixedColor(mixedNSColor(.red, with: .black, by: 0.5), with: .red, by: meter.averagePower * 3)
    case .transcribing: return mixedColor(.blue, with: .black, by: 0.5)
    case .rewriting: return mixedColor(.systemPurple, with: .black, by: 0.5)
    case .prewarming: return mixedColor(.blue, with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return mixedColor(.red, with: .white, by: 0.1).opacity(0.6)
    case .transcribing: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
    case .rewriting: return mixedColor(.systemPurple, with: .white, by: 0.1).opacity(0.6)
    case .prewarming: return mixedColor(.blue, with: .white, by: 0.1).opacity(0.6)
    }
  }

  private func mixedColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> Color {
    Color(nsColor: mixedNSColor(color, with: otherColor, by: fraction))
  }

  private func mixedNSColor(_ color: NSColor, with otherColor: NSColor, by fraction: Double) -> NSColor {
    let clampedFraction = min(max(fraction, 0), 1)
    return color.blended(withFraction: clampedFraction, of: otherColor) ?? color
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
    case .transcribing: return transcribeBaseColor
    case .rewriting: return rewriteBaseColor
    case .prewarming: return transcribeBaseColor
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56

  var isHidden: Bool {
    status == .hidden
  }

  private var isWorking: Bool {
    status == .transcribing || status == .rewriting
  }

  @State var transcribeEffect = 0

  var body: some View {
    let averagePower = min(1, meter.averagePower * 3)
    let peakPower = min(1, meter.peakPower * 3)
    ZStack {
      Capsule()
        .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
        .overlay {
          Capsule()
            .stroke(strokeColor, lineWidth: 1)
            .blendMode(.screen)
        }
        .overlay {
          if isSuper && !isHidden {
            SuperRim(isAnimated: !reduceMotion)
              .transition(.opacity)
          }
        }
        .overlay(alignment: .center) {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.red.opacity(status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0))
            .blur(radius: 2)
            .blendMode(.screen)
            .padding(6)
        }
        .overlay(alignment: .center) {
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(status == .recording && !isSuper ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0))
            .blur(radius: 1)
            .blendMode(.screen)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(7)
        }
        .overlay(alignment: .center) {
          // Legacy swaps the level bar for a sparkle that stays through transcribing and rewriting. In the recording
          // pill it's wide, visible while quiet, larger and brighter as the voice rises; in the working circle it's
          // even and dimmer, so the status colour still reads.
          if isSuper && (status == .recording || isWorking) {
            let isRecording = status == .recording
            Sparkle()
              .fill(Color.white.opacity(isRecording ? 0.7 + 0.3 * averagePower : 0.85))
              .blur(radius: 0.4)
              .blendMode(.screen)
              .frame(width: isRecording ? 18 : 9, height: isRecording ? 12 : 9)
              .scaleEffect(isRecording ? 0.9 + 0.35 * averagePower : 1)
              .transition(.scale(scale: 0.4).combined(with: .opacity))
          }
        }
        .overlay(alignment: .center) {
          GeometryReader { proxy in
            RoundedRectangle(cornerRadius: cornerRadius)
              .fill(Color.red.opacity(status == .recording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0))
              .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
              .frame(maxWidth: .infinity, alignment: .center)
              .blur(radius: 4)
              .blendMode(.screen)
          }.padding(6)
        }
        .cornerRadius(cornerRadius)
        .shadow(
          color: status == .recording ? .red.opacity(averagePower) : .red.opacity(0),
          radius: 4
        )
        .shadow(
          color: status == .recording ? .red.opacity(averagePower * 0.5) : .red.opacity(0),
          radius: 8
        )
        .animation(.interactiveSpring(), value: meter)
        .frame(
          width: status == .recording ? expandedWidth : baseWidth,
          height: baseWidth
        )
        .opacity(status == .hidden ? 0 : 1)
        .scaleEffect(status == .hidden ? 0.0 : 1)
        .blur(radius: status == .hidden ? 4 : 0)
        .animation(.bouncy(duration: 0.3), value: status)
        .changeEffect(.glow(color: .red.opacity(0.5), radius: 8), value: status)
        .changeEffect(.shine(angle: .degrees(0), duration: 0.6), value: transcribeEffect)
        .changeEffect(.shine(angle: .degrees(20), duration: 0.7), value: superSweep)
        .animation(.easeOut(duration: 0.2), value: isSuper)
        .compositingGroup()
        .onChange(of: isSuper) { _, isOn in
          if isOn, !reduceMotion { superSweep += 1 }
        }
        .task(id: isWorking) {
          while isWorking, !Task.isCancelled {
            transcribeEffect += 1
            try? await Task.sleep(for: .seconds(0.25))
          }
        }
      
      // Show tooltip when prewarming
      if status == .prewarming {
        VStack(spacing: 4) {
          Text("Model prewarming...")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.8))
            )
        }
        .offset(y: -24)
        .transition(.opacity)
        .zIndex(2)
      }
    }
    .enableInjection()
  }
}

/// Legacy's rim: a low-saturation angular gradient, one turn every 3 s.
private struct SuperRim: View {
  var isAnimated: Bool

  static let period = 3.0
  static let colors: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
    Color(hue: $0.truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 1)
  }

  var body: some View {
    TimelineView(.animation(paused: !isAnimated)) { context in
      let turn = isAnimated
        ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
        : 0
      Capsule()
        .strokeBorder(
          AngularGradient(colors: Self.colors, center: .center, angle: .degrees(turn * 360)),
          lineWidth: 1.5
        )
    }
    .allowsHitTesting(false)
  }
}

/// A four-point star with concave sides (✦): each tip curves to the next through the centre. The tips reach the
/// frame's edges, so a frame wider than it is tall stretches the side arms.
private struct Sparkle: Shape {
  var points = 4

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let tips = (0..<points).map { index in
      let angle = Double(index) / Double(points) * 2 * .pi - .pi / 2
      return CGPoint(x: center.x + rect.width / 2 * cos(angle), y: center.y + rect.height / 2 * sin(angle))
    }
    var path = Path()
    path.move(to: tips[0])
    for index in 1...points {
      path.addQuadCurve(to: tips[index % points], control: center)
    }
    path.closeSubpath()
    return path
  }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.5))
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .rewriting, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.3, peakPower: 0.3), isSuper: true)
    TranscriptionIndicatorView(status: .rewriting, meter: .init(averagePower: 0, peakPower: 0), isSuper: true)
  }
  .padding(40)
}
