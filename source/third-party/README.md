# Bundled runtime notices

LinkDesk macOS 0.4.2 includes the official Deskflow 1.27.0 core. Windows 0.4.3 builds that core from commit 081f6478e654a112168879e67a41ce7d7e4ae3af from immutable release-tag object 90376dfaba2c28dd61c5d4453ae5641c6edec5a3 with source/core-patches/windows-display-safety.patch. Required Qt/OpenSSL/MSVC runtime files remain unchanged from the official distribution. On macOS nested executables are locally signed as part of the LinkDesk bundle; this does not alter their source behavior.

- Deskflow 1.27.0: GPL-2.0-only with the upstream OpenSSL exception. See deskflow-1.27.0/LICENSE and LICENSE_EXCEPTION.
- Qt Base and Qt SVG 6.11.3: see the Qt LICENSES folders and third-party copyright files. These are separate shared libraries/frameworks and may be replaced or rebuilt under their licenses. macOS replacements require re-signing the application bundle.
- OpenSSL: 3.6.4 in the macOS core; 3.6.5 DLLs in the Windows core. See the respective Apache-2.0 LICENSE.txt and notices.
- Microsoft .NET and Windows Desktop runtime 10.0.12: bundled in the Windows frontend, licensed separately; license and third-party notices included.
- Microsoft C++ runtime DLLs: copied unchanged from the official Deskflow portable distribution. See MSVC-Runtime-License.txt.

Upstream source archives are available as LinkDesk-upstream-sources-0.4.0.zip in the v0.4.0 release (https://github.com/vvanjune/LinkDesk/releases/tag/v0.4.0), unchanged for the 0.4.2 packages. Qt 6.11.3 archives use the official 6.11.3 maintenance branches, pinned to qtbase 08c5ae85586ef9ef6b3f80f98f367de48c6db3d0 and qtsvg bb73f70f91462cedf44368bfa9e04855b4187239. No claim of bit-for-bit reproducible upstream builds is made.

Original official Windows core ZIP SHA-256:
8d19004cc3625623489d96580c1b58fd13ee78185689907fd4478595f93fab9a

Original runtime input hashes are recorded in runtime-files.json by the bundling script, before local macOS re-signing. Identity PEMs, private keys, personal pairing databases and settings are never copied into the runtime packages.

Version 0.4.2 changes the native frontends only. The Deskflow core and upstream runtime/source inputs are unchanged from v0.4.0.

Windows 0.4.3 includes the applied display-safety patch alongside these notices. Complete upstream Deskflow source is available in the linked source archive and at https://github.com/deskflow/deskflow/tree/90376dfaba2c28dd61c5d4453ae5641c6edec5a3; the patch and Windows build workflow in the LinkDesk repository provide the corresponding modifications and build instructions. The derived core remains GPL-2.0-only WITH LicenseRef-OpenSSL-Exception. Runtime manifest hashes describe the actual packaged files; core/linkdesk-core.json records patched core, patch and official input hashes. No bit-for-bit build reproducibility is claimed.

LinkDesk 0.4.4 updates both platforms. The Mac core also applies mac-display-safety.patch to the same release source, with matching OpenSSL 3.6.4 linked statically. Both patches are included with the notices. Original Mac runtime libraries are preserved and locally re-signed; Mac runtime-files.json records final signed files, and Resources/linkdesk-core.json records actual signed core, input and patch hashes. Windows 0.4.4 retains the verified Windows display-safety behavior.
