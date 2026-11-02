#ifndef RUNNER_MYMY_USAGE_H_
#define RUNNER_MYMY_USAGE_H_

// MyMy Windows collector (Phase 2), runner-direct by design.
//
// Why runner-direct, not a plugin package: the collector is one
// MethodChannel on the app's own engine, with no Dart plugin API to
// expose. A plugin package would add generated-registrant plumbing and
// a second build unit for no benefit; the runner already owns the
// engine lifetime. If a second Windows app ever needs this collector,
// that is the moment to extract it into a plugin.
//
// Contract (same as Android, see lib/src/models.dart): this code
// reports CUMULATIVE counters only. Dart derives live rates.
//
// What is measured, honestly:
// - Device totals: GetIfTable2Ex adapter counters (InOctets/OutOctets,
//   64-bit, non-loopback, operationally-up interfaces only). These
//   are since the adapter came up, not since boot, and they include
//   UDP at device level.
// - Per-process bytes: TCP ONLY, via GetPerTcpConnectionEStats summed
//   per PID, with deltas tracked across polls so closed connections
//   keep their bytes. Enabling EStats needs administrator rights;
//   without them per-process lists are empty, never fabricated.
// - UDP per-process bytes: NOT measured in Phase 2. A real ETW
//   Microsoft-Windows-Kernel-Network consumer was not shipped blind:
//   its provider GUID/event parsing cannot be verified without a
//   Windows machine, and a wrong ETW consumer would report wrong
//   PIDs/bytes as if they were real. UDP connections are still listed
//   (process + local endpoint, no bytes) from GetExtendedUdpTable.
// - svchost.exe: service names are resolved best-effort via the
//   Service Control Manager (cached 30 s); failure falls back to the
//   plain exe name.

namespace flutter {
class FlutterEngine;
}  // namespace flutter

namespace mymy_usage {

// Registers the "mymy/usage" MethodChannel on the given engine.
// The collector lives for the life of the app (intentionally leaked:
// the engine outlives any scope that could own it cleanly).
void Register(flutter::FlutterEngine* engine);

}  // namespace mymy_usage

#endif  // RUNNER_MYMY_USAGE_H_
