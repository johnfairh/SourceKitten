//
//  SwiftPMTaskReader.swift
//  SourceKittenFramework
//
import Foundation

/// Utilities to dig the serialized taskstore out of the XCBuildData then dig the Swift Module
/// build commands out of that.
enum SpmTaskReader {
    struct Err: Error {
        let message: String
    }

    struct Task {
        let description: String
        let identifier: String
        let arguments: [String]
    }

    struct Module {
        let name: String
        let arch: String
        let args: [String]

        init(task: Task) {
            let descItems = task.description.split(separator: " ")
            self.name = String(descItems[1])
            self.arch = String(descItems[2])
            self.args = Array(task.arguments[2...])
        }
    }

    typealias ModuleSet = [String : Module]

    static func read(spmDir: String) throws -> ModuleSet {
        let xcBuildDataDir = URL(fileURLWithPath: spmDir)
            .appendingPathComponent(".build/out/Intermediates.noindex/XCBuildData")
        let buildCookie = try readLatestBuildDescription(xcBuildDataDir: xcBuildDataDir)
        let msgPackURL = xcBuildDataDir
            .appendingPathComponent("\(buildCookie).xcbuilddata")
            .appendingPathComponent("task-store.msgpack")

        return try read(msgPackURL: msgPackURL)
    }

    static func readLatestBuildDescription(xcBuildDataDir: URL) throws -> some StringProtocol {
        let buildCookieURL = xcBuildDataDir.appendingPathComponent("prior-build-descriptions.txt")
        let buildCookies = try String(contentsOf: buildCookieURL).split(separator: "\n")
        guard let latestBuildCookie = buildCookies.last else {
            throw Err(message: "No build cookies found in \(buildCookieURL.path)")
        }
        return latestBuildCookie
    }

    static func read(msgPackURL: URL) throws -> ModuleSet {
        let taskStore = try Data(contentsOf: msgPackURL)

//        print("Got \(taskStore.count) bytes from task-store.msgpack")

        let tasks = try swiftCompilerTasks(taskStore: taskStore)

//        print("Got \(tasks.count) swift compiler tasks")

        var modules: ModuleSet = [:]
        for task in tasks {
            let module = Module(task: task)
            if modules[module.name] == nil || module.arch.contains("arm64") {
                modules[module.name] = module
            }
        }

//        print("Got \(modules.count) unique module recipes")

//        for module in modules.values {
//            print("-----------------------------------")
//            print(module.name)
//            print(module.args)
//        }
//
        return modules
    }

    private static func swiftCompilerTasks(taskStore: Data) throws -> [Task] {
        guard let taskArray = try taskStore.unpack() as? [Any] else {
            throw Err(message: "Failed to unpack task-store.msgpack")
        }

//        print("Got \(taskArray.count) total tasks")

        return try taskArray.compactMap { taskRaw in
            guard let taskElements = taskRaw as? [Any],
                  taskElements.count == 25 else {
                throw Err(message: "Found something not a task in the task array - new SPM?")
            }

            guard let di = taskElements[0] as? [String], di.count == 2 else {
                // Nil / Gate task
                return nil
            }

            let taskIdentifier = di[1]

            guard taskIdentifier == "com.apple.xcode.tools.swift.compiler" else {
                return nil
            }

            let description = taskElements[11] as? String ?? ""
            guard description.hasPrefix("Compile ") else {
                return nil
            }

            guard let rawCliArgs = taskElements[6] as? [Any?] else {
                throw Err(message: "Confused - can't find cli-args")
            }
            let cliArgs = try rawCliArgs.map { argRaw in
                guard let argArrayRaw = argRaw as? [Any],
                      let argType = argArrayRaw[0] as? UInt8 else {
                    throw Err(message: "Confused - can't find cli-arg type: \(argRaw ?? "[nil]")")
                }
                guard argType == 0 else {
                    throw Err(message: "Sadly found a non-byte-string argType: \(argType)")
                }
                guard let byteString = argArrayRaw[1] as? Data else {
                    throw Err(message: "CLI byte-string arg is not Data: \(argArrayRaw[1])")
                }
                guard let string = String(bytes: byteString, encoding: .utf8) else {
                    throw Err(message: "Can't get string out of Data: \(byteString)")
                }
                return string
            }

            return Task(description: description, identifier: taskIdentifier, arguments: cliArgs)
        }
    }
}

extension SwiftPM {
    static func fromBuildTaskStore(inPath path: String, moduleName: String?) -> (String, [String])? {
        do {
            let modules = try SpmTaskReader.read(spmDir: path)

            let module: SpmTaskReader.Module?

            if let moduleName {
                module = modules[moduleName]
            } else {
                module = modules.first?.value
            }

            guard let module else {
                fputs("Can't find swift module \(moduleName ?? "(any)") in taskstore\n", stderr)
                fputs("Available module names are: \(modules.keys.joined(separator: ", "))\n", stderr)
                return nil
            }

            return (module.name, Array(filterForSourceKit(arguments: module.args).dropFirst()))
        } catch let error as SpmTaskReader.Err {
            fputs("TaskReader Err: \(error.message)\n", stderr)
        } catch {
            fputs("Mysterious error: \(error)\n", stderr)
        }
        return nil
    }
}
