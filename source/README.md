# LinkDesk 0.4.x

macOS 0.4.0; Windows 0.4.1. The Windows patch refreshes its signed discovery announcement when starting after an unsaved role/name change.

GPL-2.0-only. Native SwiftUI/AppKit on macOS 13+ Apple Silicon; WPF on Windows x64 with self-contained .NET 10. Packages embed the unmodified Deskflow 1.27.0 core and required runtime files. Users do not install Deskflow or .NET separately.

## Connection model

Either platform can share or receive input: Mac → Windows, Windows → Mac, Mac → Mac, and Windows → Windows. Both devices need an IP network that allows them to communicate; a router, Ethernet LAN or hotspot works. A Windows hotspot is not required. Input uses TLS on TCP 24800; automatic discovery uses IPv4 UDP 24801. Discovery does not traverse routers, guest-network isolation or NAT. Manual names/addresses and complete fingerprints provide a fallback.

Pair multiple computers, then explicitly select one current connection on each side. Set one side to share and the other to receive. Discovery runs while the application is open in either role, even before starting input sharing. Devices with identical names are kept separate by SHA-256 certificate fingerprint. The two connected computers' core names must differ; fresh installations generate names with an identity suffix.

## Identity and pairing

Profiles: ~/Library/Application Support/LinkDesk on macOS; %LOCALAPPDATA%/LinkDesk on Windows. New identities are locally generated RSA-2048 / SHA-256 certificates. Existing valid Deskflow identities and trust databases migrate once when no LinkDesk identity exists. Broken identities or device catalogs cause an error and are preserved.

devices.json stores paired identities, aliases, last known addresses, selected fingerprint and per-device input settings. Unpaired discovery candidates stay in memory. A discovery signature proves possession of the advertised certificate key, not trust: users must compare the full SHA-256 fingerprint on the other computer before pairing. Names, reported platform and role are descriptive metadata, not the identity.

Each connection uses connections/<selected SHA256>/ as its core profile. Its TLS trust databases contain only the selected fingerprint, in both roles. An already-paired alternative device cannot substitute for the selection. Forgetting removes its record and connection profile; a migration marker prevents old root trust databases from resurrecting forgotten pairings. No private keys, personal settings or pairing records are shipped.

## Discovery and recovery

Protocol v2 signs the fresh random query nonce, name, source IPv4 address, port, platform and role using the advertised certificate key (RSA SHA-256 PKCS#1 or ECDSA SHA-256 DER). Both implementations validate signature, nonce, source address, field formats and protocol version before displaying a candidate. Only the explicitly selected paired identity can update the current connection address. Broadcast and remembered-address probes are bounded and rate-limited. The Mac responder also answers legacy v1 server queries for migration; both endpoints should upgrade to 0.4.0 for symmetric discovery.

macOS watches NWPathMonitor and wake notifications; Windows watches NetworkAddressChanged and PowerModeChanged. Debounced recovery respects manual stop and auto-connect intent, retains healthy connections and bounds failed launches. Desktop process mode is used; only owned child processes are terminated. The Windows portable marker keeps core TLS state in the selected LinkDesk profile rather than ProgramData/Deskflow.

## Input

Modifier mapping is applied by the sharing device; scroll direction and speed by the receiving device. Settings follow the selected peer. New cross-platform pairings exchange Command/Windows and Ctrl/Control; same-platform pairings keep modifiers unchanged. Migrated custom settings are retained. Local input and Mos preferences are untouched. No switching hotkeys were added.

## Build

Developer packaging requires official Deskflow 1.27.0 binary distributions as inputs and notices in third-party. This is a build dependency, not an installed-app dependency.

- macOS: set LINKDESK_DESKFLOW_APP to the extracted official Deskflow.app, then run sh scripts/build-mac.sh. Default input: /Applications/Deskflow.app. The script embeds the core, frameworks and plugins and applies a local ad-hoc signature; the release is not notarized.
- Windows: extract the official x64 portable distribution, set LINKDESK_DESKFLOW_WINDOWS to that folder, then run scripts/build-windows.ps1 with .NET 10 SDK and Python 3. Ship the entire output folder including core/ and ThirdParty/.

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
