import AppKit
import SwiftUI

struct CoffeePaymentCode: View {
    @Environment(\.ledgeSkin) private var skin
    // This is a standalone bundle resource, not an asset-catalog image.
    private let image = Bundle.main.image(forResource: "CoffeePayment")

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("作者收款码")
            } else {
                Text("收款码未能加载").font(skin.typography.body).foregroundStyle(skin.palette.paymentMissingText)
            }
        }.frame(width: 196, height: 196).background(skin.palette.light)
            .clipShape(skin.shapes.payment)
            .anchorPreference(key: SkinScanlineExclusion.self, value: .bounds) { $0 }
    }
}
