import StoreKit

@MainActor
final class StoreKitManager: ObservableObject {
    static let competitionModeID = "com.edwinma.krypto.competitionmode"

    @Published var product: Product?
    @Published var isPurchasing = false
    @Published var errorMessage: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { await listenForTransactions() }
        Task { await loadProduct() }
    }

    deinit {
        transactionListener?.cancel()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.competitionModeID])
            product = products.first
        } catch {
            errorMessage = "Couldn't load the store. Check your connection."
        }
    }

    /// Returns true once the purchase completes and is verified.
    func purchase() async -> Bool {
        guard let product else { return false }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    errorMessage = "Purchase couldn't be verified."
                    return false
                }
                await transaction.finish()
                return true
            case .userCancelled:
                return false
            case .pending:
                errorMessage = "Purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            errorMessage = "Purchase failed. Please try again."
            return false
        }
    }

    private func listenForTransactions() async {
        for await update in Transaction.updates {
            if case .verified(let transaction) = update {
                await transaction.finish()
            }
        }
    }
}
