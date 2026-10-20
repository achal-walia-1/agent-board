import AppKit
import SwiftUI

// Design option mockups for Agent Board, rendered on a fake macOS desktop.

struct MockTask: Identifiable {
    let id = UUID()
    let source: String
    let title: String
    let state: String // running, ready, approve, done
}

let mockTasks = [
    MockTask(source: "claude", title: "Refactor Auth Flow", state: "ready"),
    MockTask(source: "codex", title: "Add Unit Tests", state: "running"),
    MockTask(source: "claude", title: "Run DB Migration", state: "approve"),
    MockTask(source: "cursor", title: "Fix Card Spacing", state: "running"),
]

func stateColor(_ s: String) -> Color {
    switch s {
    case "ready": return .ready
    case "approve": return .ask
    case "running": return .cooking
    default: return Color(white: 0.5)
    }
}
func stateLabel(_ s: String) -> String {
    ["ready": "Ready", "approve": "Approve", "running": "In progress", "done": "Done"][s] ?? s
}

struct Dot: View {
    let state: String
    var size: CGFloat = 6
    var body: some View {
        if state == "running" {
            Circle().trim(from: 0, to: 0.7)
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: size + 3, height: size + 3)
                .rotationEffect(.degrees(40))
        } else {
            Circle().fill(stateColor(state)).frame(width: size, height: size)
                .shadow(color: stateColor(state).opacity(0.8), radius: 3)
        }
    }
}

struct MockStatus: View {
    let state: String
    var body: some View {
        HStack(spacing: 6) {
            Dot(state: state)
            Text(stateLabel(state)).font(.system(size: 11.5, weight: state == "running" ? .regular : .medium))
                .foregroundStyle(state == "running" ? .white.opacity(0.45) : stateColor(state))
        }
    }
}

struct AppIcon: View {
    let source: String
    var size: CGFloat = 22
    var body: some View { Image(nsImage: Icons.app(source)).resizable().interpolation(.high).frame(width: size, height: size) }
}

// DogHead comes from AgentBoard.swift

struct DarkGlass: ViewModifier {
    var radius: CGFloat
    var light = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(light ? Color.white.opacity(0.62) : Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(light ? Color.white.opacity(0.7) : Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
extension View { func darkGlass(_ r: CGFloat, light: Bool = false) -> some View { modifier(DarkGlass(radius: r, light: light)) } }

// MARK: - Desktop backdrop

struct Desktop<Content: View>: View {
    var notch = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), Color(red: 0.06, green: 0.20, blue: 0.36), Color(red: 0.32, green: 0.14, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.55, green: 0.3, blue: 0.9).opacity(0.35)).frame(width: 420).blur(radius: 80).offset(x: -220, y: 160)
            Circle().fill(Color(red: 0.2, green: 0.6, blue: 0.9).opacity(0.3)).frame(width: 380).blur(radius: 90).offset(x: 260, y: 260)
            // a background app window
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12).opacity(0.92))
                .frame(width: 440, height: 290).offset(x: -90, y: 90)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9) } }
                        .offset(x: -90 - 205, y: 90 + 12)
                }
            // menu bar
            HStack(spacing: 14) {
                Image(systemName: "apple.logo").font(.system(size: 12))
                Text("Cursor").font(.system(size: 12, weight: .bold))
                Text("File   Edit   View   Go").font(.system(size: 12)).opacity(0.85)
                Spacer()
                Text("Wed 15 Oct  12:41").font(.system(size: 12)).opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 26)
            .background(Color.black.opacity(0.22))
            if notch {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 170, height: 30)
            }
            content()
        }
        .frame(width: 720, height: 450)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Options

/// 1. Notch Island: collapsed / live activity / expanded
struct OptIsland: View {
    var body: some View {
        Desktop {
            VStack(spacing: 18) {
                // live activity state (wide)
                HStack(spacing: 10) {
                    DogHead(mood: .ready, size: 24)
                    Spacer().frame(width: 150)
                    AppIcon(source: "claude", size: 18)
                    Text("Refactor Auth Flow").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Dot(state: "ready")
                }
                .padding(.horizontal, 12).frame(height: 34)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 17, bottomTrailingRadius: 17).fill(.black))
                Spacer().frame(height: 10)
                // expanded on hover
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Dog(mood: .ready).frame(width: 92, height: 70)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("1 ready for review").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text("2 in progress · 1 awaiting approval").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                    }.padding(12)
                    ForEach(mockTasks) { t in
                        HStack(spacing: 10) {
                            AppIcon(source: t.source, size: 18)
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            Spacer(); MockStatus(state: t.state)
                        }.padding(.horizontal, 14).frame(height: 32)
                    }
                    Spacer().frame(height: 8)
                }
                .frame(width: 340)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.black))
            }
        }
    }
}

