import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// "Send Feedback" sheet, reachable from the Profile footer whether or not
/// the player is signed in. Writes one doc to the append-only `feedback`
/// collection; read it from the Firebase console.
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case bug = "Bug", idea = "Idea", other = "Other"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .bug: "ladybug.fill"
            case .idea: "lightbulb.fill"
            case .other: "bubble.left.fill"
            }
        }
        var prompt: String {
            switch self {
            case .bug: "What happened, and what did you expect instead?"
            case .idea: "What would make Krypto better?"
            case .other: "Anything at all."
            }
        }
    }

    @State private var kind: Kind = .idea
    @State private var message = ""
    @State private var contact = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var errorMessage: String?
    @FocusState private var messageFocused: Bool

    private static let maxLength = 2000

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if sent { thanks } else { form }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if contact.isEmpty, let email = Auth.auth().currentUser?.email { contact = email }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(Kind.allCases) { option in
                        let selected = kind == option
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { kind = option }
                        } label: {
                            Label(option.rawValue, systemImage: option.icon)
                                .font(.system(.subheadline, design: .rounded, weight: .heavy))
                                .foregroundStyle(selected ? .white : Theme.inkDark)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(selected ? Theme.accent : .white, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.prompt)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    TextEditor(text: $message)
                        .focused($messageFocused)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(Theme.inkDark)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                        .onChange(of: message) { _, value in
                            if value.count > Self.maxLength { message = String(value.prefix(Self.maxLength)) }
                        }
                    HStack {
                        Spacer()
                        Text("\(message.count)/\(Self.maxLength)")
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Email, if you'd like a reply (optional)")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                    TextField("Optional", text: $contact)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(Theme.inkDark)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.white))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.red.opacity(0.75))
                }

                Button {
                    Task { await send() }
                } label: {
                    HStack(spacing: 8) {
                        if isSending { ProgressView().tint(.white) }
                        Text(isSending ? "Sending…" : "Send")
                    }
                    .font(.system(.headline, design: .rounded, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.button, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.5)

                Text("Sent with your app version and device model so bugs are easier to track down.")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { messageFocused = true }
    }

    private var thanks: some View {
        VStack(spacing: 14) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("Thanks!")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(Theme.inkDark)
            Text("Every note gets read.")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(40)
    }

    private var canSend: Bool {
        !isSending && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    private func send() async {
        guard canSend else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var fields: [String: Any] = [
            "kind": kind.rawValue.lowercased(),
            "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
            "appVersion": "\(version) (\(build))",
            "device": Self.deviceModel,
            "osVersion": UIDevice.current.systemVersion,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        let trimmedContact = contact.trimmingCharacters(in: .whitespaces)
        if !trimmedContact.isEmpty { fields["contact"] = trimmedContact }
        if let user = Auth.auth().currentUser {
            fields["uid"] = user.uid
            if let name = user.displayName, !name.isEmpty { fields["displayName"] = name }
        }
        do {
            try await Firestore.firestore().collection("feedback").addDocument(data: fields)
            withAnimation { sent = true }
        } catch {
            errorMessage = "Couldn't send right now. Please try again."
        }
    }

    /// Hardware identifier like "iPhone17,1" — more useful for bugs than
    /// `UIDevice.model`'s plain "iPhone".
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(String(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
