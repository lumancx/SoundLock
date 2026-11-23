import SwiftUI

struct HeaderView: View {
    @ObservedObject var monitor: AudioDeviceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("SoundLock")
                    .font(Theme.headerTitleFont)
                Spacer()
                Toggle("", isOn: $monitor.guardEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if monitor.guardEnabled, monitor.activeAirPlayOutput != nil {
                Text("Priority paused until AirPlay stops")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Theme.headerHorizontalInset)
        .padding(.vertical, 10)
    }
}
