## 2024-05-18 - Caching dlopen and Arrays in High-Frequency Polling
**Learning:** Functions called on a frequent timer (e.g. `ActivityMonitorService` ticking every 5 seconds) should not perform expensive operations like `dlopen`, symbol resolution (`dlsym`), or constantly reallocate static collections (`Set` and `Array`).
**Action:** Always hoist configuration arrays/sets to `static let` properties and cache dynamically loaded pointers (like `IOHIDEventSystemClient`) during initialization to avoid repeated allocations and kernel calls in hot paths.

## 2026-10-28 - Avoid array reallocations in fast paths
**Learning:** Arrays created in frequently called methods like `containsDopamineStreamingOrSocialKeyword` and `readActiveChromiumTab` cause repeated memory allocations in Swift which slows down fast paths.
**Action:** Always hoist local array literals inside frequently called loops or monitoring ticks to static constants (`private static let`) in their respective classes or namespaces to reuse the same memory.

## 2026-11-02 - Offload Continuous Mascot Motion to CoreAnimation & Detach Closed Windows (#70)
**Learning:** SwiftUI `TimelineView`, `PhaseAnimator`, and `.animation(.repeatForever(...))` on `.offset(...)` / `.transformEffect(...)` trigger in-process 120Hz `UpdateCycle` passes (`ViewGraphRootValueUpdater` + `-[NSView setFrameOrigin:]`) on ProMotion Macs (~15–42% CPU). Additionally, `NSWindow` with `isReleasedWhenClosed = false` keeps its `NSHostingController` view tree active in the background when closed, and `Canvas` with `GraphicsContext.draw(Text(...))` runs CoreText + Metal `RenderBox` submissions every frame.
**Action:** Drive continuous animations out-of-process via `CALayer` `CABasicAnimation` / `CAAnimationGroup` (`LiveBitzCharacterView`), set `sizingOptions = []` on fixed-size `NSHostingView`s (never on dynamic `SpeechBubblePanel`), detach `contentViewController = nil` when secondary windows close (`SettingsWindowManager`), isolate polling `@ObservedObject`s to `Equatable` leaf views, and cache active `IOHIDServiceClient` thermal handles + browser session `modificationDate`s.
