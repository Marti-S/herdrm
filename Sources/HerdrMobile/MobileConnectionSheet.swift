import HerdrKit
import SwiftUI
import UIKit

struct AddConnectionSheet: View {
  enum ConnectionKind: String, CaseIterable, Identifiable {
    case bridge
    case directSSH

    var id: Self { self }
    var title: String {
      switch self {
      case .bridge: return String(localized: "Mac Bridge")
      case .directSSH: return String(localized: "Direct SSH")
      }
    }
  }

  @Bindable var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss
  @State private var kind: ConnectionKind

  @State private var pairingJSON = ""
  @State private var bridgeName = ""
  @State private var bridgeHost = ""
  @State private var bridgePort = String(FleetBridgeProtocol.defaultPort)
  @State private var bridgeToken = ""
  @State private var expectedServerID: UUID?
  @State private var pairingIsLoopbackOnly = false

  @State private var directName = ""
  @State private var directHost = ""
  @State private var directPort = "22"
  @State private var username = ""
  @State private var authMethod: MobileDevice.AuthMethod = .deviceKey
  @State private var password = ""
  @State private var copiedKey = false
  @State private var errorMessage: String?

  init(model: MobileAppModel) {
    self.model = model
    _kind = State(initialValue: model.bridge == nil ? .bridge : .directSSH)
  }

  private var canAdd: Bool {
    switch kind {
    case .bridge:
      return !bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && expectedServerID != nil
        && UInt16(bridgePort) != nil
    case .directSSH:
      return !directHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (authMethod == .deviceKey || !password.isEmpty)
        && UInt16(directPort) != nil
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker(String(localized: "Connection"), selection: $kind) {
          ForEach(ConnectionKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)

        switch kind {
        case .bridge:
          bridgeForm
        case .directSSH:
          directSSHForm
        }
      }
      .navigationTitle(String(localized: "Add Connection"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(String(localized: "Cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Add"), action: add)
            .disabled(!canAdd)
        }
      }
      .alert(
        String(localized: "Could Not Add Connection"),
        isPresented: Binding(
          get: { errorMessage != nil },
          set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button(String(localized: "OK"), role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }

  private var bridgeForm: some View {
    Group {
      Section(String(localized: "Pairing")) {
        TextEditor(text: $pairingJSON)
          .font(.system(size: 12, design: .monospaced))
          .frame(minHeight: 90)
          .overlay(alignment: .topLeading) {
            if pairingJSON.isEmpty {
              Text(String(localized: "Paste mobile-pairing.json here"))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.leading, 5)
                .allowsHitTesting(false)
            }
          }
        HStack {
          Button(String(localized: "Paste from Clipboard")) {
            pairingJSON = UIPasteboard.general.string ?? ""
            parsePairingJSON()
          }
          Spacer()
          Button(String(localized: "Apply JSON"), action: parsePairingJSON)
            .disabled(pairingJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text(
          String(
            localized:
              "On the Mac, copy ~/Library/Application Support/HerdrM/mobile-pairing.json. The host below may be replaced with its Tailscale IP or MagicDNS name."
          )
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section(String(localized: "Mac Bridge")) {
        TextField(String(localized: "Name (optional)"), text: $bridgeName)
        TextField(String(localized: "Tailscale host or IP"), text: $bridgeHost)
          .textContentType(.URL)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        TextField(String(localized: "Port"), text: $bridgePort)
          .keyboardType(.numberPad)
        TextField(
          String(localized: "Mac ID"),
          text: Binding(
            get: { expectedServerID?.uuidString ?? "" },
            set: {
              expectedServerID = UUID(
                uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
          )
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        SecureField(String(localized: "Pairing Token"), text: $bridgeToken)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }

      if pairingIsLoopbackOnly {
        Section {
          Text(
            String(
              localized:
                "This Mac currently listens on loopback only. Expose TCP port 45983 through Tailscale, or enable the bridge on all interfaces before connecting directly to the Mac's tailnet address."
            )
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var directSSHForm: some View {
    Group {
      Section(String(localized: "Device")) {
        TextField(String(localized: "Name (optional)"), text: $directName)
        TextField(String(localized: "Host or IP"), text: $directHost)
          .textContentType(.URL)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        TextField(String(localized: "Port"), text: $directPort)
          .keyboardType(.numberPad)
      }
      Section(String(localized: "SSH Login")) {
        TextField(String(localized: "Username"), text: $username)
          .textContentType(.username)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
        Picker(String(localized: "Authentication"), selection: $authMethod) {
          Text(String(localized: "Device Key"))
            .tag(MobileDevice.AuthMethod.deviceKey)
          Text(String(localized: "Password"))
            .tag(MobileDevice.AuthMethod.password)
        }
        if authMethod == .password {
          SecureField(String(localized: "Password"), text: $password)
            .textContentType(.password)
        }
      }
      if authMethod == .deviceKey {
        Section(String(localized: "This Phone's Key")) {
          Text(model.deviceKeyAuthorizedLine)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(3)
            .textSelection(.enabled)
          Button(
            copiedKey
              ? String(localized: "Copied")
              : String(localized: "Copy authorized_keys Line")
          ) {
            UIPasteboard.general.string = model.deviceKeyAuthorizedLine
            copiedKey = true
          }
          Text(
            String(localized: "Append this line to ~/.ssh/authorized_keys on the target host.")
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func parsePairingJSON() {
    do {
      let info = try MobileBridgePairingInfo.decode(pairingJSON)
      bridgeName = info.serverName
      bridgeHost = info.hostHint
      bridgePort = String(info.port)
      bridgeToken = info.token
      expectedServerID = info.serverID
      pairingIsLoopbackOnly = info.loopbackOnly
    } catch {
      errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  private func add() {
    switch kind {
    case .bridge:
      do {
        try model.addBridge(
          name: bridgeName,
          host: bridgeHost,
          port: UInt16(bridgePort) ?? FleetBridgeProtocol.defaultPort,
          token: bridgeToken,
          expectedServerID: expectedServerID
        )
        dismiss()
      } catch {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      }

    case .directSSH:
      model.addDirectDevice(
        name: directName,
        host: directHost,
        port: UInt16(directPort) ?? 22,
        username: username,
        authMethod: authMethod,
        password: password
      )
      dismiss()
    }
  }
}
