# Third-party notices

This file records third-party components identified in the source tree. It is
not a grant of rights to any third-party service, trademark, logo, or account.
When distributing a binary, container, or modified dependency, verify the
licenses that apply to that distribution as well.

## System.Security.Cryptography.ProtectedData 8.0.0

Used by the Windows Companion through the NuGet package
`System.Security.Cryptography.ProtectedData` version `8.0.0`.

License: MIT

Copyright (c) .NET Foundation and Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Package metadata: <https://www.nuget.org/packages/System.Security.Cryptography.ProtectedData/8.0.0>

## ws 8.x

Vendored at `relay/vendor/ws` (version 8.18.3). Used by the reference Relay
for RFC 6455 WebSocket handshake, framing, masking and ping/pong. The Relay
does not implement a custom frame parser.

License: MIT

Copyright (c) 2011 Einar Otto Stangvik <einaros@gmail.com>
Copyright (c) 2013 Arnout Kazemier and contributors
Copyright (c) 2016 Luigi Pinca and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Package metadata: <https://www.npmjs.com/package/ws>

## External runtimes and build tools

The repository does not include the source of Apple SDKs, Windows/.NET SDKs,
Node.js, the `node:22-alpine` base image, or XcodeGen. Those tools and runtime
distributions have their own terms and notices. Check the exact distribution
used for a release.

## OpenAI Codex integration

The local `codex app-server` executable and the OpenAI services it accesses are
external to this repository. Do not copy generated App Server JSON schemas from
an installed Codex build into this tree unless you also include the upstream
license and NOTICE. OpenAI names, logos, model names, and service content are
not licensed by this file. Use them only under the applicable OpenAI terms and
brand guidelines. Code-generation output should be reviewed for third-party
license obligations before redistribution.
