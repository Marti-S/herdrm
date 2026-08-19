import AppKit
import HerdrKit
import SwiftUI

/// Renders a bundled mono SVG brand icon (LobeHub agent icons, Simple Icons OS icons)
/// as a template image so it tints like SF Symbols.
struct BrandIcon: View {
    let resource: String
    var size: CGFloat = 12
    var fallbackSystemName: String = "terminal"

    var body: some View {
        if let image = BrandIconLoader.image(named: resource) {
            // Color variants keep their brand colors; mono ones tint like SF Symbols.
            Image(nsImage: image)
                .resizable()
                .renderingMode(resource.hasSuffix("-color") ? .original : .template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: size - 1))
        }
    }
}

enum BrandIconLoader {
    private static var cache: [String: NSImage?] = [:]
    private static let lock = NSLock()

    static func image(named name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        var loaded: NSImage?
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = !name.hasSuffix("-color")
            loaded = image
        }
        cache[name] = loaded
        return loaded
    }

    /// A fixed-size template copy for AppKit menus (menu labels ignore SwiftUI frames).
    static func menuImage(named name: String, size: CGFloat = 14) -> NSImage? {
        guard let base = image(named: name) else { return nil }
        let sized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        sized.isTemplate = true
        return sized
    }

    /// Maps a herdr agent kind ("claude", "codex", "grok", …) to a bundled icon resource,
    /// preferring the brand-color variant when one is bundled.
    static func agentIcon(for kind: String) -> String? {
        let normalized = kind.lowercased().replacingOccurrences(of: "_", with: "-")
        let map: [String: String] = [
            "claude": "claude", "claude-code": "claude",
            "codex": "codex",
            "grok": "grok",
            "cursor": "cursor", "cursor-agent": "cursor",
            "opencode": "opencode",
            "openai": "openai", "gpt": "openai",
            "gemini": "gemini",
            "deepseek": "deepseek",
            "qwen": "qwen", "qwen-code": "qwen",
            "copilot": "copilot", "github-copilot": "githubcopilot",
        ]
        var base: String?
        if let exact = map[normalized] {
            base = exact
        } else {
            for (key, value) in map where normalized.hasPrefix(key) {
                base = value
                break
            }
        }
        guard let base else { return nil }
        if Bundle.main.url(forResource: "\(base)-color", withExtension: "svg") != nil {
            return "\(base)-color"
        }
        return base
    }

    /// Maps a sniffed OS id ("macos", "ubuntu", "debian", …) to a bundled icon resource.
    static func osIcon(for osID: String?) -> String? {
        guard let os = osID?.lowercased(), !os.isEmpty else { return nil }
        let map: [String: String] = [
            "macos": "apple", "darwin": "apple",
            "ubuntu": "ubuntu",
            "debian": "debian",
            "fedora": "fedora",
            "arch": "archlinux", "archlinux": "archlinux",
            "alpine": "alpinelinux",
            "nixos": "nixos",
            "rocky": "rockylinux",
            "centos": "centos",
            "freebsd": "freebsd",
        ]
        if let exact = map[os] { return exact }
        if os.contains("linux") { return "linux" }
        return nil
    }
}

/// Agent-kind icon + label, used in sidebar rows and the detail header.
struct AgentKindBadge: View {
    let kind: String
    var iconSize: CGFloat = 11
    var fontSize: CGFloat = 11.5
    var color: Color = Theme.textTertiary

    var body: some View {
        HStack(spacing: 4) {
            if let resource = BrandIconLoader.agentIcon(for: kind) {
                BrandIcon(resource: resource, size: iconSize)
                    .foregroundStyle(color)
            }
            Text(kind)
                .font(.system(size: fontSize))
                .foregroundStyle(color)
        }
    }
}

/// Small tinted chip naming the device a row belongs to. Each device gets a
/// stable distinct color, so identical OS icons (two Macs) stay tellable apart.
struct DeviceChip: View {
    let device: Device

    private var shortName: String {
        device.name.count > 12 ? String(device.name.prefix(11)) + "…" : device.name
    }

    var body: some View {
        let tint = Theme.deviceTint(device)
        HStack(spacing: 3) {
            DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 8)
            Text(shortName)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(height: 15)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
        .fixedSize()
        .help(device.name)
    }
}

/// Device icon: sniffed-OS brand mark, falling back to a generic machine symbol.
struct DeviceIcon: View {
    let osID: String?
    let isLocal: Bool
    var size: CGFloat = 12

    var body: some View {
        if let resource = BrandIconLoader.osIcon(for: osID) {
            BrandIcon(resource: resource, size: size)
        } else {
            Image(systemName: isLocal ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: size - 0.5))
        }
    }
}
