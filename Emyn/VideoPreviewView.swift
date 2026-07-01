import AVFoundation
import SwiftUI

final class SampleBufferPreviewView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }

        guard renderer.isReadyForMoreMediaData else {
            return
        }

        renderer.enqueue(sampleBuffer)
    }
}

struct VideoPreviewView: NSViewRepresentable {
    @ObservedObject var pipeline: CameraPipeline

    func makeNSView(context: Context) -> SampleBufferPreviewView {
        let view = SampleBufferPreviewView()
        pipeline.previewHandler = { [weak view] sampleBuffer in
            view?.enqueue(sampleBuffer)
        }
        return view
    }

    func updateNSView(_ nsView: SampleBufferPreviewView, context: Context) {
        pipeline.previewHandler = { [weak nsView] sampleBuffer in
            nsView?.enqueue(sampleBuffer)
        }
    }

    static func dismantleNSView(_ nsView: SampleBufferPreviewView, coordinator: ()) {
        nsView.layer = nil
    }
}
