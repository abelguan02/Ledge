import ApplicationServices
import CoreGraphics

// Read-only preflight. Never requests permission or captures screen content.
print("Accessibility: \(AXIsProcessTrusted())")
print("Event posting: \(CGPreflightPostEventAccess())")
print("Screen capture: \(CGPreflightScreenCaptureAccess())")
