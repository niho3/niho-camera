import SwiftUI

/// NIHO の配色。kamakura.niho.life と NIHO の小石マークの 6 色に合わせる。
///
/// 画面は白地にし、文字は焦げ茶寄り、主操作と選択は緑、補助は紺にする。
/// 色は意味と焦点にだけ使い、面を塗りつぶさない。エラーと削除にはブランド色を
/// 使わない。文字に使う色は白地で 4.5:1 以上になる濃さにしてある。
enum NihoPalette {
    // MARK: 面

    /// 窓・写真一覧・調整パネル・上下のバー。
    static let canvas = Color.white
    /// 写真の後ろ。白に近い生成りにして、明るい写真でも縁が消えないようにする。
    static let photoStage = Color(nihoHex: 0xF6F3EE)
    /// フィルムストリップの帯。
    static let filmstrip = Color(nihoHex: 0xFAF7F2)
    /// トーンカーブなどの描画面。
    static let well = Color(nihoHex: 0xFAF8F4)
    /// 区切り線。
    static let line = Color(nihoHex: 0x5D4335, opacity: 0.14)

    // MARK: 文字

    static let ink = Color(nihoHex: 0x333333)
    /// 見出し（焦げ茶）。
    static let heading = Color(nihoHex: 0x5D4335)
    /// 補足の文字。
    static let muted = Color(nihoHex: 0x76665C)

    // MARK: 焦点・意味

    /// 主操作・選択・適用中。
    static let green = Color(nihoHex: 0x4D724F)
    static let navy = Color(nihoHex: 0x4D5E72)
    /// RAW の目印など、珊瑚色を文字や記号に使うときの濃さ。
    static let coralInk = Color(nihoHex: 0xB65E47)
    /// 近似・未校正などの注意。
    static let caution = Color(nihoHex: 0x8A6420)
    /// エラー・削除。
    static let danger = Color(nihoHex: 0xB8443A)

    // MARK: 淡い面（チップ・タイル）

    static let coralTint = Color(nihoHex: 0xFBEDE9)
    static let skyTint = Color(nihoHex: 0xEAF3F6)
    static let creamTint = Color(nihoHex: 0xF5EFE6)

    /// Metal の直接表示で写真の外側を塗る色（`photoStage` と同じ）。
    static let photoStageRGB: (red: Double, green: Double, blue: Double) = (
        red: Double(0xF6) / 255, green: Double(0xF3) / 255, blue: Double(0xEE) / 255
    )
}

extension Color {
    init(nihoHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// NIHO の区切り線（system の Divider を茶色の細線に置き換える）。
struct NihoDivider: View {
    var body: some View {
        Divider().overlay(NihoPalette.line)
    }
}

/// 上部バーの状態チップ（未校正・近似・検証中など）。
struct NihoChip: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }
}
