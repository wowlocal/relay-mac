import Foundation
import CoreVideo
import Metal
import SwiftSignalKit
import MetalEngine
import CallVideoLayer
import RelayCalls

struct RelayVideoTarget: Equatable {
    var trackSid: String
    var mirrored: Bool
}

final class LiveKitVideoSource: VideoSource {
    private let queue = Queue(name: "LiveKitVideoSource")
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var listeners = Bag<() -> Void>()
    private let mirrored = Atomic<Bool>(value: false)
    private let pendingFrame = Atomic<Bool>(value: false)
    private(set) var currentOutput: Output?

    private weak var engine: RelayRoomEngine?
    private let resolveTarget: @MainActor () -> RelayVideoTarget?
    private var sink: RelayVideoSink?
    private(set) var attachedSid: String?
    private let framesReceived = Atomic<Int>(value: 0)
    private let lastFrameSize = Atomic<CGSize>(value: .zero)
    private(set) var framesDelivered = 0
    let label: String

    @MainActor
    init(engine: RelayRoomEngine, viewSize: CGSize, label: String, resolveTarget: @escaping @MainActor () -> RelayVideoTarget?) {
        self.label = label
        self.engine = engine
        self.resolveTarget = resolveTarget
        self.device = MetalEngine.shared.device
        CVMetalTextureCacheCreate(nil, nil, self.device, nil, &self.textureCache)
        let sink = RelayVideoSink(onFrame: { [weak self] frame in
            self?.received(frame)
        })
        sink.viewSize = viewSize
        self.sink = sink
        self.refresh()
    }

    @MainActor
    func refresh() {
        guard let engine = self.engine, let sink = self.sink else {
            return
        }
        let target = self.resolveTarget()
        if let target {
            _ = self.mirrored.swap(target.mirrored)
        }
        if self.attachedSid != nil, self.attachedSid != target?.trackSid || engine.videoTrack(sid: self.attachedSid!) == nil {
            engine.detach(sink, fromTrackSid: self.attachedSid!)
            self.attachedSid = nil
        }
        if self.attachedSid == nil, let target, engine.attach(sink, toTrackSid: target.trackSid) {
            self.attachedSid = target.trackSid
        }
    }

    var debugInfo: [String: Any] {
        let size = self.lastFrameSize.with { $0 }
        return ["label": self.label, "trackSid": self.attachedSid ?? NSNull(), "framesReceived": self.framesReceived.with { $0 }, "framesDelivered": self.framesDelivered, "listeners": self.listeners.copyItems().count, "frameWidth": Int(size.width), "frameHeight": Int(size.height)]
    }

    @MainActor
    func setViewSize(_ size: CGSize) {
        self.sink?.viewSize = size
    }

    @MainActor
    func setVisible(_ visible: Bool) {
        self.sink?.isVisible = visible
    }

    func addOnUpdated(_ f: @escaping () -> Void) -> Disposable {
        let index = self.listeners.add(f)
        return ActionDisposable { [weak self] in
            DispatchQueue.main.async {
                self?.listeners.remove(index)
            }
        }
    }

    private func received(_ frame: RelayVideoFrame) {
        _ = self.framesReceived.modify { $0 + 1 }
        _ = self.lastFrameSize.swap(CGSize(width: frame.width, height: frame.height))
        if self.pendingFrame.swap(true) {
            return
        }
        self.queue.async { [weak self] in
            guard let self else {
                return
            }
            let output = self.makeOutput(frame)
            DispatchQueue.main.async {
                _ = self.pendingFrame.swap(false)
                guard let output else {
                    return
                }
                self.currentOutput = output
                self.framesDelivered += 1
                for listener in self.listeners.copyItems() {
                    listener()
                }
            }
        }
    }

