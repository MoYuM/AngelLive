//
//  GifAnimator.swift
//  DanmakuKit
//
//  Created by Q YiZhong on 2021/9/3.
//

#if canImport(UIKit)
import Foundation
import ImageIO
import QuartzCore
import os.lock

/// This is a class for managing GIF animations.
/// If you want to customize GIF DanmakuCell, you can refer to this class or use it.
///
/// 隔离模型:公开 API(prepare/start/stop/回调)全部主线程驱动(CADisplayLink 挂 .main,
/// 调用方 DanmakuGifCell 是 UIView 世界),故类收口 @MainActor;帧解码在后台队列进行,
/// 只经由 nonisolated static 函数 + 值快照 + Sendable 的 SafeArray 交互,不回触 self。
@MainActor
public class GifAnimator {
    /// Total animation frames.
    public private(set) var frameCount: Int = 0
    /// The duration of an animation loop.
    public private(set) var loopDuration: TimeInterval = 0
    /// The maximum duration of an animation frame, default is 1.0s.
    public var maxFrameDuration: TimeInterval = 1.0
    /// Decode image in background, default is true.
    public var backgroundDecode = true
    public var isLastFrame: Bool { currentFrameIndex == frameCount - 1 }
    public private(set) var currentFrameIndex = 0 {
        didSet { previousFrameIndex = oldValue }
    }
    public var currentFrameImage: CGImage? { frames[currentFrameIndex]?.image }
    /// The duration of the current frame.
    public var currentFrameDuration: TimeInterval { frames[currentFrameIndex]?.duration ?? .infinity }
    /// Called when the GIF animation has finished playing.
    public var didFinishAnimation: (() -> Void)?
    /// When the screen is updated, the image that should be displayed in the GIF is returned.
    public var update: ((_: CGImage?) -> Void)?

    private let imageSource: CGImageSource
    private let preloadCount: Int
    private let imageSize: CGSize
    private let imageScale: CGFloat
    private let maxRepeatCount: Int
    private var frames = SafeArray<GifFrame>()
    private var currentRepeatCount: UInt = 0
    private var timeSinceLastFrameChange: TimeInterval = 0.0
    private var previousFrameIndex = 0 {
        didSet {
            // 在主 actor 上固化快照,后台只做解码与写入 Sendable 容器
            let frames = self.frames
            let previousIndex = previousFrameIndex
            let preloadIndexes = preloadIndexes(start: currentFrameIndex)
            let source = ImageSourceBox(source: imageSource)
            let imageSize = self.imageSize
            let backgroundDecode = self.backgroundDecode
            queue.async {
                autoreleasepool {
                    frames[previousIndex] = frames[previousIndex]?.placeholderFrame
                    for index in preloadIndexes {
                        guard let currentFrame = frames[index], currentFrame.isPlaceholder else { continue }
                        let image = Self.frame(at: index, source: source.source, imageSize: imageSize, backgroundDecode: backgroundDecode)
                        frames[index] = GifFrame(image: image, duration: currentFrame.duration)
                    }
                }
            }
        }
    }
    private var isReachMaxRepeatCount: Bool { currentRepeatCount >= maxRepeatCount }
    private static var pool: DanmakuQueuePool?

    /// ImageIO 明确保证 CGImageSource 可跨线程使用,但 SDK 未标注 Sendable;
    /// 此盒仅用于把 imageSource 递交给解码队列,禁止外移、禁止承载其他类型。
    private struct ImageSourceBox: @unchecked Sendable {
        let source: CGImageSource
    }

    public init(imageSource source: CGImageSource,
                preloadCount count: Int,
                imageSize size: CGSize,
                imageScale scale: CGFloat,
                maxRepeatCount repeatCount: Int) {
        imageSource = source
        preloadCount = count
        imageSize = size
        imageScale = scale
        maxRepeatCount = repeatCount
    }

    // 持有方 DanmakuGifCell 在主线程释放,isolated deinit 只是把事实告知编译器
    isolated deinit {
        displayLink.invalidate()
    }

    /// Prepare GIF resource.
    public func prepare() {
        frameCount = CGImageSourceGetCount(imageSource)
        frames.reserveCapacity(frameCount)
        let frames = self.frames
        let frameCount = self.frameCount
        let maxFrameDuration = self.maxFrameDuration
        let preloadCount = self.preloadCount
        let source = ImageSourceBox(source: imageSource)
        let imageSize = self.imageSize
        let backgroundDecode = self.backgroundDecode
        queue.async { [weak self] in
            frames.removeAll()
            var duration: TimeInterval = 0
            for i in 0..<frameCount {
                let frameDuration = Self.getFrameDuration(from: source.source, at: i)
                duration += min(frameDuration, maxFrameDuration)
                if i > preloadCount {
                    frames.append(GifFrame(image: nil, duration: frameDuration))
                    break
                } else {
                    let image = Self.frame(at: i, source: source.source, imageSize: imageSize, backgroundDecode: backgroundDecode)
                    frames.append(GifFrame(image: image, duration: frameDuration))
                }
            }
            let loopDuration = duration
            Task { @MainActor in
                self?.loopDuration = loopDuration
            }
        }
    }

