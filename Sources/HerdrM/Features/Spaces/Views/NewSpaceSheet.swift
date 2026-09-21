import AppKit
import HerdrKit
import SwiftUI

struct NewSpaceSheet: View {
    @ObservedObject var model: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    // The trailing slash keeps typing in filter position from the first keystroke.
    @State private var directory = "~/"
    @State private var label = ""

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "folder.badge.plus",
                title: String(localized: "New Space"),
                subtitle: String(localized: "A herdr workspace rooted at a project directory on \(chosenDevice.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("DIRECTORY")
                DirectoryPickerField(model: model, device: chosenDevice, path: $directory)
                if !chosenDevice.isLocal {
                    Text(String(localized: "Path on \(chosenDevice.name); ~ expands to its home directory"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer().frame(height: 8)

                SheetSectionLabel("NAME")
                TextField("Defaults to the folder name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Space") {
                    model.createNewSpace(device: chosenDevice, directory: directory, label: label)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440)
        .onAppear {
            deviceID = model.deviceFilter ?? model.devices.first?.id ?? Device.local.id
        }
    }
}
