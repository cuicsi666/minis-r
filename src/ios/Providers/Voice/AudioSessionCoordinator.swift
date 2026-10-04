import Foundation
import AVFoundation
import UIKit

// MARK: - BluetoothMicRouter
//
// Routes voice-input capture to a connected Bluetooth headset's microphone (HFP)
// whenever one is attached, so dictation / voice input listens to the earpiece
// mic instead of the phone's built-in mic.
//
// iOS never routes recording to a Bluetooth mic on its own just because we set
// `.allowBluetooth` — AVAudioSession still prefers the built-in mic by default.
// We have to BOTH (a) allow Bluetooth in the session category options AND
// (b) explicitly `setPreferredInput` to the `.bluetoothHFP` port when present.
// When no Bluetooth mic is attached, these calls are no-ops and capture falls
// back to the system default (built-in) mic — i.e. behaviour is unchanged.
//
// (Defined in this file rather than a new Sources file so it is automatically
// part of the app target — this project needs explicit target membership for
// new Swift files, which a fresh file would otherwise miss at link time.)

enum BluetoothMicRouter {

    /// The Bluetooth (HFP) microphone input port, if one is currently attached.
    /// `bluetoothHFP` is the Hands-Free/headset profile that exposes a real mic;
    /// A2DP (`.bluetoothA2DP`) is output-only and never appears as an input.
    static var bluetoothInput: AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance()
            .availableInputs?
            .first { $0.portType == .bluetoothHFP }
    }

    /// True when the CURRENT audio input route is the Bluetooth mic.
    /// Useful to surface a "listening via 🎧 Bluetooth mic" badge in the UI.
    static var isUsingBluetoothMic: Bool {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        return inputs.contains { $0.portType == .bluetoothHFP }
    }

    /// Prefer the Bluetooth headset mic when one is attached. Must be called AFTER
    /// the session is active (`setActive(true)`) with a category that allows
    /// Bluetooth (`[.allowBluetooth]`). Returns true if a Bluetooth mic was found
    /// and selected.
    @discardableResult
    static func preferBluetoothMic() -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission != .denied else { return false }
        guard let bt = bluetoothInput else { return false }
        do {
            try session.setPreferredInput(bt)
            let hint = isUsingBluetoothMic ? "applied" : "set (route pending)"
            AppLogger(category: "BluetoothMic").info(
                "preferBluetoothMic → \(bt.portName) (\(String(describing: bt.portType.rawValue))) \(hint)")
            return true
        } catch {
            AppLogger(category: "BluetoothMic").error(
                "preferBluetoothMic FAILED: \(error.localizedDescription)")
            return false
        }
    }

    /// Drop the explicit input override and let the system pick (built-in mic).
    /// Call when a Bluetooth mic disappears mid-capture or when reconfiguring
    /// the session away from capture.
    static func clearBluetoothPreference() {
        _ = try? AVAudioSession.sharedInstance().setPreferredInput(nil)
    }
}

// MARK: - AudioSessionCoordinator
//
// The SINGLE owner of AVAudioSession category/active across the app. Every
// subsystem that needs audio declares an INTENT via begin()/end(); the
// coordinator picks the highest-priority active intent and applies its session
// profile (the only place setCategory / setActive is called). This removes the
// previous "everyone calls setCategory last-wins" races and the foreground-return
// silence (a stale category survived because a partial guard skipped reconfigure).
//
// Audio sources → intents (System TTS and cloud TTS are the SAME `replyTTS`
// source, just different engines resolved from the Voice Output group):
//   .capture            — mic recording (.record/.measurement)            [highest]
//   .mediaAttachment    — Markdown audio attachment / auto_play playback
//   .replyTTS           — read-replies (cloud VoiceOutputPlayer OR System AVSpeech)
//   .backgroundKeepAlive— silent keep-alive track (background only)        [lowest]
//
// `.mediaAttachment` and `.replyTTS` are mutually exclusive at the source level
// (the media player preempts TTS — see AIChatViewModel.stopSpeech on play), so in
// practice only one of them is active; the coordinator still ranks them.

