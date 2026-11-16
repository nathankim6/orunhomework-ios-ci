import AVFoundation
import SwiftUI

@main
struct OrunHomeworkApp: App {
    init() {
        AudioSessionPreparer.configure()
    }

    var body: some Scene {
        WindowGroup {
            WebShellView()
        }
    }
}

/// The student recording screen captures audio with `getUserMedia` inside the web view.
/// With no category set, that take can be routed to the earpiece (it sounds very quiet)
/// and the first capture can fail while another app holds the audio session. Setting a
/// play-and-record category up front, with the speaker as the default route, is the
/// documented preparation for WebKit capture; the system still owns Bluetooth routing.
///
/// The session is deliberately not activated here: WebKit activates it when a capture or
/// a playback starts, so opening the app never interrupts what the user is listening to.
enum AudioSessionPreparer {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers])
    }
}
