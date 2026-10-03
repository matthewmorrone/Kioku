import Foundation

// One note a fresh install starts with: its text and the bundled recording that goes with it.
struct SampleNoteSource {
    let title: String
    let content: String
    let audioResource: String
    let audioExtension: String
}

// The notes a fresh install starts with, so the Read tab has Japanese to tap on and audio to
// play before the user has imported anything. Credited in Attributions:
//   - キャラメルと飴玉: 夢野久作's 1922 story (public domain, text from Aozora Bunko), read for
//     LibriVox (public domain recording), trimmed to the story itself.
//   - さくら さくら: a traditional song (public domain), Kanohara's synthesized-vocal performance
//     from Wikimedia Commons, CC BY-SA 3.0.
enum SampleNote {
    static let seededKey = "notes.seededSampleNotes"

    // In list order; the first is the one the app opens on.
    static let sources: [SampleNoteSource] = [
        SampleNoteSource(
            title: "キャラメルと飴玉",
            content: """
                キャラメルと飴玉とがお菓子箱のうちで喧嘩をはじめました。
                「ヤイ、飴玉の間抜け野郎。貴様はまん丸くて甘ったるいばかりで何にもならないじゃないか。俺なんぞ見ろ。ちゃんと着物を着て四角いおうちにはいっているんだぞ。貴様なんぞは着物なんか欲しくたって持たないだろう。態をみろヤーイ」
                飴玉は真赤になって憤り出しました。
                「失敬なことを言うな。うちにいる時は裸だけど、外に出る時にゃちゃんと三角の紙の着物を着て行くんだ。第一貴様の名前が生意気だ。キャラメルなんて高慢チキな面をしやがって、日本にいるのならもっと日本らしい名前をつけろ」
                「こん畜生、横着な事を言う。キャラメルが悪けりゃあカステイラは西班牙の言葉だぞ。シュークリームでもワッフルでも良いが、菓子にはみんな西洋の名前が付いているんだ。あめだのせんべいなぞ言うのはみんな安っぽい美味くないお菓子ばかりだ」
                「嘘を吐け。羊羹なんて言うのは貴様よりよっぽど上等だぞ。コンペイトウは露西亜語の名前だけれど、俺よりずっと不味いぞ。ウエファースなんていう奴はいくら喰ったって喰ったような気がしないじゃないか」
                「馬鹿を言え。あれでもなかなか身体のためになるんだ。おれなんぞは牛乳が入っているから貴様よりずっと上等だ」
                「こん畜生、おれだって肉桂が入っているんだ。肉桂はお薬になるんだぞ。貴様の中に牛乳が何合入ってりゃあそんなに威張るんだ」
                「何を小癪な」
                「何を生意気な」
                とうとう取っ組み合って、大喧嘩になりました。最前から見物していたキャラメルの仲間のミンツ、ボンボン、チョコレート、ドロップス、飴玉の仲間の元禄、西郷玉、花林糖、有平糖なぞはソレというので馳け寄って、双方入り乱れてゴチャゴチャに押し合い掴み合っているうちに、みんなお互いにくっつき合って動けなくなってしまいました。
                そこへ坊ちゃんが来てお菓子箱の蓋を取ってみるとビックリして、
                「お母さん。大変大変。お菓子が喧嘩をしている」
                と叫びました。お母さんもやって来てこの有様を見ると、
                「それ御覧なさい。一緒に仕舞って置いてはいけないと言ったではありませんか。私がこわして上げるから、お姉さんやお兄さんと一緒におやつに食べておしまいなさい」
                と言って金槌を持って来て、パラパラと打ちこわしておしまいになりました。
                """,
            audioResource: "caramel-to-amedama",
            audioExtension: "m4a"
        ),
        SampleNoteSource(
            title: "さくら さくら",
            content: """
                さくら　さくら
                やよいの空は
                見わたす限り
                かすみか雲か
                匂いぞ　出ずる
                いざや　いざや
                見にゆかん
                """,
            audioResource: "sakura-sakura",
            audioExtension: "m4a"
        ),
    ]

    // Adds the sample notes on the first launch that finds no notes, and returns them in list
    // order so the caller can open the first. Runs once per install: a user who deletes them never
    // sees them come back, and a user who already has notes (a restore, an upgrade) never gets them.
    @MainActor
    static func seedIfNeeded(into store: NotesStore, defaults: UserDefaults = .standard) -> [Note] {
        guard defaults.bool(forKey: seededKey) == false else { return [] }
        defaults.set(true, forKey: seededKey)
        guard store.notes.isEmpty else { return [] }
        let notes = sources.map { source in
            Note(title: source.title, content: source.content, audioAttachmentID: attachBundledRecording(of: source))
        }
        // addNote inserts at the top, so add in reverse to keep the list in source order.
        for note in notes.reversed() {
            store.addNote(note)
        }
        return notes
    }

    // Copies a sample's bundled recording into the notes audio store and returns its attachment
    // ID. A failure leaves that sample as a text-only note rather than blocking it.
    private static func attachBundledRecording(of source: SampleNoteSource) -> UUID? {
        guard let url = Bundle.main.url(forResource: source.audioResource, withExtension: source.audioExtension) else {
            AppLog.error(.storage, "[SampleNote] \(source.audioResource).\(source.audioExtension) missing from the bundle")
            return nil
        }
        let attachmentID = UUID()
        do {
            _ = try NotesAudioStore.shared.saveAudio(from: url, attachmentID: attachmentID)
            return attachmentID
        } catch {
            AppLog.error(.storage, "[SampleNote] could not store \(source.audioResource) — \(error.localizedDescription)")
            return nil
        }
    }
}
