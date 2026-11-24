import SwiftUI

let brand = Color(red: 0x2E / 255, green: 0x35 / 255, blue: 0x8F / 255)   // Alaswaq Alwatania blue
let teal = Color(red: 0, green: 0xA3 / 255, blue: 0xA3 / 255)
let footerGrey = Color(red: 0x8A / 255, green: 0x92 / 255, blue: 0x9E / 255)

@main
struct StockCountApp: App {
    @StateObject private var store = Store()
    @AppStorage("theme") private var theme = "system"

    init() {
        // Brand-blue navigation bar with white text, like the Android app.
        let a = UINavigationBarAppearance()
        a.configureWithOpaqueBackground()
        a.backgroundColor = UIColor(red: 0x2E / 255, green: 0x35 / 255, blue: 0x8F / 255, alpha: 1)
        a.titleTextAttributes = [.foregroundColor: UIColor.white]
        a.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = a
        UINavigationBar.appearance().scrollEdgeAppearance = a
        UINavigationBar.appearance().compactAppearance = a
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        }
    }
}
