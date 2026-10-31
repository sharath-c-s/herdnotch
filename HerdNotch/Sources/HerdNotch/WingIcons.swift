import HerdPanelUI
import NotchCore
import SwiftUI

/// Particles that rise above their host and fade, driven by one repeating keyframe track for all of them
/// (no timers). Draws in an overlay so the host's layout size is unchanged; the rise stays within a few
/// points so it fits the wing's headroom. Nothing is drawn under Reduce Motion.
private struct RisingParticles: View {
    enum Style { case steam, sparkle }

    let style: Style
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            Color.clear
                .frame(width: 12, height: 1)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { _, progress in
                    ParticleField(style: style, color: color, progress: progress)
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: 2.4)
                }
        }
    }
}

private struct ParticleField: View {
    let style: RisingParticles.Style
    let color: Color
    let progress: Double

    private static let count = 3
    private static let rise: CGFloat = 8

    var body: some View {
        ZStack {
            ForEach(0..<Self.count, id: \.self) { index in
                particle(index)
            }
        }
    }

    @ViewBuilder
    private func particle(_ index: Int) -> some View {
        let phase = (progress + Double(index) / Double(Self.count)).truncatingRemainder(dividingBy: 1)
        let fade = sin(phase * .pi)
        let x = CGFloat(index - 1) * 4
        switch style {
        case .steam:
            Capsule().fill(color).frame(width: 1.5, height: 4)
                .offset(x: x + CGFloat(sin(phase * 2 * .pi)), y: -phase * Self.rise)
                .opacity(fade * 0.7)
        case .sparkle:
            Circle().fill(color).frame(width: 1.8, height: 1.8)
                .offset(x: x, y: -phase * Self.rise)
                .opacity(fade)
        }
    }
}

/// The keep-awake cup: outline when off; filled amber with steam for manual/condition holds; palette
/// "working" tint with sparkles when only busy agents hold it; a blue moon badge while lid mode is armed.
struct KeepAwakeCup: View {
    let active: Bool
    let reason: KeepAwakeReason
    let lidMode: Bool
    let isNotched: Bool
    let palette: HerdPalette

    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.28)

    private var agentOnly: Bool { reason == .agent }

    private var tint: Color {
        guard active, reason != .off else { return isNotched ? Color.white.opacity(0.4) : palette.textSecondary }
        return agentOnly ? palette.working : Self.amber
    }

    var body: some View {
        let on = active && reason != .off
        Image(systemName: on ? "cup.and.saucer.fill" : "cup.and.saucer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .overlay(alignment: .top) {
                if on { RisingParticles(style: agentOnly ? .sparkle : .steam, color: tint) }
            }
            .overlay(alignment: .bottomTrailing) {
                if on, lidMode {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.blue)
                        .offset(x: 3, y: 3)
                }
            }
    }
}

/// Input-needed marker: a hand that waves from the wrist a couple of times, pauses, and repeats, over a
/// pulsing red halo. Static (hand only, no halo motion) under Reduce Motion.
struct WavingHand: View {
    let isNotched: Bool
    let palette: HerdPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            halo
            hand
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var halo: some View {
        if reduceMotion {
            Circle().fill(palette.blocked.opacity(0.35)).frame(width: 14, height: 14)
        } else {
            Circle().fill(palette.blocked)
                .frame(width: 14, height: 14)
                .keyframeAnimator(initialValue: 0.0, repeating: true) { view, progress in
                    view.scaleEffect(0.7 + 0.35 * progress).opacity(0.55 * (1 - progress))
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: 1.2)
                }
        }
    }

    @ViewBuilder
    private var hand: some View {
        let glyph = Image(systemName: "hand.wave.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isNotched ? Color.white : palette.textPrimary)
        if reduceMotion {
            glyph
        } else {
            glyph.keyframeAnimator(initialValue: 0.0, repeating: true) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-15, duration: 0.15)
                    CubicKeyframe(20, duration: 0.2)
                    CubicKeyframe(-15, duration: 0.2)
                    CubicKeyframe(20, duration: 0.2)
                    CubicKeyframe(0, duration: 0.15)
                    LinearKeyframe(0, duration: 1.5)
                }
            }
        }
    }
}
