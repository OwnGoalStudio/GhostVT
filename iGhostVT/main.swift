//
//  main.swift
//  iGhostVT
//

@_exported import Foundation
@_exported import UIKit

#if targetEnvironment(macCatalyst)
    // Before any scene exists: it hooks the scene's window creation.
    CatalystWindowChrome.install()
#endif

_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
