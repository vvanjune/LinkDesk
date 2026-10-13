# LinkDesk native frontend

GPL-2.0-only. New native UI, implemented separately from Deskflow. Requires the user's existing Deskflow 1.27.0 installation and completed TLS setup. Deskflow binaries, certificates, keys and fingerprint databases are not shipped.

- macOS: SwiftUI / AppKit / SMAppService, arm64, macOS 13+.
- Windows: WPF / NotifyIcon / HKCU Run, net10.0-windows, self-contained win-x64.
- Transport: installed deskflow-core with a separate settings file; TLS and peer fingerprint checking always enabled.
- State: Deskflow 1.27 newline IPC, Unix socket on macOS and named pipe on Windows. The IPC version handshake negotiates the actual installed core version and replays queued messages.
- Peer trust: explicit user confirmation, SHA-256 validation, original trusted-client/server databases.
- Process: desktop mode only; existing GUI/core conflict prevention; bounded retries; terminate only owned child processes. macOS adds a 10-second startup handshake timeout.
- Startup: operating-system registration; close-to-background is independent of registration.
- Switching shortcuts: intentionally unchanged and no new switching hotkeys added.
- Input settings: sender-owned per-peer modifier remapping (Command/Super and Meta share the selected mapping); receiver-owned X/Y scroll inversion and scaling. Local physical input and Mos preferences are unchanged. The Mac defaults to the user's chosen Command→Ctrl / Control→Super preset. The Windows receiver defaults to vertical inversion for this setup; reset returns to core defaults.

See `../使用说明.md`. Build with `scripts/build-mac.sh` or `scripts/build-windows.ps1`.

Configuration checks:
`swiftc -parse-as-library macOS/Configuration.swift tests/ConfigurationTests.swift -o /tmp/linkdesk-tests && /tmp/linkdesk-tests`

Windows runtime verification is still required; cross-compilation cannot validate Windows UI, privilege behavior or named-pipe runtime behavior.

`tests/InputSettingsTests.cs` is a standalone console entry point for Windows input configuration checks. Compile it with `Windows/InputConfiguration.cs` in a net10.0 console project; it checks modifier validation, scroll bounds, and culture-independent serialization. The normal WPF project excludes this tests directory.

## 0.2.0 recovery and discovery

macOS watches NWPathMonitor and NSWorkspace wake notifications; Windows watches NetworkAddressChanged and PowerModeChanged. Recovery requests are debounced, recheck saved auto-connect intent, and recycle only owned core processes. Explicit stop disables automatic recovery. A temporary startup IPC connection delay is retried on macOS.

Mac servers answer IPv4 UDP queries on port 24801 only while their core is ready and discovery is enabled. Each response contains a public DER certificate and an RSA/ECDSA SHA-256 signature over `LinkDesk/1\n<nonce>\n<name>\n<source IPv4>\n24800\n`. Windows compares the certificate's SHA-256 hash with the existing trusted-servers database, validates the fresh query nonce and expected computer name, verifies the signature, and requires the signed IP to match the datagram sender. No private keys are transmitted. The input connection continues to require TLS and the original fingerprint validation.

Windows probes the previous IPv4 address and current adapter broadcasts, with a three-second query window and periodic retries. Discovery does not cross routed subnets; blocked broadcasts can require manual IP fallback. The reverse Windows-server/Mac-client role still uses a manual address.

Icons: native ICNS and ICO assets are included. Recreate with `swift scripts/generate-icons.swift <render-directory>` then `python3 scripts/package-icons.py <render-directory> assets`. No paid APIs or external artwork are used.

Tests: `tests/DiscoveryTests.cs` with `Windows/Discovery.cs` in a net10.0 console project tests authenticated discovery and rejects replay/tampering. `tests/DiscoveryResponderTests.swift` provides a responder using a temporary test PEM. `python3 scripts/test-recovery-mac.py` tests the actual recovery model with isolated preferences and an intentionally unavailable core. It simulates a wake notification; it does not put the user's Mac to sleep.
