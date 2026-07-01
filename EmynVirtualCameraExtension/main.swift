import CoreMediaIO
import Foundation

let providerSource = EmynVirtualCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
