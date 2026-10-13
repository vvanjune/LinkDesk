# Bundled runtime notices

LinkDesk 0.4.0 includes the unmodified Deskflow 1.27.0 core and its required native runtime files. On macOS nested executables are locally signed as part of the LinkDesk bundle; this does not alter their source behavior.

- Deskflow 1.27.0: GPL-2.0-only with the upstream OpenSSL exception. See deskflow-1.27.0/LICENSE and LICENSE_EXCEPTION.
- Qt Base and Qt SVG 6.11.3: see the Qt LICENSES folders and third-party copyright files. These are separate shared libraries/frameworks and may be replaced or rebuilt under their licenses. macOS replacements require re-signing the application bundle.
- OpenSSL: 3.6.4 in the macOS core; 3.6.5 DLLs in the Windows core. See the respective Apache-2.0 LICENSE.txt and notices.
- Microsoft .NET and Windows Desktop runtime 10.0.12: bundled in the Windows frontend, licensed separately; license and third-party notices included.
- Microsoft C++ runtime DLLs: copied unchanged from the official Deskflow portable distribution. See MSVC-Runtime-License.txt.

Upstream source archives are delivered alongside binary packages as LinkDesk-upstream-sources-0.4.0.zip in the same GitHub release. Qt 6.11.3 archives use the official 6.11.3 maintenance branches, pinned to qtbase 08c5ae85586ef9ef6b3f80f98f367de48c6db3d0 and qtsvg bb73f70f91462cedf44368bfa9e04855b4187239. No claim of bit-for-bit reproducible upstream builds is made.

Original official Windows core ZIP SHA-256:
8d19004cc3625623489d96580c1b58fd13ee78185689907fd4478595f93fab9a

Original runtime input hashes are recorded in runtime-files.json by the bundling script, before local macOS re-signing. Identity PEMs, private keys, personal pairing databases and settings are never copied into the runtime packages.