    public func startAnimation() {
        displayLink.isPaused = false
    }

    public func stopAnimation() {
        displayLink.isPaused = true
        didFinishAnimation?()
    }

    private func onScreenUpdate() {
        let duration: CFTimeInterval
        if #available(iOS 10.0, tvOS 10.0, macOS 10.15, *) {
            let preferredFramesPerSecond = displayLink.preferredFramesPerSecond
            duration = preferredFramesPerSecond == 0 ? displayLink.duration : 1.0 / TimeInterval(preferredFramesPerSecond)
        } else {
            duration = displayLink.duration
        }
        timeSinceLastFrameChange += min(maxFrameDuration, duration)
        guard timeSinceLastFrameChange >= currentFrameDuration else { return }

        timeSinceLastFrameChange -= currentFrameDuration
        currentFrameIndex = increment(frameIndex: currentFrameIndex)
        if isLastFrame {
            currentRepeatCount += 1
            if isReachMaxRepeatCount {
                stopAnimation()
            }
        }
        update?(currentFrameImage)
    }

    private nonisolated static func frame(at index: Int, source: CGImageSource, imageSize: CGSize, backgroundDecode: Bool) -> CGImage? {
        let resize = imageSize != .zero
        let options: [CFString: Any]?
        if resize {
            options = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(imageSize.width, imageSize.height)
            ]
        } else {
            options = nil
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary?) else {
            return nil
        }
        return backgroundDecode ? decodedImage(from: cgImage) : cgImage
    }

    private nonisolated static func decodedImage(from cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = cgImage.bitmapInfo == [] ? CGImageAlphaInfo.premultipliedLast.rawValue : cgImage.bitmapInfo.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return cgImage }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func increment(frameIndex: Int, by value: Int = 1) -> Int {
        (frameIndex + value) % frameCount
    }

    private func preloadIndexes(start index: Int) -> [Int] {
        let nextIndex = increment(frameIndex: index)
        let lastIndex = increment(frameIndex: index, by: preloadCount)
        if lastIndex >= nextIndex {
            return [Int](nextIndex...lastIndex)
        } else {
            return [Int](nextIndex..<frameCount) + [Int](0...lastIndex)
        }
    }

    private nonisolated static func getFrameDuration(from imageSource: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [String: Any] else { return 0.0 }
        let defaultFrameDuration = 0.1
        guard let gifInfo = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any] else { return defaultFrameDuration }
        let unclampedDelayTime = gifInfo[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber
        let delayTime = gifInfo[kCGImagePropertyGIFDelayTime as String] as? NSNumber
        let duration = unclampedDelayTime ?? delayTime
        guard let frameDuration = duration else { return defaultFrameDuration }
        return frameDuration.doubleValue > 0.011 ? frameDuration.doubleValue : defaultFrameDuration
    }

    private func createPoolIfNeeded() {
        guard GifAnimator.pool == nil else { return }
        GifAnimator.pool = DanmakuQueuePool(name: "com.DanmakuKit.GifAnimator", queueCount: 8, qos: .userInteractive)
    }

    private var queue: DispatchQueue {
        createPoolIfNeeded()
        return GifAnimator.pool?.queue ?? DispatchQueue(label: "com.DanmakuKit.GifAnimator")
    }

    private lazy var displayLink: CADisplayLink = {
        let displayLink = CADisplayLink(target: TargetProxy(target: self), selector: #selector(TargetProxy.onScreenUpdate))
        displayLink.add(to: .main, forMode: .common)
        displayLink.isPaused = true
        return displayLink
    }()
}

// MARK: GifFrame

extension GifAnimator {
    struct GifFrame: Sendable {
        let image: CGImage?
        let duration: TimeInterval
        var isPlaceholder: Bool { image == nil }
        var placeholderFrame: GifFrame { GifFrame(image: nil, duration: duration) }
    }

    // CADisplayLink 挂在 .main RunLoop,selector 必在主线程触发
    @MainActor
    class TargetProxy: NSObject {
        private weak var target: GifAnimator?
        init(target: GifAnimator) { self.target = target }
        @objc func onScreenUpdate() {
            target?.onScreenUpdate()
        }
    }
}

/// 后台解码队列与主线程共享的帧容器。内部状态全部收在 `OSAllocatedUnfairLock` 里,
/// 该类型自身即 `Sendable`,故无需 `@unchecked` 逃生舱(与 `Sentinel` 同款)。
fileprivate final class SafeArray<Element: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [Element]())

    subscript(index: Int) -> Element? {
        get {
            storage.withLock { $0.indices ~= index ? $0[index] : nil }
        }
        set {
            storage.withLock {
                if let newValue = newValue, $0.indices ~= index {
                    $0[index] = newValue
                }
            }
        }
    }

    var count: Int {
        storage.withLock { $0.count }
    }

    func reserveCapacity(_ count: Int) {
        storage.withLock { $0.reserveCapacity(count) }
    }

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    func removeAll() {
        storage.withLock { $0 = [] }
    }
}
#endif
