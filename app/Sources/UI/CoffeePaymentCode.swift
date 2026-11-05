import AppKit
import SwiftUI

enum CoffeePaymentMethod: String, CaseIterable {
    case wechat = "微信支付"
    case alipay = "支付宝"

    var resourceName: String { self == .wechat ? "CoffeePayment" : "AlipayPayment" }
}

struct CoffeePaymentCode: View {
    @Environment(\.ledgeSkin) private var skin
    // This is a standalone bundle resource, not an asset-catalog image.
    let method: CoffeePaymentMethod

    var body: some View {
        Group {
            if let image = Bundle.main.image(forResource: method.resourceName) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel(skin.phrase("%@收款码", skin.label(method.rawValue)))
            } else {
                Text(skin.label("收款码未能加载")).font(skin.typography.body).foregroundStyle(skin.palette.paymentMissingText)
            }
        }.frame(width: 196, height: 196).background(skin.palette.light)
            .clipShape(skin.shapes.payment)
            .anchorPreference(key: SkinScanlineExclusion.self, value: .bounds) { $0 }
    }
}
