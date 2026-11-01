import AppKit
import SwiftUI

struct CoffeePaymentCode: View {
    // This is a standalone bundle resource, not an asset-catalog image.
    private let image = Bundle.main.image(forResource: "CoffeePayment")

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .accessibilityLabel("作者收款码")
            } else {
                Text("收款码未能加载").font(.system(size: 13)).foregroundStyle(.black.opacity(0.65))
            }
        }.frame(width: 196, height: 196).background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
