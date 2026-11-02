#include "mymy_usage.h"

// Include order matters: winsock2.h must come before windows.h.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <tcpestats.h>
#include <winsvc.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int size = ::WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), nullptr, 0,
      nullptr, nullptr);
  if (size <= 0) return std::string();
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                        static_cast<int>(wide.size()), out.data(), size,
                        nullptr, nullptr);
  return out;
}

std::string BaseName(const std::string& path) {
  const size_t slash = path.find_last_of("\\/");
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string Ipv4ToString(DWORD addr) {
  in_addr in{};
  in.S_un.S_addr = addr;
  char buf[INET_ADDRSTRLEN] = {};
  if (::inet_ntop(AF_INET, &in, buf, sizeof(buf)) == nullptr) {
    return std::string("?.?.?.?");
  }
  return std::string(buf);
}

std::string Ipv6ToString(const BYTE addr[16]) {
  in6_addr in{};
  memcpy(&in, addr, 16);
  char buf[INET6_ADDRSTRLEN] = {};
  if (::inet_ntop(AF_INET6, &in, buf, sizeof(buf)) == nullptr) {
    return std::string("?");
  }
  return std::string(buf);
}

bool IsElevated() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation{};
  DWORD returned = 0;
  const BOOL ok = ::GetTokenInformation(
      token, TokenElevation, &elevation, sizeof(elevation), &returned);
  ::CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

struct ProcessInfo {
  std::string name;
  uint64_t startTime = 0;
};

struct ProcessTotals {
  std::string name;
  uint64_t startTime = 0;
  uint64_t rx = 0;
  uint64_t tx = 0;
};

struct ConnectionState {
  uint64_t lastIn = 0;
  uint64_t lastOut = 0;
};

struct ConnectionInfo {
  std::string processName;
  DWORD pid = 0;
  std::string remote;
};

class Collector {
 public:
  Collector() {
    WSADATA wsa{};
    ::WSAStartup(MAKEWORD(2, 2), &wsa);
  }

  bool Collect(EncodableMap* outSnapshot, bool* estatsWorking) {
    *estatsWorking = estats_working_;
    uint64_t totalRx = 0;
    uint64_t totalTx = 0;
    CollectAdapterTotals(&totalRx, &totalTx);

    std::map<DWORD, ProcessInfo> processes;
    std::vector<ConnectionInfo> connections;
    CollectConnections(&processes, &connections);

    // PID reuse: a new process in an old PID must not inherit the old
    // process's bytes. If the recorded start time differs, reset.
    for (const auto& [pid, info] : processes) {
      auto it = totals_.find(pid);
      if (it != totals_.end() && it->second.startTime != 0 &&
          info.startTime != 0 && it->second.startTime != info.startTime) {
        it->second.rx = 0;
        it->second.tx = 0;
        it->second.startTime = info.startTime;
        it->second.name = info.name;
      }
    }

    if (estats_working_) {
      CollectTcpBytes(processes);
    }

    EncodableList apps;
    for (const auto& [pid, totals] : totals_) {
      if (totals.rx == 0 && totals.tx == 0) continue;
      EncodableMap app;
      app[EncodableValue("id")] = EncodableValue(
          totals.name + ":" + std::to_string(static_cast<unsigned long>(pid)));
      app[EncodableValue("name")] = EncodableValue(totals.name);
      app[EncodableValue("rx")] =
          EncodableValue(static_cast<int64_t>(totals.rx));
      app[EncodableValue("tx")] =
          EncodableValue(static_cast<int64_t>(totals.tx));
      apps.push_back(EncodableValue(app));
    }
    // Largest first, matching the Dart UI's sort for the live tab.
    std::sort(apps.begin(), apps.end(), [](const EncodableValue& a,
                                           const EncodableValue& b) {
      const auto& ma = std::get<EncodableMap>(a);
      const auto& mb = std::get<EncodableMap>(b);
      const int64_t ta =
          std::get<int64_t>(ma.at(EncodableValue("rx"))) +
          std::get<int64_t>(ma.at(EncodableValue("tx")));
      const int64_t tb =
          std::get<int64_t>(mb.at(EncodableValue("rx"))) +
          std::get<int64_t>(mb.at(EncodableValue("tx")));
      return ta > tb;
    });

    EncodableList conns;
    const size_t kMaxConnections = 200;
    for (size_t i = 0; i < connections.size() && i < kMaxConnections; ++i) {
      EncodableMap c;
      c[EncodableValue("process")] = EncodableValue(connections[i].processName);
      c[EncodableValue("pid")] =
          EncodableValue(static_cast<int64_t>(connections[i].pid));
      c[EncodableValue("remote")] = EncodableValue(connections[i].remote);
      conns.push_back(EncodableValue(c));
    }

    const auto nowMs = static_cast<int64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count());
    (*outSnapshot)[EncodableValue("timestampMs")] = EncodableValue(nowMs);
    (*outSnapshot)[EncodableValue("totalRx")] =
        EncodableValue(static_cast<int64_t>(totalRx));
    (*outSnapshot)[EncodableValue("totalTx")] =
        EncodableValue(static_cast<int64_t>(totalTx));
    (*outSnapshot)[EncodableValue("mobileRx")] = EncodableValue(-1);
    (*outSnapshot)[EncodableValue("mobileTx")] = EncodableValue(-1);
    (*outSnapshot)[EncodableValue("apps")] = EncodableValue(apps);
    (*outSnapshot)[EncodableValue("connections")] = EncodableValue(conns);
    return true;
  }

  bool IsAdmin() const { return IsElevated(); }
  bool EstatsWorking() const { return estats_working_; }

 private:
  void CollectAdapterTotals(uint64_t* totalRx, uint64_t* totalTx) {
    PMIB_IF_TABLE2 table = nullptr;
    if (::GetIfTable2Ex(MibIfTableRaw, &table) != NO_ERROR ||
        table == nullptr) {
      return;
    }
    for (DWORD i = 0; i < table->NumEntries; ++i) {
      const MIB_IF_ROW2& row = table->Table[i];
      if (row.OperStatus != IfOperStatusUp) continue;
      if (row.Type == IF_TYPE_SOFTWARE_LOOPBACK) continue;
      *totalRx += row.InOctets;
      *totalTx += row.OutOctets;
    }
    ::FreeMibTable(table);
  }

  ProcessInfo DescribeProcess(DWORD pid) {
    ProcessInfo info;
    HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   pid);
    if (process == nullptr) {
      info.name = "PID " + std::to_string(static_cast<unsigned long>(pid));
      return info;
    }
    wchar_t path[MAX_PATH] = {};
    DWORD size = MAX_PATH;
    if (::QueryFullProcessImageNameW(process, 0, path, &size)) {
      info.name = BaseName(WideToUtf8(path));
    } else {
      info.name = "PID " + std::to_string(static_cast<unsigned long>(pid));
    }
    FILETIME creation{}, exitTime{}, kernel{}, user{};
    if (::GetProcessTimes(process, &creation, &exitTime, &kernel, &user)) {
      ULARGE_INTEGER t{};
      t.LowPart = creation.dwLowDateTime;
      t.HighPart = creation.dwHighDateTime;
      info.startTime = t.QuadPart;
    }
    ::CloseHandle(process);
    if (info.name == "svchost.exe") {
      info.name = DescribeSvchost(pid, info.name);
    }
    return info;
  }

  std::string DescribeSvchost(DWORD pid, const std::string& fallback) {
    const auto now = std::chrono::steady_clock::now();
    if (now - svchost_refresh_ > std::chrono::seconds(30)) {
      svchost_refresh_ = now;
      svchost_services_.clear();
      SC_HANDLE scm = ::OpenSCManagerW(nullptr, nullptr,
                                       SC_MANAGER_ENUMERATE_SERVICE);
      if (scm != nullptr) {
        DWORD bytesNeeded = 0;
        DWORD count = 0;
        DWORD resume = 0;
        ::EnumServicesStatusExW(
            scm, SC_ENUM_PROCESS_INFO, SERVICE_WIN32, SERVICE_STATE_ALL,
            nullptr, 0, &bytesNeeded, &count, &resume, nullptr);
        if (bytesNeeded > 0) {
          std::vector<BYTE> buffer(bytesNeeded);
          if (::EnumServicesStatusExW(
                  scm, SC_ENUM_PROCESS_INFO, SERVICE_WIN32,
                  SERVICE_STATE_ALL, buffer.data(), bytesNeeded, &bytesNeeded,
                  &count, &resume, nullptr)) {
            auto* services =
                reinterpret_cast<LPENUM_SERVICE_STATUS_PROCESSW>(buffer.data());
            for (DWORD i = 0; i < count; ++i) {
              const DWORD servicePid =
                  services[i].ServiceStatusProcess.dwProcessId;
              if (servicePid == 0) continue;
              svchost_services_[servicePid].push_back(
                  WideToUtf8(services[i].lpServiceName));
            }
          }
        }
        ::CloseServiceHandle(scm);
      }
    }
    const auto it = svchost_services_.find(pid);
    if (it == svchost_services_.end() || it->second.empty()) {
      return fallback;
    }
    std::string out = "svchost.exe (";
    for (size_t i = 0; i < it->second.size() && i < 3; ++i) {
      if (i > 0) out += ", ";
      out += it->second[i];
    }
    if (it->second.size() > 3) out += ", …";
    out += ")";
    return out;
  }

  void CollectConnections(std::map<DWORD, ProcessInfo>* processes,
                          std::vector<ConnectionInfo>* connections) {
    // TCP v4 + v6 (for the connection list and the EStats pass).
    CollectTcpTable(processes, connections);
    CollectUdpTable(processes, connections);
  }

  void CollectTcpTable(std::map<DWORD, ProcessInfo>* processes,
                       std::vector<ConnectionInfo>* connections) {
    DWORD size = 0;
    ::GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET,
                          TCP_TABLE_OWNER_PID_ALL, 0);
    if (size == 0) return;
    std::vector<BYTE> buffer(size);
    if (::GetExtendedTcpTable(buffer.data(), &size, TRUE, AF_INET,
                              TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR) {
      return;
    }
    auto* table = reinterpret_cast<PMIB_TCPTABLE_OWNER_PID>(buffer.data());
    for (DWORD i = 0; i < table->dwNumEntries; ++i) {
      const auto& row = table->table[i];
      auto [it, inserted] = processes->try_emplace(row.dwOwningPid);
      if (inserted) it->second = DescribeProcess(row.dwOwningPid);
      ConnectionInfo info;
      info.processName = it->second.name;
      info.pid = row.dwOwningPid;
      info.remote = Ipv4ToString(row.dwRemoteAddr) + ":" +
                    std::to_string(ntohs(
                        static_cast<u_short>(row.dwRemotePort)));
      connections->push_back(info);
    }
    // TCP v6.
    size = 0;
    ::GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET6,
                          TCP_TABLE_OWNER_PID_ALL, 0);
    if (size == 0) return;
    buffer.assign(size, 0);
    if (::GetExtendedTcpTable(buffer.data(), &size, TRUE, AF_INET6,
                              TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR) {
      return;
    }
    auto* table6 = reinterpret_cast<PMIB_TCP6TABLE_OWNER_PID>(buffer.data());
    for (DWORD i = 0; i < table6->dwNumEntries; ++i) {
      const auto& row = table6->table[i];
      auto [it, inserted] = processes->try_emplace(row.dwOwningPid);
      if (inserted) it->second = DescribeProcess(row.dwOwningPid);
      ConnectionInfo info;
      info.processName = it->second.name;
      info.pid = row.dwOwningPid;
      info.remote = "[" + Ipv6ToString(row.ucRemoteAddr) + "]:" +
                    std::to_string(ntohs(
                        static_cast<u_short>(row.dwRemotePort)));
      connections->push_back(info);
    }
  }

  void CollectUdpTable(std::map<DWORD, ProcessInfo>* processes,
                       std::vector<ConnectionInfo>* connections) {
    DWORD size = 0;
    ::GetExtendedUdpTable(nullptr, &size, FALSE, AF_INET,
                          UDP_TABLE_OWNER_PID, 0);
    if (size == 0) return;
    std::vector<BYTE> buffer(size);
    if (::GetExtendedUdpTable(buffer.data(), &size, TRUE, AF_INET,
                              UDP_TABLE_OWNER_PID, 0) != NO_ERROR) {
      return;
    }
    auto* table = reinterpret_cast<PMIB_UDPTABLE_OWNER_PID>(buffer.data());
    for (DWORD i = 0; i < table->dwNumEntries; ++i) {
      const auto& row = table->table[i];
      auto [it, inserted] = processes->try_emplace(row.dwOwningPid);
      if (inserted) it->second = DescribeProcess(row.dwOwningPid);
      ConnectionInfo info;
      info.processName = it->second.name;
      info.pid = row.dwOwningPid;
      // UDP rows carry no remote endpoint; show the local endpoint so
      // the user can still see which process holds a UDP socket.
      info.remote = "UDP " + Ipv4ToString(row.dwLocalAddr) + ":" +
                    std::to_string(ntohs(
                        static_cast<u_short>(row.dwLocalPort)));
      connections->push_back(info);
    }
  }

  void CollectTcpBytes(const std::map<DWORD, ProcessInfo>& processes) {
    CollectTcpBytesV4(processes);
    CollectTcpBytesV6(processes);
  }

  void CollectTcpBytesV4(const std::map<DWORD, ProcessInfo>& processes) {
    DWORD size = 0;
    ::GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET,
                          TCP_TABLE_OWNER_PID_ALL, 0);
    if (size == 0) return;
    std::vector<BYTE> buffer(size);
    if (::GetExtendedTcpTable(buffer.data(), &size, TRUE, AF_INET,
                              TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR) {
      return;
    }
    auto* table = reinterpret_cast<PMIB_TCPTABLE_OWNER_PID>(buffer.data());
    for (DWORD i = 0; i < table->dwNumEntries; ++i) {
      const auto& row = table->table[i];
      const auto procIt = processes.find(row.dwOwningPid);
      if (procIt == processes.end()) continue;
      TCP_ESTATS_DATA_RW_v0 rw{};
      rw.EnableCollection = TRUE;
      if (::SetPerTcpConnectionEStats(
              const_cast<PMIB_TCPROW>(
                  reinterpret_cast<const MIB_TCPROW*>(&row)),
              TcpConnectionEstatsData, reinterpret_cast<PUCHAR>(&rw), 0,
              sizeof(rw), nullptr, 0, 0) != NO_ERROR) {
        if (::GetLastError() == ERROR_ACCESS_DENIED) {
          estats_working_ = false;
          return;
        }
        continue;
      }
      TCP_ESTATS_DATA_RD_v0 rd{};
      if (::GetPerTcpConnectionEStats(
              const_cast<PMIB_TCPROW>(
                  reinterpret_cast<const MIB_TCPROW*>(&row)),
              TcpConnectionEstatsData, reinterpret_cast<PUCHAR>(&rw), 0,
              sizeof(rw), nullptr, 0, 0, reinterpret_cast<PUCHAR>(&rd), 0,
              sizeof(rd)) != NO_ERROR) {
        continue;
      }
      const std::string key =
          "v4|" + std::to_string(row.dwLocalAddr) + "|" +
          std::to_string(row.dwLocalPort) + "|" +
          std::to_string(row.dwRemoteAddr) + "|" +
          std::to_string(row.dwRemotePort) + "|" +
          std::to_string(static_cast<unsigned long>(row.dwOwningPid));
      AddTcpDelta(row.dwOwningPid, procIt->second, rd.DataBytesIn,
                  rd.DataBytesOut, key);
    }
  }

  void CollectTcpBytesV6(const std::map<DWORD, ProcessInfo>& processes) {
    if (!estats_working_) return;
    DWORD size = 0;
    ::GetExtendedTcpTable(nullptr, &size, FALSE, AF_INET6,
                          TCP_TABLE_OWNER_PID_ALL, 0);
    if (size == 0) return;
    std::vector<BYTE> buffer(size);
    if (::GetExtendedTcpTable(buffer.data(), &size, TRUE, AF_INET6,
                              TCP_TABLE_OWNER_PID_ALL, 0) != NO_ERROR) {
      return;
    }
    auto* table6 = reinterpret_cast<PMIB_TCP6TABLE_OWNER_PID>(buffer.data());
    for (DWORD i = 0; i < table6->dwNumEntries; ++i) {
      const auto& row = table6->table[i];
      const auto procIt = processes.find(row.dwOwningPid);
      if (procIt == processes.end()) continue;
      TCP_ESTATS_DATA_RW_v0 rw{};
      rw.EnableCollection = TRUE;
      if (::SetPerTcp6ConnectionEStats(
              const_cast<PMIB_TCP6ROW>(
                  reinterpret_cast<const MIB_TCP6ROW*>(&row)),
              TcpConnectionEstatsData, reinterpret_cast<PUCHAR>(&rw), 0,
              sizeof(rw), nullptr, 0, 0) != NO_ERROR) {
        if (::GetLastError() == ERROR_ACCESS_DENIED) {
          estats_working_ = false;
          return;
        }
        continue;
      }
      TCP_ESTATS_DATA_RD_v0 rd{};
      if (::GetPerTcp6ConnectionEStats(
              const_cast<PMIB_TCP6ROW>(
                  reinterpret_cast<const MIB_TCP6ROW*>(&row)),
              TcpConnectionEstatsData, reinterpret_cast<PUCHAR>(&rw), 0,
              sizeof(rw), nullptr, 0, 0, reinterpret_cast<PUCHAR>(&rd), 0,
              sizeof(rd)) != NO_ERROR) {
        continue;
      }
      std::string key = "v6|";
      for (int i = 0; i < 16; ++i) {
        key += std::to_string(row.ucLocalAddr[i]) + ".";
      }
      key += std::to_string(row.dwLocalPort) + "|";
      for (int i = 0; i < 16; ++i) {
        key += std::to_string(row.ucRemoteAddr[i]) + ".";
      }
      key += std::to_string(row.dwRemotePort) + "|" +
             std::to_string(static_cast<unsigned long>(row.dwOwningPid));
      AddTcpDelta(row.dwOwningPid, procIt->second, rd.DataBytesIn,
                  rd.DataBytesOut, key);
    }
  }

  void AddTcpDelta(DWORD pid, const ProcessInfo& info, uint64_t bytesIn,
                   uint64_t bytesOut, const std::string& key) {
    auto& totals = totals_[pid];
    if (totals.name.empty()) {
      totals.name = info.name;
      totals.startTime = info.startTime;
    }
    auto it = conn_state_.find(key);
    if (it == conn_state_.end()) {
      conn_state_[key] = ConnectionState{bytesIn, bytesOut};
      // First sight of a connection: its bytes so far belong to a
      // connection that started before the collector did. Counting
      // them as "new" would invent a burst, so they are NOT added;
      // only future deltas count. This is the honest rule for a
      // collector that starts mid-session.
      return;
    }
    uint64_t deltaIn = bytesIn >= it->second.lastIn
                           ? bytesIn - it->second.lastIn
                           : bytesIn;
    uint64_t deltaOut = bytesOut >= it->second.lastOut
                            ? bytesOut - it->second.lastOut
                            : bytesOut;
    totals.rx += deltaIn;
    totals.tx += deltaOut;
    it->second.lastIn = bytesIn;
    it->second.lastOut = bytesOut;
  }

  bool estats_working_ = true;
  std::map<DWORD, ProcessTotals> totals_;
  std::unordered_map<std::string, ConnectionState> conn_state_;
  std::chrono::steady_clock::time_point svchost_refresh_{};
  std::map<DWORD, std::vector<std::string>> svchost_services_;
};

