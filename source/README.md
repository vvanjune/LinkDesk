# LinkDesk 0.3.0 standalone native interfaces

GPL-2.0-only. SwiftUI/AppKit on macOS 13+ arm64; WPF on Windows x64 with self-contained .NET 10. The packages embed the unmodified Deskflow 1.27.0 core and required Qt/OpenSSL/C++ runtime files. End users do not install Deskflow or run its GUI.

## Build

Packaging requires the official upstream binary distribution as a build input, plus the notices in `third-party`. This is a developer build dependency, not an installed-app dependency.

macOS: point `LINKDESK_DESKFLOW_APP` at the official extracted Deskflow.app, then run `scripts/build-mac.sh`. The default build input is `/Applications/Deskflow.app`. The output embeds its core in `Contents/MacOS`, frameworks in `Contents/Frameworks`, and plugins in `Contents/PlugIns`. It is locally signed, not notarized.

Windows: extract the official Deskflow 1.27.0 x64 portable ZIP, set `LINKDESK_DESKFLOW_WINDOWS` to the extracted directory, then run `scripts/build-windows.ps1` with .NET 10 SDK and Python 3. The output has LinkDesk.exe, core/ and ThirdParty/. Ship the entire folder. See `third-party/README.md` for upstream notices and source archives.

## Identity and process isolation

macOS uses `~/Library/Application Support/LinkDesk`; Windows uses `%LOCALAPPDATA%/LinkDesk`. New identities are RSA-2048 self-signed SHA-256 certificates, generated locally. Existing Deskflow identities and pairing databases are copied once when the LinkDesk identity does not exist. Existing broken identities cause an error rather than being silently replaced. Fingerprints are SHA-256 over DER certificates and are shown in both connection pages.

The Windows embedded core includes a clean `core/settings/Deskflow.conf` portable marker. This makes the upstream core use the explicitly passed per-user settings folder for TLS, instead of its normal ProgramData/Deskflow folder. Both platforms set XDG_STATE_HOME to the LinkDesk profile. Desktop process mode is used; only owned child processes are terminated. Core IPC stays the upstream Unix socket/named pipe protocol, with version negotiation.

TLS and fingerprint validation remain mandatory. Unknown peers require explicit fingerprint confirmation. No personal certificates, private keys, settings or pairing databases are packaged.

## Recovery and discovery

macOS watches NWPathMonitor and NSWorkspace wake notifications; Windows watches NetworkAddressChanged and PowerModeChanged. Debounced recovery respects manual stop and saved auto-connect intent. Healthy connections are retained. Repeated failed launches use bounded retries.

Mac servers answer IPv4 UDP queries on port 24801 while their core is ready. Windows validates the pinned certificate, fresh nonce, expected peer name, signed source IP and RSA/ECDSA signature before updating the saved address. This supports already-paired Mac-server/Windows-client connections; initial pairing and reverse roles use manual addresses. The input connection uses TLS on TCP 24800.

## Input and icons

Sender-owned per-peer modifier mapping; receiver-owned X/Y scroll inversion and scaling. Local input and Mos preferences are untouched. No new switching hotkeys. Native ICNS/ICO assets are included; generator scripts use AppKit and the Python standard library.

## Tests

From this directory:

```sh
swiftc -parse-as-library macOS/Configuration.swift tests/ConfigurationTests.swift -o /tmp/linkdesk-config-tests
/tmp/linkdesk-config-tests
swiftc -parse-as-library macOS/Identity.swift tests/IdentityTests.swift -o /tmp/linkdesk-identity-tests
/tmp/linkdesk-identity-tests
python3 scripts/test-recovery-mac.py
```

C# test entry points are standalone console programs, compiled with .NET 10: InputSettingsTests.cs with InputConfiguration.cs; DiscoveryTests.cs with Discovery.cs; IdentityTests.cs with Identity.cs and Discovery.cs. Identity tests generate temporary test identities, verify stable reuse and migration, reject corrupt files without rotation, and verify signed discovery. Swift identity tests additionally verify private-file permissions and optionally compare a C#-generated PEM/fingerprint passed as two arguments.

Tests validate the model and protocols. Cross-compilation and dependency inspection cannot replace actual Windows connection testing. See `../验证记录.md` for actual outcomes and remaining limits.
