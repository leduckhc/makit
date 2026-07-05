/// NDJSON codec for the pino control-plane protocol (SPEC-01 / SPEC-03).
///
/// Mirrors the wire format of `server/src/daemon/protocol.ts`:
///   - Request:  `{ id, verb, args? }\n`
///   - Response: `{ id, ok: true, data? }\n`  or  `{ id, ok: false, error }\n`
///
/// The decode side never throws: malformed input yields `null`, matching the
/// server codec's contract so a hostile local peer cannot crash the client.
library;

import 'dart:convert';

import 'control_types.dart';

/// Serialize a control request to a single newline-terminated wire line.
///
/// [args] is omitted from the envelope when `null`, matching the TS encoder.
String encodeRequest(
  ControlVerb verb, {
  required String id,
  Map<String, dynamic>? args,
}) {
  final msg = <String, dynamic>{'id': id, 'verb': verb.wire};
  if (args != null) msg['args'] = args;
  return '${jsonEncode(msg)}\n';
}

/// Parse a single wire line into a raw [ControlResponse], or `null` if the
/// line is not valid JSON or not a well-formed envelope.
///
/// The `data` of an ok response is left as raw decoded JSON; use
/// [parseVerbData] (or the typed convenience methods on the client) to shape it
/// per verb.
ControlResponse<Object?>? decodeResponse(String line) {
  final Object? parsed;
  try {
    parsed = jsonDecode(line);
  } on FormatException {
    return null;
  }
  return ControlResponse.fromJson<Object?>(parsed, (data) => data);
}

/// Parse the raw `data` of an ok response into the typed payload for [verb].
///
/// Returns `null` when the payload is malformed, or — for [ControlVerb.pairCurrent]
/// — when there is no active token (the server sends `null`). For
/// [ControlVerb.logsTail] the result is a [LogChunk] ([LogLine] or [LogDone]).
Object? parseVerbData(ControlVerb verb, Object? data) => switch (verb) {
  ControlVerb.status => StatusData.fromJson(data),
  ControlVerb.pairMint => PairMintData.fromJson(data),
  ControlVerb.pairCurrent => PairCurrentData.fromJson(data),
  ControlVerb.devicesList => DevicesListData.fromJson(data),
  ControlVerb.devicesRevoke => DevicesRevokeData.fromJson(data),
  ControlVerb.sessionsList => SessionsListData.fromJson(data),
  ControlVerb.serverStop => ServerStopData.fromJson(data),
  ControlVerb.logsTail => LogChunk.fromJson(data),
  ControlVerb.logsCancel => null,
};

/// Parse a single wire line into a [ControlResponse] whose ok `data` is typed
/// per [verb] via [parseVerbData]. Returns `null` on a malformed envelope.
ControlResponse<Object?>? decodeTypedResponse(String line, ControlVerb verb) {
  final Object? parsed;
  try {
    parsed = jsonDecode(line);
  } on FormatException {
    return null;
  }
  return ControlResponse.fromJson<Object?>(
    parsed,
    (data) => parseVerbData(verb, data),
  );
}
