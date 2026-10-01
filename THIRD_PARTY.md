# Third-party software

Portal is GPL-2.0-or-later. Distribution must comply with the licenses of the actual libraries included in the build. The packaging script copies the libraries linked on the build machine; inspect `dist/Portal.app/Contents/Frameworks` before publishing.

- **LibVNCClient / LibVNCServer**, GPL-2.0-or-later. Source: https://github.com/LibVNC/libvncserver, revision `42494999e6492aaab9c1db785ecd293ef10b3aed`. Portal’s only source modification is reproduced in `scripts/patch-vnc.py`: let the registered extension handle ExtendedDesktopSize so all monitor records are retained. The original license is reproduced in `LICENSE`.
- **OpenSSL**, Apache-2.0. https://www.openssl.org/source/ and https://github.com/openssl/openssl/blob/master/LICENSE.txt
- **libjpeg-turbo**, IJG, BSD-style and zlib licenses, depending on component. https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/LICENSE.md
- **LZO**, GPL-2.0-or-later when selected by the local LibVNCClient build. https://www.oberhumer.com/opensource/lzo/
- System libraries, including zlib, are loaded from macOS and are not redistributed by Portal.

Before distributing binaries, include each bundled library’s exact license and corresponding source as required. The local development bundle is not a signed/notarized public release.

## Fonts

Inter 4.1 (https://rsms.me/inter/) and JetBrains Mono 2.304 (https://www.jetbrains.com/lp/mono/) are bundled under SIL Open Font License 1.1. Original license notices are included beside the fonts in `Sources/Portal/Resources/Fonts` and in the app resource bundle.