/// 2. Side rail
struct OptRail: View {
    var body: some View {
        Desktop(notch: false) {
            HStack(alignment: .top, spacing: 10) {
                Spacer()
                // expanded peek
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(mockTasks) { t in
                        HStack(spacing: 10) {
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                            Spacer(minLength: 16)
                            MockStatus(state: t.state)
                        }.padding(.horizontal, 14).frame(height: 40)
                    }
                }
                .frame(width: 230).padding(.vertical, 6)
                .darkGlass(16)
                .padding(.top, 104)
                // the rail
                VStack(spacing: 0) {
                    DogHead(mood: .ready, size: 34).padding(.vertical, 10)
                    ForEach(mockTasks) { t in
                        ZStack(alignment: .bottomTrailing) {
                            AppIcon(source: t.source, size: 24)
                            Dot(state: t.state, size: 7).offset(x: 3, y: 3)
                        }.frame(height: 40)
                    }
                    Spacer().frame(height: 6)
                }
                .frame(width: 52)
                .darkGlass(26)
                .padding(.top, 60).padding(.trailing, 10)
            }
        }
    }
}

/// 3. Compact bar + toast
struct OptToast: View {
    var body: some View {
        Desktop(notch: false) {
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    DogHead(mood: .cooking, size: 26)
                    Text("2 in progress").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text("· 1 ready").font(.system(size: 12)).foregroundStyle(Color.ready)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 10).frame(width: 260, height: 42)
                .darkGlass(21)
                HStack(spacing: 11) {
                    AppIcon(source: "claude", size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refactor Auth Flow").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Claude finished · tap to open").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Dot(state: "ready", size: 7)
                }
                .padding(.horizontal, 14).frame(width: 300, height: 58)
                .darkGlass(16)
                .overlay(alignment: .leading) { Capsule().fill(Color.ready).frame(width: 3, height: 26).offset(x: 1) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 40).padding(.trailing, 16)
        }
    }
}

/// 4. Menu bar dropdown
struct OptMenuBar: View {
    var body: some View {
        Desktop(notch: false) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    DogHead(mood: .ready, size: 18)
                    Text("1").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 6).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.2)))
                .offset(x: -140, y: 2)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Dog(mood: .ready).frame(width: 96, height: 72)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AGENTS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Color.ready)
                            Text("1 ready for review").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            Text("2 in progress").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                    }.padding(12)
                    Divider().opacity(0.3)
                    ForEach(mockTasks) { t in
                        HStack(spacing: 10) {
                            AppIcon(source: t.source, size: 18)
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            Spacer(); MockStatus(state: t.state)
                        }.padding(.horizontal, 14).frame(height: 32)
                    }
                    Spacer().frame(height: 6)
                }
                .frame(width: 320)
                .darkGlass(12)
                .offset(x: -40, y: 30)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// 5. Desktop widget (macOS widget style)
struct OptWidget: View {
    var body: some View {
        Desktop(notch: false) {
            HStack(alignment: .top, spacing: 14) {
                Spacer()
                // small
                VStack(alignment: .leading, spacing: 4) {
                    Dog(mood: .cooking).frame(width: 130, height: 90)
                    Text("2").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Text("in progress").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(14).frame(width: 158, height: 170, alignment: .topLeading)
                .darkGlass(22)
                // medium
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Dog(mood: .ready).frame(width: 110, height: 80)
                        Text("1 ready").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        Text("2 in progress").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(mockTasks.prefix(4)) { t in
                            HStack(spacing: 8) {
                                AppIcon(source: t.source, size: 16)
                                Text(t.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                                Spacer(minLength: 2)
                                Dot(state: t.state, size: 6)
                            }
                        }
                    }
                }
                .padding(14).frame(width: 330, height: 170)
                .darkGlass(22)
            }
            .padding(.top, 50).padding(.trailing, 18)
        }
    }
}