class ChannelHandler {
 public:
  explicit ChannelHandler(flutter::FlutterEngine* engine)
      : channel_(
            engine->messenger(), "mymy/usage",
            &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler(
        [this](const MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
          Handle(call, std::move(result));
        });
  }

  void Handle(const MethodCall<EncodableValue>& call,
              std::unique_ptr<MethodResult<EncodableValue>> result) {
    const std::string& method = call.method_name();
    if (method == "getStatus") {
      // A probe collect tells us whether EStats actually works here,
      // rather than guessing from the admin flag alone.
      EncodableMap snapshot;
      bool working = false;
      collector_.Collect(&snapshot, &working);
      const bool admin = collector_.IsAdmin();
      const bool perProcess = admin && collector_.EstatsWorking();
      EncodableMap status;
      status[EncodableValue("hasPermission")] = EncodableValue(perProcess);
      status[EncodableValue("engine")] = EncodableValue("windows-ip-helper");
      status[EncodableValue("note")] = EncodableValue(
          perProcess
              ? "Windows collector: adapter totals + per-process TCP "
                "bytes (EStats). UDP per-process bytes are not measured "
                "in Phase 2 (ETW pending)."
              : "Run MyMy as administrator for per-process TCP bytes. "
                "Adapter totals and the active connection list still "
                "work. UDP per-process bytes are not measured in "
                "Phase 2.");
      result->Success(EncodableValue(status));
      return;
    }
    if (method == "getSnapshot") {
      EncodableMap snapshot;
      bool working = false;
      collector_.Collect(&snapshot, &working);
      result->Success(EncodableValue(snapshot));
      return;
    }
    result->NotImplemented();
  }

 private:
  Collector collector_;
  flutter::MethodChannel<EncodableValue> channel_;
};

}  // namespace

namespace mymy_usage {

void Register(flutter::FlutterEngine* engine) {
  // Intentionally leaked: one collector for the life of the app.
  static ChannelHandler* handler = new ChannelHandler(engine);
  (void)handler;
}

}  // namespace mymy_usage
