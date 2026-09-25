import Foundation

// Dictionary entries that are nothing but particles (and だ / です) written together — には, ですか,
// よね. JMdict lists them as expressions, so the path search picks them as single units. The
// segmenter shows each as its parts instead, which is what a
// learner looks up: に and は, not には.
//
// The list is curated, not derived. JMdict tags い, し, さ and ど as particles too, so "every entry
// that decomposes into particles" sweeps in ない, いい and について; and entries whose meaning is not
// the sum of their parts stay whole on purpose: ので, のに, でも, とも, かな, かも, では, だの, and
// anything with a verb inside (によって, にとって, とともに).
nonisolated enum ParticleClusters {
    static let components: [String: [String]] = [
        "には": ["に", "は"], "にも": ["に", "も"], "とは": ["と", "は"], "をも": ["を", "も"],
        "での": ["で", "の"], "へと": ["へ", "と"], "までも": ["まで", "も"], "からには": ["から", "に", "は"],
        "のか": ["の", "か"], "なの": ["な", "の"], "ですか": ["です", "か"],
        "のです": ["の", "です"], "のだ": ["の", "だ"], "んです": ["ん", "です"], "んだ": ["ん", "だ"],
        "なのです": ["な", "の", "です"], "なのだ": ["な", "の", "だ"], "なんです": ["な", "ん", "です"],
        "よね": ["よ", "ね"], "だよね": ["だ", "よ", "ね"], "わね": ["わ", "ね"], "わよ": ["わ", "よ"],
        "よな": ["よ", "な"], "なよ": ["な", "よ"], "かよ": ["か", "よ"], "がね": ["が", "ね"],
        "ってね": ["って", "ね"], "ってよ": ["って", "よ"], "ってな": ["って", "な"],
    ]
}
