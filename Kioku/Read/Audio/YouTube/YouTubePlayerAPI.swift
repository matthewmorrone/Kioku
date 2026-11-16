import Foundation

// YouTube's unofficial player endpoint, called the way its iOS app does. Shared by the audio download
// and the caption fetch so both read the same response. Unofficial: YouTube can change or restrict it.
enum YouTubePlayerAPI {
    static let clientVersion = "20.10.4"
    static let userAgent = "com.google.ios.youtube/\(clientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    // Calls the player endpoint as YouTube's iOS client and returns its JSON response.
    static func playerResponse(videoID: String) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw YouTubeAudioFailure.noAudioStream
        }
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "IOS", "clientVersion": clientVersion,
                "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": "18.3.2.22D82", "hl": "en"
            ]],
            "videoId": videoID, "contentCheckOk": true, "racyCheckOk": true
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            AppLog.error(.audioAlignment, "youtube player request \(videoID) HTTP \(http.statusCode)")
            throw YouTubeAudioFailure.badResponse(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeAudioFailure.noAudioStream
        }
        return json
    }
}
