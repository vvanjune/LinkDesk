# LinkDesk 0.4.6: both platforms

GPL-2.0-only. Native SwiftUI/AppKit on macOS 13+ Apple Silicon; WPF on Windows x64 with self-contained .NET 10. Both packages use audited system-specific Deskflow 1.27.0 display-safety patches and required runtimes. Both apps build from source/VERSION and display their actual assembled version. Users do not install Deskflow or .NET separately.

## Connection model

Either platform can share or receive input: Mac → Windows, Windows → Mac, Mac → Mac, and Windows → Windows. Both devices need an IP network that allows them to communicate; a router, Ethernet LAN or hotspot works. A Windows hotspot is not required. Input uses TLS on TCP 24800; automatic discovery uses IPv4 UDP 24801. Discovery does not traverse routers, guest-network isolation or NAT. Manual names/addresses and complete fingerprints provide a fallback.

Pair multiple computers, then explicitly select one current connection on each side. Set one side to share and the other to receive. Discovery runs while the application is open in either role, even before starting input sharing. Devices with identical names are kept separate by SHA-256 certificate fingerprint. The two connected computers' core names must differ; fresh installations generate names with an identity suffix.

## Identity and pairing

Profiles: ~/Library/Application Support/LinkDesk on macOS; %LOCALAPPDATA%/LinkDesk on Windows. New identities are locally generated RSA-2048 / SHA-256 certificates. Existing valid Deskflow identities and trust databases migrate once when no LinkDesk identity exists. Broken identities or device catalogs cause an error and are preserved.

devices.json stores paired identities, aliases, last known addresses, selected fingerprint and per-device input settings. Unpaired discovery candidates stay in memory. A discovery signature proves possession of the advertised certificate key, not trust: users must compare the full SHA-256 fingerprint on the other computer before pairing. Names, reported platform and role are descriptive metadata, not the identity.

Each connection uses connections/<selected SHA256>/ as its core profile. Its TLS trust databases contain only the selected fingerprint, in both roles. An already-paired alternative device cannot substitute for the selection. Forgetting removes its record and connection profile; a migration marker prevents old root trust databases from resurrecting forgotten pairings. No private keys, personal settings or pairing records are shipped.

## Discovery and recovery

0.4.6 adds receiver-side connection failure monitoring: after 30 seconds it requests discovery (at most once per 15 seconds); after 60 seconds it shows actionable network and peer-sharing guidance. Failures alone never reload or kill the core. Recovery logs the outage duration. Selected-peer address changes bypass the ordinary recovery delay while retaining session, pause, identity and configuration-change checks. Discovery status, endpoint changes and peer returns are logged without repeating identical status messages.

