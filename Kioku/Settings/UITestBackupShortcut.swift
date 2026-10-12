import Foundation

// UI tests can't open a file in the system importer on the CI simulator: XCUITest reports the
// importer's files as not hittable, whatever part of them it taps. So in a UI-test launch, Import
// restores the backup that launch exported (through the real system exporter) by handing it to the
// same handler the importer calls, and validation, the replace confirmation, the replace-all and
// its alert all run as usual. Debug builds and UI-test launches only; everything else uses the
// importer.
enum UITestBackupShortcut {
    private static var exportedURL: URL?

    // Remembers where this launch's export was saved, when the UI tests launched the app.
    static func rememberExport(at url: URL) {
        #if DEBUG
        if UITestDictionaryInstaller.isUITestLaunch { exportedURL = url }
        #endif
    }

    // The file Import should restore without the importer: this launch's export, in a UI-test
    // launch that has made one; nil otherwise.
    static var importURL: URL? {
        #if DEBUG
        return UITestDictionaryInstaller.isUITestLaunch ? exportedURL : nil
        #else
        return nil
        #endif
    }
}
