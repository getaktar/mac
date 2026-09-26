import Foundation

enum ObjectKeyGenerator {
    static func generate(template: String, originalFilename: String, date: Date = .now) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%02d", components.month ?? 0)
        let day = String(format: "%02d", components.day ?? 0)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timeString = timeFormatter.string(from: date)

        let ext = (originalFilename as NSString).pathExtension
        let nameWithoutExt = (originalFilename as NSString).deletingPathExtension
        let uuid = UUID().uuidString.lowercased()
        let random = String(UUID().uuidString.prefix(8)).lowercased()

        let replacements: [(String, String)] = [
            ("{year}", year),
            ("{month}", month),
            ("{day}", day),
            ("{date}", dateString),
            ("{time}", timeString),
            ("{filename}", nameWithoutExt),
            ("{uuid}", uuid),
            ("{random}", random),
            ("{ext}", ext),
        ]

        var result = template
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }
}
