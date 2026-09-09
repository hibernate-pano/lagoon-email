import Hummingbird

public enum HealthRoutes {
    public static func register(on router: Router<BasicRequestContext>) {
        router.get("healthz") { _, _ in
            "ok"
        }
    }
}