Protocol v2 signs the fresh random query nonce, name, source IPv4 address, port, platform and role using the advertised certificate key (RSA SHA-256 PKCS#1 or ECDSA SHA-256 DER). Both implementations validate signature, nonce, source address, field formats and protocol version before displaying a candidate. Only the explicitly selected paired identity can update the current connection address. Broadcast and remembered-address probes are bounded and rate-limited. The Mac responder also answers legacy v1 server queries for migration; both endpoints should upgrade to 0.4.0 for symmetric discovery.

macOS watches NWPathMonitor and wake notifications; Windows watches NetworkAddressChanged and PowerModeChanged. Windows 0.4.3 separates login startup from sharing startup. New and upgraded preferences default automatic sharing and explicit display wake to off. Explicitly enabled sharing startup requires a remembered requested session, a minimum 15-second wait and five seconds of stable physical display topology on the default user desktop. Network recovery coalesces a 10-second quiet window, retains IPC-responsive cores and performs a graceful reload only for a genuine selected configuration change. Unresponsive or unexpectedly exited cores require manual attention; recovery never kills them automatically. Mac 0.4.5 follows the same lifecycle policy; its details are below. Desktop process mode is used; only explicitly stopped or application-owned processes on quit may be terminated after a graceful-stop timeout. The Windows portable marker keeps core TLS state in the selected LinkDesk profile rather than ProgramData/Deskflow.

Role advertisements can lag behind a mode change. They are device-list metadata: they never block a selected paired identity from starting or stop an established TLS connection. The core uses the explicitly configured local mode; its actual connection determines compatibility. Saving or starting refreshes the local announcement, without restarting unchanged discovery on each observed packet. Fingerprint validation and selected-only TLS scopes remain mandatory.

### Recovery and address editing follow-up

Stopped sessions ignore late core state messages; a TLS socket message alone no longer reports a connected sharing session. Specific connection refusals remain visible during retry monitoring. Receiver diagnostics distinguish recent discovery, a peer advertising receive mode, disabled discovery and connection timeout/refusal without assuming Wi-Fi or firewall is the cause.

Settings saved during recovery are retained. Reloads recheck desktop/session readiness after the old core exits; pending explicit settings resume when ready even if automatic network recovery is off. New cores get time to establish IPC before health checks classify them as unresponsive. An unresponsive core is preserved even if its selected configuration changed.

After stopping sharing, select a paired device and use **更新地址** to enter its IP address or hostname. This changes only its remembered endpoint, not its fingerprint or trust. Discovery can still update this address later. The next connection must authenticate the same paired identity.

## Input

Modifier mapping is applied by the sharing device; scroll direction and speed by the receiving device. Settings follow the selected peer. New cross-platform pairings exchange Command/Windows and Ctrl/Control; same-platform pairings keep modifiers unchanged. Migrated custom settings are retained. Local input and Mos preferences are untouched. No switching hotkeys were added.

Screen-edge switching defaults to immediate. The sharing side can require the pointer to dwell at the edge for 250/500/1000 ms before switching (core server option enableSwitchDelay/switchDelay). Settings pages stay editable while sharing runs: saving applies a genuine configuration change by gracefully reloading the core (stop, wait, relaunch), while the local role still requires stopping both ends first. Connection refusals are reported as human-readable guidance covering incompatible versions, duplicate client names, unknown clients and protocol errors.

## Build

Developer packaging requires official Deskflow 1.27.0 binary distributions as inputs and notices in third-party. Windows additionally requires a display-safe core built from the pinned upstream reference plus core-patches/windows-display-safety.patch; the bundler refuses a missing or unchanged upstream core. This is a build dependency, not an installed-app dependency.

- macOS: set LINKDESK_DESKFLOW_APP to the extracted official Deskflow.app, then run sh scripts/build-mac.sh. Default input: /Applications/Deskflow.app; also set LINKDESK_PATCHED_MAC_CORE to the verified Mac core. The script embeds the core, frameworks and plugins and applies a local ad-hoc signature; the release is not notarized.
- Windows: extract the official x64 portable distribution, set LINKDESK_DESKFLOW_WINDOWS to that folder, set LINKDESK_PATCHED_WINDOWS_CORE to the validated patched-core artifact, then run scripts/build-windows.ps1 with .NET 10 SDK and Python 3. Ship the entire output folder including core/ and ThirdParty/.

See third-party/README.md for licenses, runtime hashes and corresponding upstream source archives. Native ICNS/ICO assets are included; icon scripts use AppKit and Python's standard library.

## Tests

Swift test entry points compile separately with their supporting source files:

    swiftc -parse-as-library macOS/Configuration.swift tests/ConfigurationTests.swift -o /tmp/linkdesk-config-tests
    /tmp/linkdesk-config-tests
    swiftc -parse-as-library macOS/Configuration.swift macOS/Identity.swift macOS/Peers.swift macOS/Discovery.swift tests/MultiPeerTests.swift -o /tmp/linkdesk-peer-tests
    /tmp/linkdesk-peer-tests
    swiftc -parse-as-library macOS/Configuration.swift macOS/Identity.swift macOS/Peers.swift macOS/Discovery.swift tests/DiscoveryV2Tests.swift -o /tmp/linkdesk-discovery-tests
    /tmp/linkdesk-discovery-tests
    python3 scripts/test-recovery-mac.py

C# tests are separate .NET 10 console programs: InputSettingsTests.cs with InputConfiguration.cs; DiscoveryTests.cs / DiscoveryV2Tests.cs with Discovery.cs and Peers.cs; IdentityTests.cs / MultiPeerTests.cs also require Identity.cs. Enable nullable and disable default compile items when compiling a subset. Tests create temporary identities, never real application keys. The v2 test programs also expose loopback-only interoperation endpoints for testing Swift ↔ C# discovery.

See the release verification record for physical-machine results and limits. Configuration tests for four OS combinations do not replace hardware tests. Packages target Apple Silicon and Windows x64; Intel Mac and other platforms are not shipped.

## Windows display protection validation

The windows-display-core.yml workflow checks out immutable release-tag object 90376dfaba2c28dd61c5d4453ae5641c6edec5a3 (peeled commit 081f6478e654a112168879e67a41ce7d7e4ae3af), applies the strict-context patch, generates import libraries from the checksummed official OpenSSL DLL exports using matching pinned headers, builds the native core, runs DisplayWakePolicyTests.cpp, and executes the core with the official Qt/OpenSSL/MSVC runtime. windows-frontend-checks.yml runs the actual WPF model against an isolated fake IPC core: legacy startup preferences, 100 network signals, healthy resume, graceful endpoint reload, manual stop, hung/crashed core and cancellation of opted-in startup. It also parses the diagnostic command without executing it and launches the published app in tray-only login mode to verify that it shows no window and starts no sharing core.

The patch removes explicit display wake on connection/enter, disables receiver screen-saver synchronization by default, and gates optional explicit wake to actual remote input once per observed off cycle. It avoids releasing execution-state requirements that this instance never acquired, and uses ES_CONTINUOUS to clear owned requirements. Regular injected keyboard/mouse input may still affect Windows idle handling; this patch does not guarantee a monitor will never wake.

These checks verify application behavior, not GPU/driver reliability. Physical cold boots, screen-off/wake cycles, sleep and network recovery must be verified on affected hardware. No driver changes or remote-control software are used by these workflows. Diagnostic output remains local; it is never automatically uploaded.

## Mac 0.4.5 behavior and build

Mac now follows the same startup separation, explicit remembered session intent, 10-second coalesced recovery, healthy IPC process retention, graceful reconfiguration and no automatic kill/relaunch policy. Set LINKDESK_PATCHED_MAC_CORE to the verified mac-display-core.yml artifact when building; the bundler rejects a missing or unmodified core.

The Mac patch gates user-activity declarations to decoded remote input and observed workspace display sleep/wake cycles. Unknown display state never arms a request. Notification blocks retain a protected shared state, never a raw computer pointer. Entry/connection no longer declares user activity; receiver screen-saver synchronization defaults off; only an owned activity assertion is released.

mac-package.yml runs the actual Swift model with isolated IPC fixtures, embeds the checksummed official runtime, rewrites build-time loader paths, signs nested code, records actual signed core/runtime hashes in Resources, and seals the outer app. The Mac bundle uses ad-hoc signing and is not notarized; updated code may require renewed device-control permission. These software tests do not replace physical hardware verification.
