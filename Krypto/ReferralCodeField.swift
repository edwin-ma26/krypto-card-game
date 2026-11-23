import SwiftUI

/// The optional "friend's code" input on the sign-up forms.
///
/// This is the only attribution path that actually survives an install: a link
/// tapped in Messages carries nothing through the App Store into a fresh app,
/// so unless the new player types the code in themselves, there's no way to
/// know who sent them. Putting it in front of them at sign-up is what makes the
/// existing referral system usable by people who never go looking for it.
struct ReferralCodeField: View {
    @Binding var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Friend's code (optional)")
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color(.darkGray))
                .padding(.leading, 4)

            TextField("CODE", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.inkDark)
                .tint(Theme.inkDark)
                .padding()
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 16))

            Text("Got invited? Enter their code so they get credit.")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .padding(.leading, 4)
        }
    }
}
