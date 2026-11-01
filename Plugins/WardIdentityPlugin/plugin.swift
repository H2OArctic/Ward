import Foundation
import PackagePlugin

@main
struct WardIdentityPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let configuration = root.appendingPathComponent("build/application-id")
        guard FileManager.default.fileExists(atPath: configuration.path) else {
            Diagnostics.error("Configure WARD_BUNDLE_ID first: bash tools/build-identity.sh configure build/application-id")
            return []
        }
        let generator = root.appendingPathComponent("tools/build-identity.sh")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("WardBuildIdentity.swift")
        return [.buildCommand(
            displayName: "Generating Ward build identity",
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [generator.path, "generate", configuration.path, output.path],
            inputFiles: [configuration, generator],
            outputFiles: [output]
        )]
    }
}
