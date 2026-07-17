extension CMUXCLI {
    static func requestsSubcommandHelp<S: Sequence>(_ args: S) -> Bool where S.Element == String {
        var iterator = args.makeIterator()
        switch iterator.next()?.lowercased() {
        case "help", "--help", "-h":
            return true
        default:
            break
        }
        while let arg = iterator.next() {
            if arg == "--help" || arg == "-h" {
                return true
            }
        }
        return false
    }
}
