import AppKit

enum ProcessDisplayName {
    /// Resolve only the processes shown in the menu, without scanning other apps.
    static func name(for pid: pid_t) -> String {
        let executableURL = ProcessSampler.executableURL(for: pid)
        return resolve(
            applicationName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            executableURL: executableURL,
            executableName: executableURL?.lastPathComponent ?? ProcessSampler.name(for: pid))
    }

    static func resolve(applicationName: String?, executableURL: URL?,
                        executableName: String) -> String {
        if let name = nonempty(applicationName) { return name }
        if var url = executableURL?.deletingLastPathComponent() {
            while url.path != "/" {
                if url.pathExtension.lowercased() == "app",
                   let info = Bundle(url: url)?.infoDictionary,
                   let name = nonempty(info["CFBundleDisplayName"] as? String)
                       ?? nonempty(info["CFBundleName"] as? String) {
                    // A bundled worker still represents its own PID and usage,
                    // rather than the total usage of the containing app.
                    if info["CFBundleExecutable"] as? String == executableName
                        || name == executableName {
                        return name
                    }
                    return "\(name) (\(executableName))"
                }
                url.deleteLastPathComponent()
            }
        }
        return executableName
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