@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private init() { registerInterruptionObserver() }

    enum Intent: Int {
        // Higher rawValue = higher priority.
        case backgroundKeepAlive = 0
        case replyTTS = 1
        case mediaAttachment = 2
        case capture = 3
        /// [T-call-bluetooth-pause] Highest: held for the WHOLE hands-free call so
        /// the audio session stays active (and on ONE Bluetooth link) the entire
        /// call. Without it, each turn boundary where no capture/TTS is active
        /// would deactivate the session (setActive(false)) and the headset drops
        /// + re-establishes the link → ANC flip every round.
        case callHold = 4
    }

    private let logger = AppLogger(category: "AudioSession")
    private var active: Set<Intent> = []

    /// True while the mic is capturing — reply TTS is suppressed in this state.
    var isCapturing: Bool { active.contains(.capture) }

    /// [T-call-bluetooth-pause] When true, `.capture` and `.replyTTS` share ONE
    /// `.playAndRecord` profile so a Bluetooth headset holds a single HFP + A2DP
    /// link instead of toggling between A2DP (output-only) and HFP (headset mic)
    /// at every speech⇄reply boundary. That toggle is what the boss heard as a
    /// short pause/resume + noise-cancellation flip at the start and end of each
    /// call turn. Set by the hands-free call loop (VoiceInputViewModel) while it
    /// is engaged.
    var callModeProfileForced = false

    // MARK: - Public API

    /// Posted when a media attachment preempts reply TTS — the active chat VM stops
    /// its System AVSpeechSynthesizer in response (cloud TTS is stopped directly).
    static let replyTTSPreemptedNotification = Notification.Name("AudioSession.replyTTSPreempted")

    /// Declare that `intent` now needs the audio session. Idempotent.
    ///
    /// The profile is applied ASYNCHRONOUSLY (see `apply`), so on return the
    /// session may not yet carry this intent's category. That is fine for
    /// playback intents but NOT for mic capture, which must read
    /// `AVAudioEngine.inputNode.inputFormat` only once `.record` is live — use
    /// `beginAndWait` there.
    func begin(_ intent: Intent) {
        beginInternal(intent)
    }

    /// [T-voice-input-double-tap] `begin` + bounded wait for the profile to
    /// actually be applied. Returns `true` if the session reached this intent's
    /// profile within `timeout`.
    ///
    /// Why this exists: reply TTS holds `.playback`, and tapping the mic while it
    /// speaks stops TTS and begins `.capture` in the same turn. Since
    /// bf9d66f6 moved `setCategory`/`setActive` onto a serial background queue
    /// (to stop a wedged mediaserverd from tripping the 10s watchdog), `begin`
    /// returns before the switch lands. The VAD then read `inputFormat` while the
    /// session was still in TTS's `.playback` profile, got 0 channels / 0 Hz, and
    /// threw "Microphone input unavailable" — so the first tap stopped the speech
    /// but never started recording. By the second tap the queue had drained and
    /// the profile was correct, which is exactly the reported "works on the
    /// second tap" behaviour.
    ///
    /// The wait is bounded and runs on the SAME serial queue the work is enqueued
    /// on, so it cannot outlive the queued block and cannot deadlock; on timeout
    /// the caller proceeds and its own 0-channel guard still protects it. The main
    /// thread is parked for at most `timeout`, well inside the watchdog budget.
    @discardableResult
    func beginAndWait(_ intent: Intent, timeout: TimeInterval = 1.0) -> Bool {
        beginInternal(intent)
        // Nothing was queued (already in this profile and active) → already live.
        guard Self.pendingLock.withLock({ Self.pendingApplies }) > 0 else { return true }
        let sem = DispatchSemaphore(value: 0)
        Self.sessionQueue.async { sem.signal() }   // FIFO: runs after pending applies
        let hit = sem.wait(timeout: .now() + timeout) == .success
        if !hit {
            logger.error("[AudioSession] beginAndWait(\(intent)) timed out after \(timeout)s — proceeding")
        }
        return hit
    }

    private func beginInternal(_ intent: Intent) {
        // Media attachment preempts reply TTS (mutually exclusive voice content):
        // stop the cloud queue directly and notify the chat VM to stop System TTS,
        // BEFORE media takes the session. (TTS is not auto-resumed afterwards.)
        if intent == .mediaAttachment, active.contains(.replyTTS) {
            VoiceOutputPlayer.shared.stopAll()
            NotificationCenter.default.post(name: Self.replyTTSPreemptedNotification, object: nil)
        }
        let was = highest
        active.insert(intent)
        if highest != was || !sessionActive {
            apply(reason: "begin(\(intent))")
        }
    }

    /// Declare that `intent` no longer needs the session.
    func end(_ intent: Intent) {
        guard active.contains(intent) else { return }
        active.remove(intent)
        apply(reason: "end(\(intent))")
    }

    /// Re-assert the correct session on foreground return (the stale-category fix)
    /// and stop the background keep-alive track (not needed in foreground).
    func reassertForForeground() {
        active.remove(.backgroundKeepAlive)
        apply(reason: "foreground")
    }

    // MARK: - Core (the ONLY setCategory/setActive site)

    private var sessionActive = false

    /// [T-voice-mic-preempted] Error from the most recent `apply()`, or nil if it
    /// succeeded. Lets a caller that just ran `beginAndWait` tell "the session
    /// never activated" (another app owns the mic — FaceTime, a phone call, a
    /// Bluetooth device) apart from "activated fine but the input node still
    /// reported 0 channels", which have completely different user-facing causes.
    ///
    /// Written on `sessionQueue` inside apply()'s catch and read from the main
    /// actor after `beginAndWait`'s barrier, so it needs the same lock as
    /// `pendingApplies` rather than actor isolation. Cleared at the START of
    /// every apply so a stale failure can never be attributed to a later attempt.
    /// Annotated exactly like `pendingApplies`/`pendingLock` below: the lock,
    /// not actor isolation, is what makes these safe across the main actor and
    /// `sessionQueue`.
    nonisolated private static let lastApplyLock = NSLock()
    nonisolated(unsafe) private static var _lastApplyError: Error?

    /// The most recent activation failure, or nil if the last apply succeeded.
    /// Only meaningful immediately after `beginAndWait` returns.
    nonisolated static var lastApplyError: Error? {
        lastApplyLock.withLock { _lastApplyError }
    }

    private var highest: Intent? { active.max(by: { $0.rawValue < $1.rawValue }) }

    private func profile(for intent: Intent) -> (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) {
        switch intent {
        // [T-call-bluetooth-pause] Unified hands-free profile: when the call loop
        // is active, capture and replyTTS both resolve here so the CATEGORY never
        // changes between listening and speaking → no Bluetooth A2DP↔HFP toggle.
        case .capture, .replyTTS:
            if callModeProfileForced {
                // [T-call-media-mode] BOSS: 用媒体模式不要通话模式. The headset
                // stays in A2DP (media audio) ONLY — output goes to the headset,
                // mic uses the phone's built-in mic. No HFP phone-call link is
                // ever established, so the headset's phone-call ANC never
                // engages/toggles. Session stays put on one stable media route.
                return (.playAndRecord, .default, [.allowBluetoothA2DP])
            }
            if intent == .capture {
                // [T-bluetooth-mic] `.allowBluetooth` lets the headset's HFP mic
                // become an eligible input source. Bluetooth HFP presents at
                // 16 kHz mono — VAD adapts to the reported input format.
                return (.record, .measurement, [.allowBluetooth])
            }
            return (.playback, .spokenAudio, [.duckOthers])
        case .mediaAttachment:
            return (.playback, .default, [.duckOthers])
        case .backgroundKeepAlive:
            return (.playback, .default, [.mixWithOthers])
        case .callHold:
            // [T-call-media-mode] Media-mode hold for the whole call: Bluetooth
            // stays A2DP (output to headset), mic = phone built-in. No HFP link
            // → the headset never enters phone-call ANC mode → no ANC toggling.
            return (.playAndRecord, .default, [.allowBluetoothA2DP])
        }
    }

    /// Serial queue that owns every blocking AVAudioSession mutation.
    ///
    /// [T-audiosession-setactive-watchdog] `setActive` / `setCategory` forward to
    /// mediaserverd over an NSXPCConnection and wait for a SYNCHRONOUS reply.
    /// When that daemon is wedged the reply never lands, and because this class
    /// is `@MainActor` the call was blocking the main thread — the app was
    /// SIGKILLed by the 10s scene-update watchdog (0x8BADF00D, incident
    /// EFB2E09B: app CPU ~1%, main thread parked in
    /// `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` under
    /// `-[AVAudioSession privateSetActive:withOptions:error:core:]`, reached from
    /// a Combine sink delivered on the main queue).
    ///
    /// Serial, so the ordering guarantees the old main-thread-only code relied on
    /// (deactivate-then-activate, category-before-active) still hold. AVAudioSession
    /// is thread-safe; it was never the main thread that made these calls correct.
    private static let sessionQueue = DispatchQueue(label: "com.cuicsi.minisr.audiosession.apply")

    /// Number of profile switches enqueued on `sessionQueue` but not yet applied.
    /// Written from BOTH the main actor (enqueue) and the session queue
    /// (completion), so it lives outside the actor's isolation with its own lock
    /// — see `beginAndWait`. `nonisolated` on the lock too, otherwise the
    /// background completion block can't touch it.
    nonisolated(unsafe) private static var pendingApplies = 0
    nonisolated private static let pendingLock = NSLock()

    private func apply(reason: String) {
        // Decide WHAT to do on the actor (reads `active` / `sessionActive`), then
        // perform the blocking AVAudioSession work off the main thread. State is
        // updated optimistically here so concurrent begin()/end() calls see the
        // intended session state without waiting on the daemon round-trip.
        guard let top = highest else {
            if sessionActive {
                sessionActive = false
                logger.info("[AudioSession] \(reason) → idle, deactivating (async)")
                Self.sessionQueue.async {
                    try? AVAudioSession.sharedInstance()
                        .setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
            return
        }
        let (cat, mode, opts) = profile(for: top)
        let session = AVAudioSession.sharedInstance()
        // FULL compare (category + mode + options), not just category — a partial
        // guard let BKA's `.mixWithOthers` profile poison reply TTS before.
        // These are plain property reads (no IPC), so they stay on the actor.
        let needsReconfig = session.category != cat
            || session.mode != mode
            || session.categoryOptions != opts
        let needsActivate = !sessionActive || needsReconfig
        guard needsReconfig || needsActivate else { return }
        if needsActivate { sessionActive = true }

        let log = logger
        // [T-media-mode] Read the actor-isolated flag BEFORE the escaping closure.
        let mediaMode = callModeProfileForced
        // Tracks queued-but-unapplied profile switches so `beginAndWait` knows
        // whether there is anything to wait for. Incremented here on the main
        // actor and decremented ON THE SESSION QUEUE (not via a hop back to the
        // actor, which could land after the waiter's barrier and read stale).
        Self.pendingLock.withLock { Self.pendingApplies += 1 }
        let t0 = CFAbsoluteTimeGetCurrent()
        Self.sessionQueue.async {
            // [T-voice-mic-preempted] Clear before attempting, so a success
            // wipes any earlier failure and a reader can never see a stale one.
            Self.lastApplyLock.withLock { Self._lastApplyError = nil }
            do {
                if needsReconfig {
                    try session.setCategory(cat, mode: mode, options: opts)
                }
                if needsActivate {
                    try session.setActive(true)
                }
                // [T-bluetooth-mic] After the session is live with the capture
                // category (which now allows Bluetooth), prefer the headset mic
                // when one is attached. Only for `.capture`, and only after a
                // successful activation — `setPreferredInput` is a no-op on an
                // inactive session, so calling it before `setActive` would
                // silently fail. `beginAndWait` in VAD's configureSession blocks
                // on THIS queue, so by the time it returns and `setupEngineAndVAD`
                // reads `inputNode.inputFormat`, the Bluetooth mic (16 kHz mono)
                // is already the selected input — the tap sees the right format.
                // [T-media-mode] Bluetooth-mic selection stays for NON-call capture (HFP).
                // In call media-mode the mic is the phone built-in by design
                // (headset is A2DP output-only) — no HFP input to prefer.
                if (top == .capture || top == .callHold), !mediaMode {
                    BluetoothMicRouter.preferBluetoothMic()
                }
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                log.info("[VoiceInputDebug][AudioSession] \(reason) → \(top) (\(cat.rawValue)/\(mode.rawValue)) applied in \(String(format: "%.0f", ms))ms")
            } catch {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                log.error("[VoiceInputDebug][AudioSession] \(reason) apply FAILED after \(String(format: "%.0f", ms))ms: \(error.localizedDescription)")
                // [T-voice-mic-preempted] Publish the reason so the capture path
                // can report "mic busy" instead of a generic parse failure.
                Self.lastApplyLock.withLock { Self._lastApplyError = error }
                // Roll back the optimistic flag so the next begin() retries the
                // activation instead of assuming the session is already live.
                Task { @MainActor in self.sessionActive = false }
            }
            Self.pendingLock.withLock { Self.pendingApplies -= 1 }
        }
    }

    // MARK: - Unified interruption handling (replaces per-subsystem observers)

    /// Set by subsystems so the coordinator can resume them after an interruption.
    var onInterruptionEnded: (() -> Void)?

    /// True while TTS was paused by us because external audio took priority
    /// (interruption or secondary-audio-silence hint). Guards the resume so we
    /// never resume playback the USER paused.
    private var pausedByExternalAudio = false

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        // [T-tts-pause-on-external-record] A third-party keyboard's dictation
        // (or any other app recording) runs its OWN audio session alongside our
        // .playback/.spokenAudio one — iOS does NOT post an
        // interruptionNotification for that coexistence, so TTS kept talking
        // and the keyboard transcribed our own speech. The system DOES post
        // silenceSecondaryAudioHintNotification (.begin) when higher-priority
        // audio (recording/call) should dominate: pause TTS there, resume on
        // .end.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSilenceSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil)
        // [T-tts-pause-inapp-keyboard-dictation] A third-party keyboard's
        // dictation started FROM INSIDE our app shares this process's audio
        // context — iOS does NOT post a silence-secondary-audio hint for it (that
        // notification fires only when ANOTHER app takes over). But the keyboard's
        // record session still triggers a route change, and the authoritative
        // `secondaryAudioShouldBeSilencedHint` property flips true while it holds
        // the mic. Poll that property on every route change and pause/resume TTS
        // accordingly, so in-app dictation gets the same treatment as cross-app
        // recording. (Reason codes alone are unreliable — categoryChange /
        // routeConfigurationChange fire for many unrelated cases — so we trust the
        // property, not the reason.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func handleRouteChange(_ note: Notification) {
        let shouldSilence = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        if shouldSilence {
            pauseTTSForExternalAudio(reason: "route-change(secondary-silence)")
        } else {
            resumeTTSAfterExternalAudio(reason: "route-change(secondary-clear)")
        }
    }

    /// Pause reply TTS because external audio (interruption / recording in
    /// another app) needs to dominate. `pause()` keeps the synthesis queue so
    /// playback can pick up where it left off — deliberately NOT stopAll().
    ///
    /// The intent flag `pausedByExternalAudio` is latched INDEPENDENTLY of the
    /// player's physical `isPaused`: an external recording frequently stops our
    /// AVAudioPlayer BEFORE the pause signal arrives, so at this point there may
    /// be no live player to physically pause — but we still must remember that
    /// WE own the pause, or the matching `.end` won't resume. `pause()` now
    /// latches `isPaused` even with no live player and gates `pumpPlayback`, so
    /// the queue can't sneak a unit out under the recorder.
    private func pauseTTSForExternalAudio(reason: String) {
        // Idempotent: repeated BEGIN signals (interruption + secondary-hint can
        // both fire) must not clear an already-recorded pause intent.
        guard !pausedByExternalAudio else { return }
        pausedByExternalAudio = true
        VoiceOutputPlayer.shared.pause()
        logger.info("[AudioSession] \(reason) → TTS paused (external audio)")
    }

    /// Resume reply TTS if (and only if) WE paused it for external audio.
    private func resumeTTSAfterExternalAudio(reason: String) {
        guard pausedByExternalAudio else { return }
        pausedByExternalAudio = false
        VoiceOutputPlayer.shared.resume()
        logger.info("[AudioSession] \(reason) → TTS resumed")
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.info("[AudioSession] interruption began")
            sessionActive = false   // system deactivated us
            // Previously we only flagged the session inactive; the TTS queue
            // kept "playing" into a dead session. Pause it so the queue
            // survives and can resume when the interruption ends.
            pauseTTSForExternalAudio(reason: "interruption-began")
        case .ended:
            logger.info("[AudioSession] interruption ended → re-asserting")
            apply(reason: "interruption-ended")
            resumeTTSAfterExternalAudio(reason: "interruption-ended")
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }

    @objc private func handleSilenceSecondaryAudioHint(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }
        switch type {
        case .begin:
            logger.info("[AudioSession] silence-secondary-audio hint BEGIN")
            pauseTTSForExternalAudio(reason: "secondary-audio-hint")
        case .end:
            logger.info("[AudioSession] silence-secondary-audio hint END")
            resumeTTSAfterExternalAudio(reason: "secondary-audio-hint-end")
        @unknown default:
            break
        }
    }
}
