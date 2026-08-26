extension CMUXCLI {
    static func requestsSubcommandHelp<S: Sequence>(_ arguments: S) -> Bool
    where S.Element == String {
        var iterator = arguments.makeIterator()
        switch iterator.next()?.lowercased() {
        case "help", "--help", "-h":
            return true
        default:
            break
        }

        while let argument = iterator.next() {
            if argument == "--help" || argument == "-h" {
                return true
            }
        }
        return false
    }
}