    private func makeOutput(_ frame: RelayVideoFrame) -> Output? {
        let rotationAngle: Float
        switch frame.rotation {
        case .rotation0:
            rotationAngle = 0
        case .rotation90:
            rotationAngle = Float.pi * 0.5
        case .rotation180:
            rotationAngle = Float.pi
        case .rotation270:
            rotationAngle = Float.pi * 1.5
        }
        let mirrored = self.mirrored.with { $0 }
        let mirrorDirection: Output.MirrorDirection = mirrored ? .horizontal : []
        let sourceId = mirrored ? 1 : 0

        switch frame.buffer {
        case let .pixelBuffer(pixelBuffer):
            guard let textureCache = self.textureCache else {
                return nil
            }
            if CVPixelBufferGetPlaneCount(pixelBuffer) == 2 {
                let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
                let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
                var yRef: CVMetalTexture?
                var status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .r8Unorm, width, height, 0, &yRef)
                guard status == kCVReturnSuccess, let yRef, let yTexture = CVMetalTextureGetTexture(yRef) else {
                    return nil
                }
                var uvRef: CVMetalTexture?
                status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .rg8Unorm, CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &uvRef)
                guard status == kCVReturnSuccess, let uvRef, let uvTexture = CVMetalTextureGetTexture(uvRef) else {
                    return nil
                }
                return Output(resolution: CGSize(width: width, height: height), textureLayout: .biPlanar(Output.BiPlanarTextureLayout(y: yTexture, uv: uvTexture)), dataBuffer: Output.NativeDataBuffer(pixelBuffer: pixelBuffer), rotationAngle: rotationAngle, followsDeviceOrientation: false, mirrorDirection: mirrorDirection, sourceId: sourceId, textureReferences: [yRef, uvRef])
            }
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
                return nil
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var ref: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &ref)
            guard status == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else {
                return nil
            }
            return Output(resolution: CGSize(width: width, height: height), textureLayout: .bgra(Output.BGRATextureLayout(bgra: texture)), dataBuffer: Output.NativeDataBuffer(pixelBuffer: pixelBuffer), rotationAngle: rotationAngle, followsDeviceOrientation: false, mirrorDirection: mirrorDirection, sourceId: sourceId, textureReferences: [ref])
        case let .i420(buffer):
            guard let y = self.planeTexture(width: buffer.width, height: buffer.height),
                  let u = self.planeTexture(width: buffer.chromaWidth, height: buffer.chromaHeight),
                  let v = self.planeTexture(width: buffer.chromaWidth, height: buffer.chromaHeight) else {
                return nil
            }
            buffer.withPlanes { yPlane, uPlane, vPlane in
                y.replace(region: MTLRegionMake2D(0, 0, buffer.width, buffer.height), mipmapLevel: 0, withBytes: yPlane, bytesPerRow: buffer.strideY)
                u.replace(region: MTLRegionMake2D(0, 0, buffer.chromaWidth, buffer.chromaHeight), mipmapLevel: 0, withBytes: uPlane, bytesPerRow: buffer.strideU)
                v.replace(region: MTLRegionMake2D(0, 0, buffer.chromaWidth, buffer.chromaHeight), mipmapLevel: 0, withBytes: vPlane, bytesPerRow: buffer.strideV)
            }
            return Output(resolution: CGSize(width: buffer.width, height: buffer.height), textureLayout: .triPlanar(Output.TriPlanarTextureLayout(y: y, u: u, v: v)), dataBuffer: Output.DataBuffer(), rotationAngle: rotationAngle, followsDeviceOrientation: false, mirrorDirection: mirrorDirection, sourceId: sourceId)
        }
    }

    private func planeTexture(width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0 else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        return self.device.makeTexture(descriptor: descriptor)
    }

    deinit {
        let engine = self.engine
        let sink = self.sink
        let sid = self.attachedSid
        if let engine, let sink, let sid {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    engine.detach(sink, fromTrackSid: sid)
                }
            }
        }
    }
}

final class RelayVideoSourceRegistry {
    private final class Entry {
        weak var source: LiveKitVideoSource?
        init(_ source: LiveKitVideoSource) {
            self.source = source
        }
    }
    private var entries: [Entry] = []

    func add(_ source: LiveKitVideoSource) {
        self.entries = self.entries.filter { $0.source != nil }
        self.entries.append(Entry(source))
    }

    @MainActor
    func refresh() {
        self.entries = self.entries.filter { $0.source != nil }
        for entry in self.entries {
            entry.source?.refresh()
        }
    }

    var sources: [LiveKitVideoSource] {
        return self.entries.compactMap { $0.source }
    }
}
