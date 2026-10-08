import Foundation

@main
enum LogicTestMain {
    static func main() {
        do {
            try MoonLogicTests.runAll()
            print("logic tests passed")
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}
