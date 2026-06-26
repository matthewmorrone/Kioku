import SwiftUI

// Per-kanji ambient decoration: an animated layer rendered as the BACKGROUND of the
// entire KanjiDetailView sheet, themed to the kanji's meaning — rain falls across
// the whole sheet for 雨, fire rises behind everything for 火, etc. Unregistered
// kanji return EmptyView and the sheet renders with no background animation.
//
// Implementation split across this file (registry only) and two siblings:
//   • KanjiDecoration+Particles.swift — CAEmitterLayer-based effects (rain, snow,
//     fire) where hardware-accelerated particles look right and SwiftUI Canvas
//     would have to fight the GPU for the same density.
//   • KanjiDecoration+Canvas.swift — SwiftUI Canvas-based effects (the other 12)
//     where geometric/scripted animation is the right tool: bolts, rays, waves,
//     pulses, sweeps.
enum KanjiDecoration {
    // Returns the decoration view for `literal`, or EmptyView when no decoration
    // is registered. @ViewBuilder switch lets each branch be its own concrete
    // View type without per-decoration AnyView wrapping.
    @ViewBuilder
    static func view(for literal: String) -> some View {
        switch literal {
        case "雨": RainDecoration()
        case "雪": SnowDecoration()
        case "火": FireDecoration()
        case "水": WaterDecoration()
        case "日": SunDecoration()
        case "月": MoonDecoration()
        case "星": StarDecoration()
        case "雷": LightningDecoration()
        case "風": WindDecoration()
        case "木": TreeDecoration()
        case "花": FlowerDecoration()
        case "心": HeartDecoration()
        case "音": SoundDecoration()
        case "光": LightDecoration()
        case "海": SeaDecoration()
        // Numbers 零〜十 — visual count via pulsing dots; 零 is the empty ring.
        case "零": ZeroDecoration()
        case "一": NumberDotsDecoration(count: 1)
        case "二": NumberDotsDecoration(count: 2)
        case "三": NumberDotsDecoration(count: 3)
        case "四": NumberDotsDecoration(count: 4)
        case "五": NumberDotsDecoration(count: 5)
        case "六": NumberDotsDecoration(count: 6)
        case "七": NumberDotsDecoration(count: 7)
        case "八": NumberDotsDecoration(count: 8)
        case "九": NumberDotsDecoration(count: 9)
        case "十": NumberDotsDecoration(count: 10)
        // Colors — a field of drifting paint splotches in the kanji's color.
        case "赤": ColorFieldDecoration(palette: KanjiColorPalette.red)
        case "青": ColorFieldDecoration(palette: KanjiColorPalette.blue)
        case "黄": ColorFieldDecoration(palette: KanjiColorPalette.yellow)
        case "緑": ColorFieldDecoration(palette: KanjiColorPalette.green)
        case "黒": ColorFieldDecoration(palette: KanjiColorPalette.black)
        case "白": ColorFieldDecoration(palette: KanjiColorPalette.white)
        // Seasons — each evokes its season's signature: cherry blossoms, heat
        // shimmer, fall leaves, frost.
        case "春": SpringDecoration()
        case "夏": SummerDecoration()
        case "秋": AutumnDecoration()
        case "冬": WinterDecoration()
        // Nature — landscape, weather variants, plant life.
        case "山": MountainDecoration()
        case "川": RiverDecoration()
        case "空": SkyDecoration()
        case "雲": CloudDecoration()
        case "虹": RainbowDecoration()
        case "嵐": StormDecoration()
        case "草": GrassDecoration()
        case "石": StoneDecoration()
        case "田": RiceFieldDecoration()
        case "米": RiceGrainDecoration()
        case "茶": TeaDecoration()
        case "池": PondDecoration()
        case "泉": SpringDecorationSource()
        case "林": WoodsDecoration()
        case "森": ForestDecoration()
        case "葉": LeafDecoration()
        // Beings — animals, body, times of day.
        case "朝": MorningDecoration()
        case "夜": NightDecoration()
        case "夕": EveningDecoration()
        case "鳥": BirdDecoration()
        case "魚": FishDecoration()
        case "馬": HorseDecoration()
        case "犬": DogDecoration()
        case "猫": CatDecoration()
        case "虫": InsectDecoration()
        case "目": EyeDecoration()
        // Abstract — concepts, motion verbs, magnitudes, sound siblings.
        case "力": PowerDecoration()
        case "気": SpiritDecoration()
        case "愛": LoveDecoration()
        case "夢": DreamDecoration()
        case "神": DivineDecoration()
        case "行": GoDecoration()
        case "走": RunDecoration()
        case "飛": FlyDecoration()
        case "上": UpDecoration()
        case "下": DownDecoration()
        case "大": BigDecoration()
        case "小": SmallDecoration()
        case "声": VoiceDecoration()
        case "響": EchoDecoration()
        default: EmptyView()
        }
    }
}

// Deterministic pseudo-random in [0, 1) derived from index + salt. Shared between
// canvas decorations that need stable per-particle parameters across the many
// re-renders TimelineView triggers per second. Real Random() would jitter particles
// every frame because the closure re-runs constantly.
func kanjiSeedFraction(_ index: Int, _ salt: Int) -> Double {
    let h = (index &* 73 &+ salt &* 31) & 0xff
    return Double(h) / 255.0
}

// Full registry of decorated kanji, grouped by category. Used by the Animated
// Kanji debug view to enumerate everything we ship a decoration for. Keep in
// sync with the switch above — adding a case there should also add the literal
// here so it shows up in the debug list.
extension KanjiDecoration {
    static let animatedKanjiCategories: [(category: String, literals: [String])] = [
        ("Weather & Sky", ["雨", "雪", "火", "水", "日", "月", "星", "雷", "風", "光"]),
        ("Numbers", ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]),
        ("Colors", ["赤", "青", "黄", "緑", "黒", "白"]),
        ("Seasons", ["春", "夏", "秋", "冬"]),
        ("Nature", ["山", "川", "空", "雲", "虹", "嵐", "草", "石", "田", "米", "茶", "海", "池", "泉", "木", "林", "森", "花", "葉"]),
        ("Beings & Body", ["朝", "夜", "夕", "鳥", "魚", "馬", "犬", "猫", "虫", "目"]),
        ("Abstract & Action", ["心", "音", "声", "響", "力", "気", "愛", "夢", "神", "行", "走", "飛", "上", "下", "大", "小"])
    ]
}
