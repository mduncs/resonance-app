import XCTest
@testable import Resonance

final class RadioDecodingTests: XCTestCase {
    func testInternetRadioStationsDecodeIntegerIDsAndTrimHomePageURLs() throws {
        let payload = """
        {
          "subsonic-response": {
            "status": "ok",
            "version": "1.16.1",
            "internetRadioStations": {
              "internetRadioStation": [
                {
                  "id": 42,
                  "name": "Lossless FM",
                  "streamUrl": "https://radio.example.com/live.aac",
                  "homePageUrl": " https://radio.example.com "
                },
                {
                  "id": "broken",
                  "name": "Broken",
                  "streamUrl": "not a url",
                  "homePageUrl": "   "
                }
              ]
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            SubsonicResponse<InternetRadioStationsResponse>.self,
            from: Data(payload.utf8)
        )

        let stations = (decoded.subsonicResponse.content?.internetRadioStation ?? [])
            .compactMap { $0.toInternetRadioStation() }

        XCTAssertEqual(stations.count, 1)
        XCTAssertEqual(stations.first?.id, "42")
        XCTAssertEqual(stations.first?.streamUrl.absoluteString, "https://radio.example.com/live.aac")
        XCTAssertEqual(stations.first?.homePageUrl?.absoluteString, "https://radio.example.com")
    }
}
