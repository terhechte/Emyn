import CoreGraphics

public struct WindowControlMapping: Equatable, Sendable {
    public let viewRect: CGRect
    public let targetRect: CGRect

    public init(viewRect: CGRect, targetRect: CGRect) {
        self.viewRect = viewRect
        self.targetRect = targetRect
    }
}

/// Converts the window rectangle rendered in a video preview into the matching
/// target-window rectangle used for mouse-event forwarding.
public enum WindowPointerMapper {
    public static func mapping(
        for windowBounds: CGRect,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        outputSize: CGSize,
        viewBounds: CGRect
    ) -> WindowControlMapping? {
        guard windowBounds.width > 0,
              windowBounds.height > 0,
              outputSize.width > 0,
              outputSize.height > 0 else {
            return nil
        }

        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let fittedRect = fittedContentRect(
            contentSize: windowBounds.size,
            fit: fit,
            alignment: alignment,
            outputExtent: outputExtent
        )

        let outputControlRect: CGRect
        let targetRect: CGRect
        switch fit {
        case .fill:
            outputControlRect = outputExtent
            targetRect = visibleTargetRect(
                for: windowBounds,
                fittedRect: fittedRect,
                outputExtent: outputExtent
            )
        case .contain:
            outputControlRect = fittedRect.intersection(outputExtent)
            targetRect = windowBounds
        case .scale:
            outputControlRect = outputExtent
            targetRect = windowBounds
        }

        guard !outputControlRect.isNull,
              outputControlRect.width > 0,
              outputControlRect.height > 0,
              targetRect.width > 0,
              targetRect.height > 0 else {
            return nil
        }

        return WindowControlMapping(
            viewRect: viewRect(
                forOutputRect: outputControlRect,
                outputSize: outputSize,
                viewBounds: viewBounds
            ),
            targetRect: targetRect
        )
    }

    public static func fittedContentRect(
        contentSize: CGSize,
        fit: BackgroundMediaFit,
        alignment: BackgroundContentAlignment,
        outputExtent: CGRect
    ) -> CGRect {
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch fit {
        case .fill:
            let scale = max(outputExtent.width / contentSize.width, outputExtent.height / contentSize.height)
            scaleX = scale
            scaleY = scale
        case .contain:
            let scale = min(outputExtent.width / contentSize.width, outputExtent.height / contentSize.height)
            scaleX = scale
            scaleY = scale
        case .scale:
            scaleX = outputExtent.width / contentSize.width
            scaleY = outputExtent.height / contentSize.height
        }

        let scaledSize = CGSize(
            width: contentSize.width * scaleX,
            height: contentSize.height * scaleY
        )
        return CGRect(
            origin: alignment.origin(for: scaledSize, in: outputExtent),
            size: scaledSize
        )
    }

    public static func visibleTargetRect(
        for windowBounds: CGRect,
        fittedRect: CGRect,
        outputExtent: CGRect
    ) -> CGRect {
        let visibleOutputRect = fittedRect.intersection(outputExtent)
        guard !visibleOutputRect.isNull,
              fittedRect.width > 0,
              fittedRect.height > 0 else {
            return windowBounds
        }

        let scaleX = fittedRect.width / windowBounds.width
        let scaleY = fittedRect.height / windowBounds.height
        guard scaleX > 0, scaleY > 0 else {
            return windowBounds
        }

        let visibleMinX = max(0, (visibleOutputRect.minX - fittedRect.minX) / scaleX)
        let visibleMaxX = min(windowBounds.width, (visibleOutputRect.maxX - fittedRect.minX) / scaleX)
        let visibleMinYFromBottom = max(0, (visibleOutputRect.minY - fittedRect.minY) / scaleY)
        let visibleMaxYFromBottom = min(windowBounds.height, (visibleOutputRect.maxY - fittedRect.minY) / scaleY)

        let visibleWidth = max(0, visibleMaxX - visibleMinX)
        let visibleHeight = max(0, visibleMaxYFromBottom - visibleMinYFromBottom)
        guard visibleWidth > 0, visibleHeight > 0 else {
            return windowBounds
        }

        return CGRect(
            x: windowBounds.minX + visibleMinX,
            y: windowBounds.minY + windowBounds.height - visibleMaxYFromBottom,
            width: visibleWidth,
            height: visibleHeight
        )
    }

    public static func viewRect(
        forOutputRect outputRect: CGRect,
        outputSize: CGSize,
        viewBounds: CGRect
    ) -> CGRect {
        let videoRect = aspectFitRect(contentSize: outputSize, in: viewBounds)
        let scaleX = videoRect.width / outputSize.width
        let scaleY = videoRect.height / outputSize.height

        return CGRect(
            x: videoRect.minX + outputRect.minX * scaleX,
            y: videoRect.minY + outputRect.minY * scaleY,
            width: outputRect.width * scaleX,
            height: outputRect.height * scaleY
        )
    }

    public static func aspectFitRect(contentSize: CGSize, in container: CGRect) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              container.width > 0,
              container.height > 0 else {
            return container
        }

        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: container.midX - size.width * 0.5,
            y: container.midY - size.height * 0.5,
            width: size.width,
            height: size.height
        )
    }
}
