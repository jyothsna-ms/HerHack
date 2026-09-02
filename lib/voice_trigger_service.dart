// voice_trigger_service.dart
//
// Listens continuously for trigger phrases and, when matched, fires:
//   1. a direct phone call (no dialer tap needed)
//   2. a direct SMS with live location to each emergency contact
//
// pubspec.yaml dependencies:
//   speech_to_text: ^7.0.0
//   geolocator: ^13.0.0
//   telephony: ^0.2.0              // direct SMS sending
//   flutter_phone_direct_caller: ^2.1.1   // direct call (no dialer UI)
//   permission_handler: ^11.3.0
//
// Android manifest permissions needed:
//   RECORD_AUDIO, SEND_SMS, CALL_PHONE, ACCESS_FINE_LOCATION,
//   ACCESS_BACKGROUND_LOCATION (if triggering while app is backgrounded)

import 'dart:async';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:geolocator/geolocator.dart';
import 'package:telephony/telephony.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:permission_handler/permission_handler.dart';

class EmergencyContact {
  final String name;
  final String phoneNumber;
  EmergencyContact(this.name, this.phoneNumber);
}

class VoiceTriggerService {
  final List<String> triggerPhrases; // e.g. ["help me", "call for help"]
  final List<EmergencyContact> contacts;
  final void Function(String matchedPhrase)? onTriggered;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final Telephony _telephony = Telephony.instance;

  bool _isListening = false;
  bool _cooldown = false; // prevents repeated triggers from one shout

  VoiceTriggerService({
    required this.triggerPhrases,
    required this.contacts,
    this.onTriggered,
  });

  Future<bool> init() async {
    final statuses = await [
      Permission.microphone,
      Permission.sms,
      Permission.phone,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every((s) => s.isGranted);
    if (!allGranted) return false;

    return _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (e) => print('Speech error: $e'),
    );
  }

  void startListening() {
    if (_isListening) return;
    _isListening = true;
    _listenLoop();
  }

  void stopListening() {
    _isListening = false;
    _speech.stop();
  }

  // speech_to_text sessions time out after a period of silence, so we
  // restart it in a loop to approximate continuous background listening.
  void _listenLoop() {
    if (!_isListening) return;
    _speech.listen(
      onResult: _onResult,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      cancelOnError: false,
    );
  }

  void _onSpeechStatus(String status) {
    if (status == 'done' && _isListening) {
      // restart listening to stay "always on"
      Future.delayed(const Duration(milliseconds: 300), _listenLoop);
    }
  }

  void _onResult(stt.SpeechRecognitionResult result) {
    final heard = result.recognizedWords.toLowerCase();

    if (_cooldown) return;

    for (final phrase in triggerPhrases) {
      if (heard.contains(phrase.toLowerCase())) {
        _cooldown = true;
        onTriggered?.call(phrase);
        _fireEmergencyResponse();
        // reset cooldown after a delay so it can trigger again later
        Future.delayed(const Duration(seconds: 20), () => _cooldown = false);
        break;
      }
    }
  }

  Future<void> _fireEmergencyResponse() async {
    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    final mapsLink =
        'https://maps.google.com/?q=${position.latitude},${position.longitude}';

    for (final contact in contacts) {
      await _telephony.sendSms(
        to: contact.phoneNumber,
        message:
            'EMERGENCY: I need help. My live location: $mapsLink',
      );
    }

    if (contacts.isNotEmpty) {
      await FlutterPhoneDirectCaller.callNumber(contacts.first.phoneNumber);
    }
  }
}

// Usage:
// final service = VoiceTriggerService(
//   triggerPhrases: ['help me', 'emergency help'],
//   contacts: [EmergencyContact('Mom', '+911234567890')],
//   onTriggered: (phrase) => print('Triggered by: $phrase'),
// );
// if (await service.init()) service.startListening();