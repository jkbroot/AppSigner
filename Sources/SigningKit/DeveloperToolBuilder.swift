import Foundation

/// Builds a developer tool from its own source on this machine.
///
/// Nothing is downloaded as a binary: the source is cloned from the project's own
/// repository and compiled with the local Xcode toolchain, so what gets injected is
/// something you can reproduce and audit.
public struct DeveloperToolBuilder {
    public enum BuildError: Error, LocalizedError {
        case toolchainMissing(String)
        case unsupportedTool(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolchainMissing(let what):
                return "\(what) is required to build this tool. Install Xcode and its iOS SDK."
            case .unsupportedTool(let id): return "No build recipe for '\(id)'."
            case .failed(let detail): return "Build failed: \(detail)"
            }
        }
    }

    private let runner: ProcessRunner
    public init(runner: ProcessRunner = .init()) { self.runner = runner }

    // MARK: Recipe (pure, so it can be checked without running a build)

    public static func flexCloneArguments(into workDir: URL) -> [String] {
        ["clone", "--depth", "1", "https://github.com/FLEXTool/FLEX.git",
         workDir.appendingPathComponent("FLEX").path]
    }

    public static func flexBuildArguments(projectDir: URL, output: URL) -> [String] {
        ["-project", projectDir.appendingPathComponent("FLEX.xcodeproj").path,
         "-target", "FLEX",
         "-configuration", "Release",
         "-sdk", "iphoneos",
         "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
         "MACH_O_TYPE=mh_dylib",
         "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
         "CONFIGURATION_BUILD_DIR=\(output.path)",
         "build"]
    }

    public static func bootstrapCompileArguments(source: URL, output: URL, sdkPath: String) -> [String] {
        ["-sdk", "iphoneos", "clang",
         "-arch", "arm64", "-dynamiclib", "-fobjc-arc",
         "-isysroot", sdkPath,
         "-mios-version-min=13.0",
         "-framework", "UIKit", "-framework", "Foundation",
         "-Wl,-headerpad_max_install_names",
         "-install_name", "@executable_path/Frameworks/FLEXBootstrap.dylib",
         "-o", output.path, source.path]
    }

    /// The launcher that makes an injected FLEX reachable in an app that knows nothing
    /// about it. FLEX is resolved at runtime, so a missing framework cannot crash the host.
    public static let bootstrapSource = #"""
    // FLEXBootstrap — opens FLEX inside a host app that was never built with it.
    #import <Foundation/Foundation.h>
    #import <UIKit/UIKit.h>
    #import <objc/message.h>

    static void FLEXBootstrapShowExplorer(void) {
        Class managerClass = NSClassFromString(@"FLEXManager");
        if (!managerClass) {
            NSLog(@"[FLEXBootstrap] FLEX.framework is not loaded");
            return;
        }
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, NSSelectorFromString(@"sharedManager"));
        if (!manager) return;
        ((void (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"showExplorer"));
    }

    @interface FLEXBootstrap : NSObject
    @end

    @implementation FLEXBootstrap

    + (void)load {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationLaunched:)
                                                   name:UIApplicationDidFinishLaunchingNotification
                                                 object:nil];
    }

    + (void)applicationLaunched:(NSNotification *)note {
        [self attachAfter:1.0 attempt:0];
    }

    + (void)attachAfter:(double)delay attempt:(int)attempt {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self attach:attempt]; });
    }

    + (void)attach:(int)attempt {
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (!window) window = windowScene.windows.firstObject;
            if (window) break;
        }

        if (!window) {                       // the UI may not be up yet
            if (attempt < 10) [self attachAfter:1.0 attempt:attempt + 1];
            return;
        }

        UILongPressGestureRecognizer *gesture =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleGesture:)];
        gesture.numberOfTouchesRequired = 3;
        gesture.minimumPressDuration = 0.6;
        [window addGestureRecognizer:gesture];
        NSLog(@"[FLEXBootstrap] ready — three-finger long press to open FLEX");
    }

    + (void)handleGesture:(UIGestureRecognizer *)gesture {
        if (gesture.state == UIGestureRecognizerStateBegan) FLEXBootstrapShowExplorer();
    }

    @end
    """#

    // MARK: Running a build

    public func build(_ tool: DeveloperTool, into library: DeveloperToolLibrary,
                      progress: ((String) -> Void)? = nil) throws {
        guard tool.id == "flex" else { throw BuildError.unsupportedTool(tool.id) }
        try buildFLEX(into: library, progress: progress)
    }

    private func buildFLEX(into library: DeveloperToolLibrary,
                           progress: ((String) -> Void)? = nil) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/xcodebuild") else {
            throw BuildError.toolchainMissing("xcodebuild")
        }
        let sdkPath = try runner.runThrowing("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sdkPath.isEmpty else { throw BuildError.toolchainMissing("the iOS SDK") }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flexbuild-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let output = work.appendingPathComponent("out")
        let tool = DeveloperToolCatalog.all.first { $0.id == "flex" }!

        progress?("Cloning FLEX…")
        _ = try runner.runStreaming("/usr/bin/git", Self.flexCloneArguments(into: work)) { progress?($0) }

        progress?("Building FLEX.framework for iOS (arm64)…")
        let projectDir = work.appendingPathComponent("FLEX")
        let code = try runner.runStreaming("/usr/bin/xcodebuild",
                                           Self.flexBuildArguments(projectDir: projectDir, output: output)) {
            if $0.contains("error:") || $0.hasPrefix("**") { progress?($0) }
        }
        guard code == 0 else { throw BuildError.failed("xcodebuild exited with \(code)") }

        // The app does not need the SDK-only parts of the framework.
        let framework = output.appendingPathComponent("FLEX.framework")
        for extra in ["Headers", "Modules"] {
            try? fm.removeItem(at: framework.appendingPathComponent(extra))
        }

        progress?("Building the launcher…")
        let bootstrapSource = work.appendingPathComponent("FLEXBootstrap.m")
        try Data(Self.bootstrapSource.utf8).write(to: bootstrapSource)
        let bootstrap = output.appendingPathComponent("FLEXBootstrap.dylib")
        let compile = try runner.runStreaming("/usr/bin/xcrun",
                                              Self.bootstrapCompileArguments(source: bootstrapSource,
                                                                             output: bootstrap,
                                                                             sdkPath: sdkPath)) { progress?($0) }
        guard compile == 0, fm.fileExists(atPath: bootstrap.path) else {
            throw BuildError.failed("could not compile the launcher")
        }

        progress?("Installing into the tool library…")
        try library.importArtifacts(for: tool, from: output)
        progress?("FLEX is ready.")
    }
}
