import SwiftUI
import AppKit
import msgblastCore

struct OnboardingPermissionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: OnboardingController
    @ObservedObject private var messages: AppPermissions
    @ObservedObject private var apps: CuaPermissionsController
    @State private var openedHistorySettings = false

    init(model: AppModel, setup: OnboardingController) {
        self.model = model
        self.setup = setup
        messages = setup.messagesPermissions
        apps = setup.appPermissions
    }

    private var busy: Bool { setup.permissionChecksBusy || setup.checking || model.busy || model.webBroadcastBusy }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Image(systemName: "shield").font(.system(size: 32, weight: .light))
                    Text("Allow access").font(.system(size: 28, weight: .semibold))
                }
                Divider()
                PermissionControlsView(model: model, setup: setup) { openedHistorySettings = true }
            }
            .padding(16).frame(maxWidth: 680, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
            .padding(.horizontal, 28).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Back") { setup.reviewStats() }
                if openedHistorySettings && messages.history != .allowed {
                    Button("Restart & check access") {
                        guard setup.checkpointPermissionChange() else { return }
                        setup.restartForAccess()
                    }.disabled(busy)
                }
                if setup.permissionChecksBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Skip for now") { Task { await setup.skipPermissionSetup() } }
                    .disabled(busy)
                    .accessibilityIdentifier("skip-permissions")
                Button("Continue") { Task { await setup.finishPermissionSetup() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!setup.permissionSetupReady || busy)
                    .accessibilityIdentifier("continue-permissions")
            }.padding(20)
        }
    }
}
