import SwiftUI

// The "Importing Files" help page, pushed from Settings and from the Bulk Import sheet. Explains
// which files Import Files… accepts and how files that share a name are paired into one note or
// attached to a note you already have. Sections: file types, name pairing, examples, adding to an
// existing note, audio without lyrics, other ways in.
struct FileImportHelpView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Text", value: ".txt")
                LabeledContent("Subtitles", value: ".srt")
                LabeledContent("Audio", value: ".mp3 .m4a .wav .aac .aiff .caf")
                LabeledContent("Karaoke timings", value: ".TextGrid")
            } header: {
                Text("What You Can Import")
            } footer: {
                Text("Notes ▸ Import ▸ Import Files… takes any mix of these, as many as you like at once. Other file types are ignored.")
            }

            Section {
                Text("Files with the same name, apart from the extension, become one note. Capitals and surrounding spaces don't matter, so \"Lesson 1.txt\" and \"lesson 1.MP3\" go together.")
                Text("The shared name becomes the note's title.")
                Text("The text file is the note's body. With no text file, the body is built from the subtitle lines.")
                Text("Subtitles make the audio play line by line with highlighting. A TextGrid adds word-level karaoke timing on top.")
            } header: {
                Text("Name Sharing")
            } footer: {
                Text("Before importing, each group shows what will happen, such as \"New note from text with audio\", so you can check the pairing.")
            }

            Section {
                ImportExampleRow(files: ["夜に駆ける.txt", "夜に駆ける.mp3", "夜に駆ける.srt"],
                                 result: "One note titled 夜に駆ける, with playable audio and synced lines.")
                ImportExampleRow(files: ["episode3.srt", "episode3.m4a"],
                                 result: "One note whose text comes from the subtitles, with audio.")
                ImportExampleRow(files: ["vocab.txt", "Vocab List.txt"],
                                 result: "Two separate notes — the names differ.")
                ImportExampleRow(files: ["song.mp3", "song-lyrics.txt"],
                                 result: "Two items: \"song\" (audio only) and \"song-lyrics\" (text only). Rename one so they match.")
            } header: {
                Text("Examples")
            }

            Section {
                Text("A group without a .txt file is added to an existing note when its name matches that note's title, or the name of the audio file already on it. Nothing new is created.")
                Text("Audio replaces the note's current audio. Subtitles replace its lines. A TextGrid on its own adds karaoke timing to the lines the note already has.")
                Text("If nothing matches, a new note is made instead.")
            } header: {
                Text("Adding to an Existing Note")
            } footer: {
                Text("Handy for updating a song you've already imported: drop in just the corrected .srt with the same name.")
            }

            Section {
                Text("Audio with no text, subtitles or TextGrid is transcribed on the device into a new note. Spoken audio works well; for songs Kioku warns you and recommends adding the lyrics as a .txt instead, though you can transcribe anyway.")
            } header: {
                Text("Audio Without Lyrics")
            } footer: {
                Text("Transcription needs iOS 26 or later; on earlier versions, audio-only files are skipped.")
            }

            Section {
                Text("Import Audio… transcribes one audio file into a new note.")
                Text("Camera and Photo Library read Japanese text from a picture.")
                Text("From URL pulls the text of a web page.")
                Text("In a note with no audio yet, the lyrics button attaches an audio file, plus its .srt or .TextGrid if you pick them too, to that note — names don't need to match there. With audio alone, Kioku lines the recording up with the note's text by itself.")
            } header: {
                Text("Other Ways In")
            }
        }
        .navigationTitle("Importing Files")
        .navigationBarTitleDisplayMode(.inline)
    }
}
