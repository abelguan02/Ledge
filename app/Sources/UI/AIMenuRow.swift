import SwiftUI

struct AIMenuRow: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var preferences: AppPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(preferences.interfaceLanguage.label("智能处理")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(preferences.interfaceLanguage.label("智能处理"), isOn: Binding(get: { model.preferences.aiEnabled }, set: { model.preferences.aiEnabled = $0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(model.codexAvailable == false)
            }
            HStack(spacing: 6) {
                Circle().fill(model.codexAvailable == false ? Color.red : model.preferences.aiEnabled && model.codexAvailable == true ? .green : .gray).frame(width: 6, height: 6)
                Text(preferences.interfaceLanguage.label(model.aiStatus)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 14).padding(.vertical, 8).frame(width: 260)
    }
}
