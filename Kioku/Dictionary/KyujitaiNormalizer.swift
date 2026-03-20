import Foundation

// Maps kyujitai (traditional/pre-reform) kanji to their shinjitai equivalents so lookup
// succeeds when users paste classical text that JMdict only indexes under the modern form.
// Applied as a fallback surface candidate — the original form is always tried first.
enum KyujitaiNormalizer {

    // Replaces each kyujitai scalar in the input with its shinjitai equivalent.
    // Returns nil when no substitution was made, so callers can skip the redundant query.
    static func normalize(_ input: String) -> String? {
        var scalars = input.unicodeScalars
        var changed = false

        for i in scalars.indices {
            if let replacement = table[scalars[i]] {
                scalars.replaceSubrange(i...i, with: CollectionOfOne(replacement))
                changed = true
            }
        }

        return changed ? String(scalars) : nil
    }

    // Scalar-keyed table for O(1) per-character lookup during normalization.
    nonisolated(unsafe) private static let table: [Unicode.Scalar: Unicode.Scalar] = [
        "舊": "旧", "體": "体", "國": "国", "圓": "円", "圖": "図", "學": "学", "實": "実", "寫": "写",
        "會": "会", "發": "発", "變": "変", "壓": "圧", "醫": "医", "區": "区", "賣": "売", "單": "単",
        "收": "収", "臺": "台", "榮": "栄", "營": "営", "衞": "衛", "驛": "駅", "緣": "縁", "艷": "艶",
        "鹽": "塩", "奧": "奥", "應": "応", "橫": "横", "價": "価", "假": "仮", "氣": "気", "擧": "挙",
        "曉": "暁", "縣": "県", "廣": "広", "恆": "恒", "雜": "雑", "濕": "湿", "壽": "寿", "澁": "渋",
        "燒": "焼", "奬": "奨", "將": "将", "涉": "渉", "證": "証", "乘": "乗", "淨": "浄", "剩": "剰",
        "疊": "畳", "條": "条", "狀": "状", "讓": "譲", "釀": "醸", "觸": "触", "寢": "寝", "愼": "慎",
        "晉": "晋", "眞": "真", "盡": "尽", "粹": "粋", "醉": "酔", "穗": "穂", "瀨": "瀬", "聲": "声",
        "齊": "斉", "靜": "静", "攝": "摂", "竊": "窃", "專": "専", "戰": "戦", "淺": "浅", "潛": "潜",
        "纖": "繊", "禪": "禅", "雙": "双", "騷": "騒", "增": "増", "藏": "蔵", "臟": "臓", "續": "続",
        "墮": "堕", "對": "対", "帶": "帯", "滯": "滞", "擇": "択", "澤": "沢", "擔": "担", "膽": "胆",
        "團": "団", "彈": "弾", "晝": "昼", "蟲": "虫", "鑄": "鋳", "廳": "庁", "徵": "徴", "聽": "聴",
        "鎭": "鎮", "轉": "転", "傳": "伝", "燈": "灯", "當": "当", "黨": "党", "盜": "盗", "稻": "稲",
        "鬪": "闘", "德": "徳", "獨": "独", "讀": "読", "屆": "届", "貳": "弐", "腦": "脳", "霸": "覇",
        "廢": "廃", "拜": "拝", "賠": "陪", "麥": "麦", "髮": "髪", "拔": "抜", "蠻": "蛮", "祕": "秘",
        "彥": "彦", "濱": "浜", "甁": "瓶", "拂": "払", "佛": "仏", "竝": "並", "邊": "辺",
        "辨": "弁", "瓣": "弁", "辯": "弁", "舖": "舗", "寶": "宝", "萠": "萌", "褒": "褒", "豐": "豊",
        "沒": "没", "飜": "翻", "每": "毎", "萬": "万", "滿": "満", "默": "黙", "藥": "薬", "譯": "訳",
        "豫": "予", "餘": "余", "與": "与", "搖": "揺", "樣": "様", "謠": "謡", "來": "来", "賴": "頼",
        "亂": "乱", "覽": "覧", "龍": "竜", "壘": "塁", "淚": "涙", "勞": "労", "樓": "楼", "祿": "禄",
        "錄": "録", "灣": "湾", "嶌": "島", "嶋": "島", "嶽": "岳",
    ]
}
