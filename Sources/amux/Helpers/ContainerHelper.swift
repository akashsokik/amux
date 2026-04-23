import Foundation

// Thin wrapper around the `docker` CLI. Callers dispatch on a background
// queue; helper parses tab-delimited Go template output. Returns nil when
// docker is unavailable so UIs can distinguish "missing daemon" from
// "empty list".

enum ContainerHelper {
    struct Container {
        let id: String
        let names: String
        let image: String
        let command: String
        let createdAgo: String
        let status: String
        let ports: String
        var isRunning: Bool { status.lowercased().hasPrefix("up") }
    }

    struct Image {
        let id: String
        let repository: String
        let tag: String
        let createdAgo: String
        let size: String
        var displayName: String {
            if repository == "<none>" { return id }
            return tag.isEmpty || tag == "<none>" ? repository : "\(repository):\(tag)"
        }
    }

    struct Detail {
        let id: String
        let shortID: String
        let name: String
        let image: String
        let imageID: String
        let created: String
        let platform: String
        let state: String
        let statusText: String
        let command: String
        let entrypoint: String
        let workingDir: String
        let env: [(String, String)]
        let labels: [(String, String)]
        let exposedPorts: [String]
        let publishedPorts: [String]
        let mounts: [(source: String, destination: String, mode: String)]
        let networks: [String]
    }

    enum Availability {
        case available(String)
        case missing
    }

    static func availability() -> Availability {
        for path in ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return .available(path)
            }
        }
        return .missing
    }

    static func listContainers(showAll: Bool = true) -> [Container]? {
        guard case .available(let docker) = availability() else { return nil }
        let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Command}}\t{{.RunningFor}}\t{{.Status}}\t{{.Ports}}"
        var args = ["ps", "--no-trunc", "--format", format]
        if showAll { args.insert("-a", at: 1) }
        guard let output = run(docker, args: args) else { return nil }
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> Container? in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 7 else { return nil }
            return Container(
                id: String(cols[0].prefix(12)),
                names: cols[1].split(separator: ",").first.map(String.init) ?? cols[1],
                image: cols[2],
                command: cols[3].trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                createdAgo: cols[4],
                status: cols[5],
                ports: cols[6]
            )
        }
    }

    static func listImages() -> [Image]? {
        guard case .available(let docker) = availability() else { return nil }
        let format = "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}"
        guard let output = run(docker, args: ["images", "--format", format]) else { return nil }
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> Image? in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5 else { return nil }
            return Image(id: String(cols[0].prefix(12)), repository: cols[1], tag: cols[2], createdAgo: cols[3], size: cols[4])
        }
    }

    @discardableResult static func start(_ id: String) -> Bool { runCmd(["start", id]) }
    @discardableResult static func stop(_ id: String) -> Bool { runCmd(["stop", id]) }
    @discardableResult
    static func removeContainer(_ id: String, force: Bool = true) -> Bool {
        var args = ["rm"]; if force { args.append("-f") }; args.append(id); return runCmd(args)
    }
    @discardableResult
    static func removeImage(_ id: String, force: Bool = false) -> Bool {
        var args = ["rmi"]; if force { args.append("-f") }; args.append(id); return runCmd(args)
    }

    static func inspect(_ id: String) -> Detail? {
        guard case .available(let docker) = availability() else { return nil }
        guard let raw = run(docker, args: ["inspect", id]),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let root = json.first else { return nil }

        let fullID = root["Id"] as? String ?? id
        let name = ((root["Name"] as? String) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let created = root["Created"] as? String ?? ""
        let os = root["Os"] as? String ?? ""
        let arch = root["Architecture"] as? String ?? ""
        let platform = [os, arch].filter { !$0.isEmpty }.joined(separator: "/")

        let state = root["State"] as? [String: Any] ?? [:]
        let stateStatus = state["Status"] as? String ?? ""
        let stateStarted = state["StartedAt"] as? String ?? ""
        let stateExit = state["ExitCode"] as? Int ?? 0
        let stateText: String = {
            if stateStatus == "running" { return "Running since \(stateStarted)" }
            if stateStatus.isEmpty { return "" }
            return "\(stateStatus) (exit \(stateExit))"
        }()

        let config = root["Config"] as? [String: Any] ?? [:]
        let image = config["Image"] as? String ?? (root["Image"] as? String ?? "")
        let imageID = (root["Image"] as? String ?? "")
        let cmd = ((config["Cmd"] as? [String]) ?? []).joined(separator: " ")
        let entry = ((config["Entrypoint"] as? [String]) ?? []).joined(separator: " ")
        let workDir = config["WorkingDir"] as? String ?? ""

        var envPairs: [(String, String)] = []
        for item in (config["Env"] as? [String]) ?? [] {
            if let eq = item.firstIndex(of: "=") {
                envPairs.append((String(item[..<eq]), String(item[item.index(after: eq)...])))
            } else {
                envPairs.append((item, ""))
            }
        }

        var labelPairs: [(String, String)] = []
        for (k, v) in (config["Labels"] as? [String: String]) ?? [:] { labelPairs.append((k, v)) }
        labelPairs.sort { $0.0 < $1.0 }

        let exposed = ((config["ExposedPorts"] as? [String: Any]) ?? [:]).keys.sorted()

        var published: [String] = []
        if let ns = root["NetworkSettings"] as? [String: Any],
           let ports = ns["Ports"] as? [String: Any] {
            for (container, bindings) in ports {
                if let arr = bindings as? [[String: Any]] {
                    for b in arr {
                        let hostIP = b["HostIp"] as? String ?? ""
                        let hostPort = b["HostPort"] as? String ?? ""
                        let host = hostIP.isEmpty ? hostPort : "\(hostIP):\(hostPort)"
                        published.append("\(host) → \(container)")
                    }
                } else {
                    published.append(container)
                }
            }
        }
        published.sort()

        var mounts: [(String, String, String)] = []
        for m in (root["Mounts"] as? [[String: Any]]) ?? [] {
            mounts.append((m["Source"] as? String ?? "", m["Destination"] as? String ?? "", m["Mode"] as? String ?? ""))
        }

        var networks: [String] = []
        if let ns = root["NetworkSettings"] as? [String: Any],
           let nets = ns["Networks"] as? [String: Any] {
            networks = nets.keys.sorted()
        }

        return Detail(
            id: fullID, shortID: String(fullID.prefix(12)), name: name, image: image, imageID: imageID,
            created: created, platform: platform, state: stateStatus, statusText: stateText,
            command: cmd, entrypoint: entry, workingDir: workDir,
            env: envPairs, labels: labelPairs, exposedPorts: Array(exposed),
            publishedPorts: published, mounts: mounts, networks: networks
        )
    }

    private static func runCmd(_ args: [String]) -> Bool {
        guard case .available(let docker) = availability() else { return false }
        return run(docker, args: args) != nil
    }

    private static func run(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }
}