/// 6. Chat-head orb
struct OptOrb: View {
    var body: some View {
        Desktop(notch: false) {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                VStack(alignment: .trailing, spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(mockTasks) { t in
                            HStack(spacing: 10) {
                                AppIcon(source: t.source, size: 18)
                                Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                                Spacer(); MockStatus(state: t.state)
                            }.padding(.horizontal, 14).frame(height: 36)
                        }
                    }
                    .padding(.vertical, 6).frame(width: 290)
                    .darkGlass(18)
                    ZStack(alignment: .topTrailing) {
                        DogHead(mood: .ready, size: 62)
                            .background(Circle().fill(Color(white: 0.18)))
                            .overlay(Circle().strokeBorder(Color.ready.opacity(0.8), lineWidth: 2))
                            .shadow(color: Color.ready.opacity(0.45), radius: 12)
                        Text("1").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.ready))
                            .offset(x: 3, y: -3)
                    }
                }
                .padding(22)
            }
        }
    }
}

/// 7. Bottom dock ticker
struct OptTicker: View {
    var body: some View {
        Desktop(notch: false) {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    DogHead(mood: .cooking, size: 28).padding(.trailing, 4)
                    ForEach(mockTasks) { t in
                        HStack(spacing: 7) {
                            AppIcon(source: t.source, size: 16)
                            Text(t.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            Dot(state: t.state, size: 6)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(t.state == "ready" ? Color.ready.opacity(0.14) : t.state == "approve" ? Color.ask.opacity(0.14) : .white.opacity(0.06)))
                    }
                }
                .padding(.horizontal, 10).frame(height: 46)
                .darkGlass(23)
                .padding(.bottom, 18)
            }
        }
    }
}

/// 8. Current card, light glass
struct OptLight: View {
    var body: some View {
        Desktop(notch: false) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Dog(mood: .ready).frame(width: 112, height: 86)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.5)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AGENTS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Color(red: 0.1, green: 0.55, blue: 0.3))
                        Text("1 ready for review").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black.opacity(0.85))
                        Text("2 in progress").font(.system(size: 11.5)).foregroundStyle(.black.opacity(0.45))
                    }
                    Spacer()
                }.padding(12)
                VStack(spacing: 0) {
                    ForEach(Array(mockTasks.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Rectangle().fill(.black.opacity(0.07)).frame(height: 0.5).padding(.leading, 42) }
                        HStack(spacing: 10) {
                            AppIcon(source: t.source, size: 20)
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.black.opacity(0.82))
                            Spacer()
                            HStack(spacing: 5) {
                                Dot(state: t.state)
                                Text(stateLabel(t.state)).font(.system(size: 11)).foregroundStyle(.black.opacity(0.5))
                            }
                        }.padding(.horizontal, 12).frame(height: 36)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.45)))
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(width: 340)
            .darkGlass(20, light: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 40).padding(.trailing, 16)
        }
    }
}

// MARK: - Render

let options: [(String, String, AnyView)] = [
    ("1-notch-island", "1 · Notch Island", AnyView(OptIsland())),
    ("2-side-rail", "2 · Side Rail", AnyView(OptRail())),
    ("3-compact-bar-toast", "3 · Compact Bar + Toast", AnyView(OptToast())),
    ("4-menu-bar", "4 · Menu Bar Dropdown", AnyView(OptMenuBar())),
    ("5-desktop-widget", "5 · Desktop Widget", AnyView(OptWidget())),
    ("6-chat-head-orb", "6 · Chat-Head Orb", AnyView(OptOrb())),
    ("7-dock-ticker", "7 · Bottom Ticker", AnyView(OptTicker())),
    ("8-light-glass-card", "8 · Light Glass Card", AnyView(OptLight())),
]

@MainActor
func savePNG<V: View>(_ v: V, _ path: String) {
    let r = ImageRenderer(content: v)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor
func renderOptions(to dir: String) {
    for (file, _, view) in options {
        savePNG(view.environment(\.frozenTime, 1.37), "\(dir)/\(file).png")
    }
    let sheet = VStack(alignment: .leading, spacing: 18) {
        Text("Agent Board · component options").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
        LazyVGrid(columns: [GridItem(.fixed(720), spacing: 24), GridItem(.fixed(720), spacing: 24)], spacing: 28) {
            ForEach(0..<options.count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 10) {
                    Text(options[i].1).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    options[i].2.clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
    .padding(36)
    .background(Color(white: 0.07))
    .environment(\.frozenTime, 1.37)
    savePNG(sheet, "\(dir)/0-all-options.png")
}
