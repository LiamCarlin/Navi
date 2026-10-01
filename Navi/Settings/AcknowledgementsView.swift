import SwiftUI

/// Third-party code and media that ship inside Navi.app, with the notices their licenses ask
/// us to reproduce. Opened from About → Acknowledgements. Keep it in step with
/// `scripts/bundle-runtime.sh` (the Python packages in the browser runtime) and `vendor/`.
struct Acknowledgement: Identifiable {
    let name: String
    let use: String
    let copyright: String
    let license: License
    let url: String
    var id: String { name }

    enum License: String, CaseIterable {
        case mit = "MIT License"
        case bsd3 = "BSD 3-Clause License"
        case mitCMU = "MIT-CMU License"
        case mpl2 = "Mozilla Public License 2.0"
        case psf = "Python Software Foundation License 2.0"
        case cc0 = "CC0 1.0 Universal"
    }

    static let all: [Acknowledgement] = [
        .init(name: "typesafe-computer-use", use: "How Navi drives apps on your Mac (ported to Swift)",
              copyright: "Copyright (c) 2026 Aaron Levin", license: .mit,
              url: "https://github.com/awlevin/typesafe-computer-use"),
        .init(name: "jev-ultrafast", use: "The browser task runner",
              copyright: "Copyright (c) 2026 Browser Use", license: .mit,
              url: "https://github.com/browser-use/jev-ultrafast"),
        .init(name: "browser-harness", use: "Talks to Chrome for browser tasks",
              copyright: "Copyright (c) 2026 Browser Use", license: .mit,
              url: "https://github.com/browser-use/browser-harness"),
        .init(name: "cdp-use", use: "Chrome DevTools Protocol client",
              copyright: "Copyright (c) 2024 Browser Use", license: .mit,
              url: "https://github.com/browser-use/cdp-use"),
        .init(name: "fetch-use", use: "HTTP helpers for the browser runner",
              copyright: "Copyright (c) Browser Use", license: .mit,
              url: "https://github.com/browser-use/fetch-use"),
        .init(name: "Python", use: "Runs the browser task runner",
              copyright: "Copyright (c) 2001 Python Software Foundation. All rights reserved.", license: .psf,
              url: "https://docs.python.org/3/license.html"),
        .init(name: "python-build-standalone", use: "The self-contained Python build (with the libraries it bundles, such as OpenSSL, SQLite, libffi, zlib and xz, each under its own license)",
              copyright: "Copyright (c) Gregory Szorc, Astral Software Inc. and contributors", license: .mpl2,
              url: "https://github.com/astral-sh/python-build-standalone"),
        .init(name: "httpx", use: "HTTP client", copyright: "Copyright © 2019, Encode OSS Ltd.", license: .bsd3,
              url: "https://github.com/encode/httpx"),
        .init(name: "httpcore", use: "HTTP client", copyright: "Copyright © 2020, Encode OSS Ltd.", license: .bsd3,
              url: "https://github.com/encode/httpcore"),
        .init(name: "h11", use: "HTTP/1.1", copyright: "Copyright (c) 2016 Nathaniel J. Smith and other contributors", license: .mit,
              url: "https://github.com/python-hyper/h11"),
        .init(name: "h2", use: "HTTP/2", copyright: "Copyright (c) 2015-2020 Cory Benfield and contributors", license: .mit,
              url: "https://github.com/python-hyper/h2"),
        .init(name: "hpack", use: "HTTP/2 header compression", copyright: "Copyright (c) 2014 Cory Benfield", license: .mit,
              url: "https://github.com/python-hyper/hpack"),
        .init(name: "hyperframe", use: "HTTP/2 framing", copyright: "Copyright (c) 2014 Cory Benfield", license: .mit,
              url: "https://github.com/python-hyper/hyperframe"),
        .init(name: "anyio", use: "Async networking", copyright: "Copyright (c) 2018 Alex Grönholm", license: .mit,
              url: "https://github.com/agronholm/anyio"),
        .init(name: "websockets", use: "WebSocket connection to Chrome", copyright: "Copyright (c) Aymeric Augustin and contributors", license: .bsd3,
              url: "https://github.com/python-websockets/websockets"),
        .init(name: "idna", use: "Internationalized domain names", copyright: "Copyright (c) 2013-2026, Kim Davies and contributors.", license: .bsd3,
              url: "https://github.com/kjd/idna"),
        .init(name: "certifi", use: "Root certificates", copyright: "Kenneth Reitz and contributors", license: .mpl2,
              url: "https://github.com/certifi/python-certifi"),
        .init(name: "Pillow", use: "Images in the browser runner",
              copyright: "Copyright © 1997-2011 by Secret Labs AB; Copyright © 1995-2011 by Fredrik Lundh and contributors; Copyright © 2010 by Jeffrey A. Clark and contributors",
              license: .mitCMU, url: "https://github.com/python-pillow/Pillow"),
        .init(name: "typing_extensions", use: "Python typing support", copyright: "Copyright (c) Python Software Foundation", license: .psf,
              url: "https://github.com/python/typing_extensions"),
        .init(name: "Screendrop keystroke sound", use: "Typing sounds", copyright: "Screendrop contributors — dedicated to the public domain", license: .cc0,
              url: "https://github.com/fayazara/Screendrop"),
    ]
}

extension Acknowledgement.License {
    /// The text each license asks to travel with the software, or where to read it.
    var text: String {
        switch self {
        case .mit:
            return """
            Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
            """
        case .bsd3:
            return """
            Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

            1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
            2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
            3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

            THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
            """
        case .mitCMU:
            return """
            By obtaining, using, and/or copying this software and/or its associated documentation, you agree that you have read, understood, and will comply with the following terms and conditions:

            Permission to use, copy, modify and distribute this software and its associated documentation for any purpose and without fee is hereby granted, provided that the above copyright notice appears in all copies, and that both that copyright notice and this permission notice appear in supporting documentation, and that the name of Secret Labs AB or the author not be used in advertising or publicity pertaining to distribution of the software without specific, written prior permission.

            SECRET LABS AB AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL SECRET LABS AB OR THE AUTHOR BE LIABLE FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
            """
        case .mpl2:
            return "This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. You can obtain a copy of the MPL at https://mozilla.org/MPL/2.0/. The source code is available at the project's link above."
        case .psf:
            return "Licensed under the Python Software Foundation License Version 2. The full license is at https://docs.python.org/3/license.html."
        case .cc0:
            return "Dedicated to the public domain under CC0 1.0 Universal (https://creativecommons.org/publicdomain/zero/1.0/). No attribution is required; we give it anyway."
        }
    }
}

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Acknowledgements").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Navi is built with these open-source projects. Thank you to everyone who made them.")
                        .foregroundStyle(.secondary)
                    ForEach(Acknowledgement.all) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.headline)
                                LinkPill(title: item.license.rawValue, url: item.url)
                            }
                            Text(item.use).font(.callout).foregroundStyle(.secondary)
                            Text(item.copyright).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(Acknowledgement.License.allCases.filter { l in Acknowledgement.all.contains { $0.license == l } }, id: \.self) { license in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(license.rawValue).font(.headline)
                            Text(license.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 560, height: 600)
    }
}
