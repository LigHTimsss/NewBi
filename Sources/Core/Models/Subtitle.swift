import Foundation

struct SubtitleTrack: Decodable, Identifiable, Sendable {
    let lan: String
    let lan_doc: String
    let subtitle_url: String
    let ai_type: Int?
    var id: String { lan + "|" + subtitle_url }
    var isAI: Bool { lan.hasPrefix("ai-") || (ai_type ?? 0) > 0 }
    /// 保留平台的语言名称及自动生成/翻译标注，不自行追加来源后缀。
    var title: String { lan_doc }
}

struct SubtitleList: Decodable, Sendable { let subtitles: [SubtitleTrack]? }
struct SubtitleDocument: Decodable, Sendable {
    let body: [SubtitleCue]
}
struct SubtitleCue: Decodable, Sendable {
    let from: Double
    let to: Double
    let content: String
}

