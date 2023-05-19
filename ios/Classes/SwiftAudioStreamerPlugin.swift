import AVFoundation
import Flutter
import UIKit

public class SwiftAudioStreamerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  private var eventSink: FlutterEventSink?
  var engine = AVAudioEngine()
  var audioData: [Float] = []
  var recording = false
  var preferredSampleRate: Int? = nil
  var preferredBufferSize = 4096
  var preferredOverlap = 0.5

  // Register plugin
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwiftAudioStreamerPlugin()

    // Set flutter communication channel for emitting updates
    let eventChannel = FlutterEventChannel.init(
      name: "audio_streamer.eventChannel", binaryMessenger: registrar.messenger())
    // Set flutter communication channel for receiving method calls
    let methodChannel = FlutterMethodChannel.init(
      name: "audio_streamer.methodChannel", binaryMessenger: registrar.messenger())
    methodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) -> Void in
      if call.method == "getSampleRate" {
        // Return sample rate that is currently being used, may differ from requested
        result(Int(AVAudioSession.sharedInstance().sampleRate))
      }
    }
    eventChannel.setStreamHandler(instance)
    instance.setupNotifications()
  }

  private func setupNotifications() {
    // Get the default notification center instance.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(notification:)),
      name: AVAudioSession.interruptionNotification,
      object: nil)
  }

  @objc func handleInterruption(notification: Notification) {
    // If no eventSink to emit events to, do nothing (wait)
    if eventSink == nil {
      return
    }

    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began: ()
    case .ended:
      // An interruption ended. Resume playback, if appropriate.

      guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
        return
      }
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      if options.contains(.shouldResume) {
        startRecording(
          sampleRate: preferredSampleRate,
          bufferSize: UInt32(preferredBufferSize),
          overlapVal: preferredOverlap ?? 0.5
        )
      }

    default:
      eventSink!(
        FlutterError(
          code: "100", message: "Recording was interrupted",
          details: "Another process interrupted recording."))
    }
  }

  // Handle stream emitting (Swift => Flutter)
  private func emitValues(values: [Float]) {

    // If no eventSink to emit events to, do nothing (wait)
    if eventSink == nil {
      return
    }
    // Emit values count event to Flutter
    eventSink!(values)
  }

  // Event Channel: On Stream Listen
  public func onListen(
    withArguments arguments: Any?,
    eventSink: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = eventSink
    if let args = arguments as? [String: Any] {
      if let preferredSampleRate = args["sampleRate"] as? Int,
        let preferredBufferSize = args["bufferSize"] as? Int,
        let preferredOverlap = args["overlap"] as? Double {
        self.preferredBufferSize = preferredBufferSize
        self.preferredSampleRate = preferredSampleRate
        self.preferredOverlap = preferredOverlap
        startRecording(
          sampleRate: preferredSampleRate, bufferSize: UInt32(preferredBufferSize),
          overlapVal: preferredOverlap)
      } else {
        // Handle the case where one or both arguments are missing or not of the expected type
        print("Invalid or missing arguments (bufferSize or sampleRate or overlap)")
        startRecording(sampleRate: nil, bufferSize: nil, overlapVal: 0.0)
      }
    } else {
      // Handle the case where the arguments parameter is not a dictionary
      print("Arguments parameter is not a dictionary")
      startRecording(sampleRate: nil, bufferSize: nil, overlapVal: 0.0)
    }
    return nil
  }

  // Event Channel: On Stream Cancelled
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    eventSink = nil
    engine.stop()
    return nil
  }

  func startRecording(sampleRate: Int?, bufferSize: UInt32?, overlapVal: Double) {
    engine = AVAudioEngine()

    do {
      try AVAudioSession.sharedInstance().setCategory(
        AVAudioSession.Category.playAndRecord, options: .mixWithOthers)
      try AVAudioSession.sharedInstance().setActive(true)

      if let sampleRateNotNull = sampleRate, let bufferSizeNotNull = bufferSize {
        // Try to set sample rate
        try AVAudioSession.sharedInstance().setPreferredSampleRate(Double(sampleRateNotNull))
        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(
          Double(bufferSizeNotNull) / Double(sampleRateNotNull))
      }

      let input = engine.inputNode
      let bus = 0

      var previousAudioBuffer = [Float]()
      var holderAudioBuffer = [Float]()
      let overlap = 1.0 - overlapVal

      input.installTap(
        onBus: bus, bufferSize: bufferSize ?? 4096, format: input.inputFormat(forBus: bus)
      ) {
        buffer, _ -> Void in
        let samples = buffer.floatChannelData?[0]
        // audio callback, samples in samples[0]...samples[buffer.frameLength-1]
        let audioBufferList = Array(
          UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        if overlap == 1.0 {
          self.emitValues(values: audioBufferList)
        } else {
          if previousAudioBuffer.count == 0 {
            previousAudioBuffer += audioBufferList
            self.emitValues(values: audioBufferList)
          } else {
            holderAudioBuffer += previousAudioBuffer
            holderAudioBuffer += audioBufferList

            var startIndex = Int(floor(overlap * Double(audioBufferList.count)))
            let width = audioBufferList.count
            var endIndex = startIndex + width - 1

            while startIndex < holderAudioBuffer.count {
              if holderAudioBuffer.count - startIndex > audioBufferList.count {
                self.emitValues(values: Array(holderAudioBuffer[startIndex...endIndex]))
                startIndex += Int(floor(overlap * Double(audioBufferList.count)))
                endIndex = startIndex + width - 1
              } else if holderAudioBuffer.count - startIndex == audioBufferList.count {
                self.emitValues(values: Array(holderAudioBuffer[startIndex...endIndex]))
                startIndex = holderAudioBuffer.count
                previousAudioBuffer.removeAll()
              } else if holderAudioBuffer.count - startIndex < audioBufferList.count {
                previousAudioBuffer = Array(holderAudioBuffer[startIndex..<holderAudioBuffer.count])
                startIndex = holderAudioBuffer.count
              }
            }
            holderAudioBuffer.removeAll()
          }
        }
      }

      try engine.start()
    } catch {
      eventSink!(
        FlutterError(
          code: "100", message: "Unable to start audio session", details: error.localizedDescription
        ))
    }
  }
}
