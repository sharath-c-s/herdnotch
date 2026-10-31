import Foundation

/// A display identity, in the units the AppKit layer's `CGDirectDisplayID` already uses.
///
/// `NotchCore` is a pure Foundation library with no `import CoreGraphics` and no `import AppKit`, so it
/// cannot spell `CGDirectDisplayID` itself. Rather than pull in CoreGraphics for one typealias, this is a
/// plain `UInt32` that the AppKit composition root is expected to construct from
/// `screen.deviceDescription[NSScreenNumber]` (which is itself a `CGDirectDisplayID` in disguise) and pass
/// in as-is. Keeping the underlying type identical means the conversion at the boundary is a bit-for-bit
/// no-op rather than a translation table to keep honest.
public typealias NotchDisplayID = UInt32
