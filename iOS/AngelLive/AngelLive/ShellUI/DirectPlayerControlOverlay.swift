//
//  DirectPlayerControlOverlay.swift
//  AngelLive
//
//  壳 UI 播放器控制层：和 FullUI 的 UnifiedPlayerControlOverlay 视觉风格一致，
//  但去掉了弹幕、清晰度、视频统计等需要 LiveParse 的功能。
//

import SwiftUI
import AngelLiveCore
import AngelLiveDependencies
import UIKit

struct DirectPlayerControlOverlay: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let bridge: PlayerControlBridge

    /// 刷新回调（重新加载 URL）
    var onRefresh: (() -> Void)?
    /// 可直接投屏的直链媒体才传入，用于打开独立的 DLNA 设备选择页。
    var onDLNACast: (() -> Void)?

    @State private var autoHideTask: Task<Void, Never>?
    @State private var statusBarVM = StatusBarViewModel()

    // MARK: - Computed Properties

    private var isLandscape: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .compact ||
        horizontalSizeClass == .regular && verticalSizeClass == .compact
    }

    private var controlPadding: CGFloat {
        isLandscape ? 20 : 12
    }

    var body: some View {
        ZStack {
            // 底部渐变背景（锁定时隐藏）
            if !bridge.isLocked.wrappedValue {
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [
                            .clear,
                            .black.opacity(AppConstants.PlayerUI.Opacity.overlayLight),
                            .black.opacity(AppConstants.PlayerUI.Opacity.overlayStrong)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                }
                .ignoresSafeArea()
                .opacity(bridge.isMaskShow.wrappedValue ? 1 : 0)
                .allowsHitTesting(false)
            }

            // 控制按钮层
            ZStack {
                // 左侧中间：锁定按钮（始终显示）
                lockButton

                // 锁定时隐藏其余所有控制
                if !bridge.isLocked.wrappedValue {
                    // 左上角：返回按钮
                    backButtonLayer

                    // 右上角：状态栏 + PiP
                    topRightLayer

                    // 中间：暂停大按钮
                    if !bridge.isPlaying {
                        Button {
                            bridge.togglePlayPause()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 62, height: 62)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    // 左下角：播放/暂停 + 刷新
                    bottomLeftLayer

                    // 右下角：全屏切换
                    bottomRightLayer
                }
            }
            .padding(controlPadding)
            .opacity(bridge.isMaskShow.wrappedValue ? 1 : 0)
            .allowsHitTesting(bridge.isMaskShow.wrappedValue)
            .ignoresSafeArea(shouldIgnoreSafeArea ? .all : [])
            .simultaneousGesture(
                TapGesture()
                    .onEnded { _ in
                        if bridge.isMaskShow.wrappedValue {
                            startAutoHideTimer()
                        }
                    }
            )
        }
        .tint(.white)
        .onChange(of: bridge.isMaskShow.wrappedValue) { _, isMaskShow in
            if isMaskShow {
                startAutoHideTimer()
            } else {
                cancelAutoHideTimer()
            }
        }
        .onAppear {
            if bridge.isMaskShow.wrappedValue {
                startAutoHideTimer()
            }
        }
        .onDisappear {
            cancelAutoHideTimer()
        }
    }

    private var shouldIgnoreSafeArea: Bool {
        isLandscape && !AppConstants.Device.isIPad
    }

    // MARK: - Lock Button

    private var lockButton: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        bridge.isLocked.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: bridge.isLocked.wrappedValue ? "lock.fill" : "lock.open")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, isLandscape ? 30 : 0)
                Spacer()
            }
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Back Button

    private var backButtonLayer: some View {
        VStack {
            HStack {
                Button {
                    handleBackButton()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: - Top Right (Status Bar + PiP)

    private var topRightLayer: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // 状态栏（仅横屏时显示）
                    if isLandscape {
                        statusBarContent
                    }
                    HStack(spacing: 16) {
                        if let onDLNACast {
                            Button {
                                onDLNACast()
                            } label: {
                                Image(systemName: "tv")
                                    .frame(width: 30, height: 30)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("DLNA 投屏")
                        }

                        if bridge.supportsPictureInPicture {
                            Button {
                                bridge.togglePictureInPicture()
                            } label: {
                                Image(systemName: "pip")
                                    .frame(width: 30, height: 30)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.top, isLandscape ? -controlPadding : 0)
            .padding(.trailing, isLandscape ? -controlPadding / 2 : 0)
            Spacer()
        }
    }

    // MARK: - Bottom Left (Play/Pause + Refresh)

    private var bottomLeftLayer: some View {
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 16) {
                    Button {
                        bridge.togglePlayPause()
                    } label: {
                        Image(systemName: bridge.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 30, height: 30)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onRefresh?()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .frame(width: 30, height: 30)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
        }
    }

    // MARK: - Bottom Right (Fullscreen)

    private var bottomRightLayer: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 16) {
                    Button {
                        toggleOrientation()
                    } label: {
                        Image(systemName: fullscreenIconName)
                            .frame(width: 30, height: 30)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBarContent: some View {
        HStack(spacing: 4) {
            Text(statusBarVM.formattedTime)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Image(systemName: statusBarVM.batteryIconName)
                .font(.system(size: 11))
                .foregroundStyle(statusBarVM.batteryColor)
        }
    }

    // MARK: - Helpers

    private var fullscreenIconName: String {
        isCurrentLandscape
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
    }

    private func handleBackButton() {
        if !AppConstants.Device.isIPad && isCurrentLandscape {
            // iPhone 横屏：先切回竖屏
            KSOptions.supportedInterfaceOrientations = .allButUpsideDown

            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first else { return }

            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)

            // 先通知 ViewController 刷新支持的方向
            if let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // 延迟到下一个 run loop，确保 VC 已刷新支持的方向
            DispatchQueue.main.async {
                windowScene.requestGeometryUpdate(prefs) { _ in }
            }
        } else {
            // 竖屏 / iPad：直接 dismiss
            dismiss()
        }
    }

    private func toggleOrientation() {
        let targetOrientation: UIInterfaceOrientationMask = isCurrentLandscape ? .portrait : .landscapeRight
        KSOptions.supportedInterfaceOrientations = targetOrientation

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetOrientation)

        // 先通知 ViewController 刷新支持的方向
        if let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        // 延迟到下一个 run loop，确保 VC 已刷新支持的方向
        DispatchQueue.main.async {
            windowScene.requestGeometryUpdate(prefs) { _ in }
        }
    }

    private var isCurrentLandscape: Bool {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return false
        }
        return windowScene.interfaceOrientation.isLandscape
    }

    // MARK: - Auto Hide Timer

    private func startAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                bridge.isMaskShow.wrappedValue = false
            }
        }
    }

    private func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }
}
