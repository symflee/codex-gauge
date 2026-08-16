import CodexGaugeCore

struct StatusWidthPrototypeBuilder: Sendable {
    func prototypes(for frames: [DisplayFrame]) -> [DisplayFrame] {
        frames.map(prototype)
    }

    private func prototype(for frame: DisplayFrame) -> DisplayFrame {
        switch frame {
        case .single(let quota):
            .single(prototype(for: quota))
        case .comparison(let codex, let spark):
            .comparison(
                codex: prototype(for: codex),
                spark: prototype(for: spark)
            )
        }
    }

    private func prototype(for quota: DisplayQuota) -> DisplayQuota {
        DisplayQuota(identifier: quota.identifier, value: .stale(100))
    }
}
