import SwiftUI

@main
struct ChaiWuApp: App {
    @StateObject private var vm = TransactionViewModel()
    @StateObject private var sync = SyncEngine.shared

    var body: some Scene {
        WindowGroup {
            if vm.isUnlocked {
                DashboardView()
                    .environmentObject(vm)
                    .environmentObject(sync)
            } else {
                LockScreenView()
                    .environmentObject(vm)
            }
        }
    }
}

struct LockScreenView: View {
    @EnvironmentObject var vm: TransactionViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue.gradient)
            Text("柴务")
                .font(.largeTitle.bold())
            Text("个人财务管理")
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { vm.authenticate() }) {
                Label("Face ID / Touch ID 解锁", systemImage: "faceid")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 40)
            if let err = vm.authError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .onAppear { vm.authenticate() }
    }
}
