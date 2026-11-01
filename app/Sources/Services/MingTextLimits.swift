import Foundation

/// Shared by saved prompt settings, the host, and the Codex service boundary.
enum MingTextLimits {
    static let maximumPromptBytes = 16 * 1024
    // Preserve the existing prompt allowance; the additional KiB holds the
    // app's bounded style/length suffix, not extra user prompt content.
    static let maximumInstructionBytes = maximumPromptBytes + 1024
    static let maximumInputBytes = 128 * 1024
    static let instructionTooLongMessage = "当前提示词（含风格和长短）过长，请缩短提示词后再处理；文字与修改仍保留。"
}
