import Foundation

/// Alle eingebauten Adapter. App und kastellan-mcp holen sich hier ihre Registry.
public enum BuiltinAdapters {
    public static var registry: AdapterRegistry {
        var r = AdapterRegistry()
        register(into: &r)
        return r
    }

    /// Neue Adapter hier eintragen (Phase 1: All-Inkl KAS, Phase 2: Cloudflare, Hetzner, Phase 3b: hosting.de, Phase 3c: Mittwald, Phase 3d: Hostinger).
    static func register(into registry: inout AdapterRegistry) {
        registry.register(KASAdapter.self)
        registry.register(CloudflareAdapter.self)
        registry.register(HetznerAdapter.self)
        registry.register(HostingDeAdapter.self)
        registry.register(MittwaldAdapter.self)
        registry.register(HostingerAdapter.self)
    }
}
