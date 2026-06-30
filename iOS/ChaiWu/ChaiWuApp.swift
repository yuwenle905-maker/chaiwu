import SwiftUI

@main
struct ChaiWuApp: App {
    @StateObject private var vm = TransactionViewModel()
    @StateObject private var sync = SyncEngine.shared
    @AppStorage("biometricLockEnabled") private var biometricLockEnabled = false

    var body: some Scene {
        WindowGroup {
            if biometricLockEnabled && !vm.isUnlocked {
                LockScreenView()
                    .environmentObject(vm)
            } else {
                DashboardView()
                    .environmentObject(vm)
                    .environmentObject(sync)
                    .onAppear {
                        if !vm.isUnlocked {
                            vm.isUnlocked = true
                            vm.reload()
                            SyncEngine.shared.startWatching()
                        }
                    }
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
            Text("账单")
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
