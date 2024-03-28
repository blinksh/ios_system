//
//  jsc.swift
//  ios_system
//
//  Created by Nicolas Holzschuch on 01/04/2020.
//  Copyright © 2020 Nicolas Holzschuch. All rights reserved.
//

import Foundation
import ios_system
import JavaScriptCore

extension URL {
    // shorthand to check if URL is directory
    public var isDirectory: Bool {
        let keys = Set<URLResourceKey>([URLResourceKey.isDirectoryKey])
        let value = try? self.resourceValues(forKeys: keys)
        switch value?.isDirectory {
        case .some(true):
            return true
            
        default:
            return false
        }
    }
}

/* 
func convertCArguments(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> [String]? {
    
    var args = [String]()
    
    for i in 0..<Int(argc) {
        
        guard let argC = argv?[i] else {
            return nil
        }
        
        let arg = String(cString: argC)
        
        args.append(arg)
        
    }
    return args
} */

func printUsage(command: String) {
    fputs("Usage: \(command) file.js\nExecutes JavaScript files using JavaScriptCore.\n", thread_stdout)
}

let timerJSSharedInstance = TimerJS()

@objc protocol TimerJSExport : JSExport {

    func setTimeout(_ callback : JSValue,_ ms : Double) -> String

    func clearTimeout(_ identifier: String)

    func setInterval(_ callback : JSValue,_ ms : Double) -> String

}

// Custom class must inherit from `NSObject`
@objc class TimerJS: NSObject, TimerJSExport {
    var timers = [String: Timer]()
    
    static func registerInto(jsContext: JSContext, forKeyedSubscript: String = "timerJS") {
        jsContext.setObject(timerJSSharedInstance,
                            forKeyedSubscript: forKeyedSubscript as (NSCopying & NSObjectProtocol))
        jsContext.evaluateScript(
            "function setTimeout(callback, ms) {" +
            "    return timerJS.setTimeout(callback, ms)" +
            "}" +
            "function clearTimeout(indentifier) {" +
            "    timerJS.clearTimeout(indentifier)" +
            "}" +
            "function setInterval(callback, ms) {" +
            "    return timerJS.setInterval(callback, ms)" +
            "}"
        )
    }
    
    func clearTimeout(_ identifier: String) {
        let timer = timers.removeValue(forKey: identifier)
        
        timer?.invalidate()
    }
    
    
    func setInterval(_ callback: JSValue,_ ms: Double) -> String {
        return createTimer(callback: callback, ms: ms, repeats: true)
    }
    
    func setTimeout(_ callback: JSValue, _ ms: Double) -> String {
        return createTimer(callback: callback, ms: ms , repeats: false)
    }
    
    @objc func callJsCallback(timer: Timer) {
        let callback = (timer.userInfo as! JSValue)
        callback.call(withArguments: nil)
    }
    
    func createTimer(callback: JSValue, ms: Double, repeats : Bool) -> String {
        let timeInterval  = ms/1000.0
        
        let uuid = NSUUID().uuidString
        
        // make sure that we are queueing it all in the same executable queue...
        // JS calls are getting lost if the queue is not specified... that's what we believe... ;)
        DispatchQueue.main.async(execute: {
            let timer = Timer.scheduledTimer(timeInterval: timeInterval,
                                             target: self,
                                             selector: #selector(self.callJsCallback),
                                             userInfo: callback,
                                             repeats: repeats)
            self.timers[uuid] = timer
        })
        
        
        return uuid
    }
}

// TODO:
// add searching for modules in ~/Library and ~/Documents
// npm to install new modules (not parcel, though)

// execute JavaScript:
@_cdecl("jsc")
public func jsc(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    guard let args = convertCArguments(argc: argc, argv: argv) else {
        printUsage(command: "jsc")
        return 0
    }
    if (argc != 2) {
        printUsage(command: args[0])
        return 0
    }
    let command = args[1]
    
    // let fileName = FileManager().currentDirectoryPath + "/" + command
    let fileName = command.hasPrefix("/") ? command : FileManager().currentDirectoryPath + "/" + command
    do {
        let javascript = try String(contentsOf: URL(fileURLWithPath: fileName), encoding: String.Encoding.utf8)
        let context = JSContext()!
        TimerJS.registerInto(jsContext: context) // for setTimeOut
        
        context.exceptionHandler = { context, exception in
            let line = exception!.objectForKeyedSubscript("line").toString()
            let column = exception!.objectForKeyedSubscript("column").toString()
            let stacktrace = exception!.objectForKeyedSubscript("stack").toString()
            let unknown = "<unknown>"
            fputs("jsc: Error ", thread_stderr)
            if let currentFilename = context?.evaluateScript("if (typeof __filename !== 'undefined') { __filename }") {
                if (!currentFilename.isUndefined) {
                    let file = currentFilename.toString()
                    fputs("in file " + (file ?? unknown) + " ", thread_stderr)
                }
            }
            fputs("at line " + (line ?? unknown), thread_stderr)
            fputs(", column: " + (column ?? unknown) + ": ", thread_stderr)
            fputs(exception!.toString() + "\n", thread_stderr)
            if (stacktrace != nil) {
                fputs("jsc: Full stack: " + stacktrace! + "\n", thread_stderr)
            }
        }
        // create basic variables
        context.evaluateScript(
            "const global = (() => this)();\n" +
            "global.jsc = { };\n" +
            "global.document = { baseURI: \"/\" };\n" +
            "self = this;\n")
        
        let gateway = context.objectForKeyedSubscript("jsc" as NSString)
        // Key functions: print, println, console.log:
        let print: @convention(block) (String) -> Void = { string in
            fputs(string, thread_stdout)
        }
        context.setObject(print, forKeyedSubscript: "print" as NSString)
        let println: @convention(block) (String) -> Void = { string in
            fputs(string + "\n", thread_stdout)
        }
        context.setObject(println, forKeyedSubscript: "println" as NSString)
        // console.log
        context.evaluateScript("var console = { log: function(message) { _consoleLog(message) } }")
        let consoleLog: @convention(block) (String) -> Void = { message in
            fputs("console.log: " + message + "\n", thread_stderr)
        }
        context.setObject(consoleLog, forKeyedSubscript: "_consoleLog" as NSString)
        // Add URL type using url-polyfill:
        if let urlUrl = Bundle.main.url(forResource: "url-polyfill", withExtension: "js") {
            if let urlData = try? Data(contentsOf: urlUrl) {
                let urlContent = String(decoding: urlData, as: UTF8.self)
                context.evaluateScript(urlContent) // Now we have URL type
                context.evaluateScript("var location = new URL(\"" + Bundle.main.bundlePath + "/wasm.html\");")
            }
        }
        // JSC extensions: readFile, writeFile...
        let readFile: @convention(block) (String) -> String = { string in
            do {
                return try String(contentsOf: URL(fileURLWithPath: string), encoding: String.Encoding.utf8)
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return ""
        }
        gateway?.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
        let readFileBase64: @convention(block) (String) -> String = { string in
            do {
                return try NSData(contentsOf: URL(fileURLWithPath: fileName)).base64EncodedString()
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return ""
        }
        gateway?.setObject(readFileBase64, forKeyedSubscript: "readFileBase64" as NSString)
        
        let writeFile: @convention(block) (String, String) -> Int = { filePath, content in
            do {
                try content.write(toFile: filePath, atomically: true, encoding: String.Encoding.utf8)
                return 0
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return -1
        }
        gateway?.setObject(writeFile, forKeyedSubscript: "writeFile" as NSString)
        let writeFileBase64: @convention(block) (String, String) -> Int = { filePath, content in
            do {
                if let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) {
                    try data.write(to: URL(fileURLWithPath: filePath))
                    return 0
                }
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return -1
        }
        gateway?.setObject(writeFileBase64, forKeyedSubscript: "writeFileBase64" as NSString)

        let listFiles: @convention(block) (String) -> [String] = { directory in
            do {
                return try FileManager().contentsOfDirectory(atPath: directory)
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return []
        }
        gateway?.setObject(listFiles, forKeyedSubscript: "listFiles" as NSString)

        let isFile: @convention(block) (String) -> Bool = { filePath in
            var isDirectory: ObjCBool = false
            let isFile = FileManager().fileExists(atPath: filePath, isDirectory: &isDirectory)
            return isFile && !isDirectory.boolValue
        }
        gateway?.setObject(isFile, forKeyedSubscript: "isFile" as NSString)
        
        let isDirectory: @convention(block) (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            let isFile = FileManager().fileExists(atPath: path, isDirectory: &isDirectory)
            return isFile && isDirectory.boolValue
        }
        gateway?.setObject(isDirectory, forKeyedSubscript: "isDirectory" as NSString)

        let createDirectory: @convention(block) (String) -> Int = { path in
            do {
                try FileManager().createDirectory(atPath: path, withIntermediateDirectories: true)
                return 0
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                return -1
            }
        }
        gateway?.setObject(createDirectory, forKeyedSubscript: "makeFolder" as NSString)
        let delete: @convention(block) (String) -> Int = { path in
            do {
                try FileManager().removeItem(atPath: path)
                return 0
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                return -1
            }
        }
        gateway?.setObject(delete, forKeyedSubscript: "delete" as NSString)
        let move: @convention(block) (String, String) -> Int = { pathA, pathB in
            do {
                try FileManager().moveItem(atPath: pathA, toPath: pathB)
                return 0
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return -1
        }
        gateway?.setObject(move, forKeyedSubscript: "move" as NSString)
        let copy: @convention(block) (String, String) -> Int = { pathA, pathB in
            do {
                try FileManager().copyItem(atPath: pathA, toPath: pathB)
                return 0
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return -1
        }
        gateway?.setObject(copy, forKeyedSubscript: "copy" as NSString)

        let fileSize: @convention(block) (String) -> UInt64 = { path in
            do {
                //return [FileAttributeKey : Any]
                let attr = try FileManager.default.attributesOfItem(atPath: path)
                return attr[FileAttributeKey.size] as? UInt64 ?? 0
            } catch {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                return 0
            }
        }
        gateway?.setObject(fileSize, forKeyedSubscript: "fileSize" as NSString)
        
        let system: @convention(block) (String) -> Int32 = { command in
            let pid = ios_fork()
            var result = ios_system(command)
            ios_waitpid(pid)
            ios_releaseThreadId(pid)
            if (result == 0) {
                // If there's already been an error (e.g. "command not found") no need to ask for more.
                result = ios_getCommandStatus()
            }
            return result
        }
        gateway?.setObject(system, forKeyedSubscript: "system" as NSString)

        // Load require:
        if let requireUrl = Bundle.main.url(forResource: "require_jscore", withExtension: "js") {
            if let data = try? Data(contentsOf: requireUrl) {
                let content = String(decoding: data, as: UTF8.self)
                context.evaluateScript(content) // Now we should have require()
            }
        }
        
        // Extra things for WebAssembly:
        // We also need performance.now (returns float in milliseconds):
        let performance_now: @convention(block) () -> Double = {
            return Date().timeIntervalSince1970 * 1000.0
        }
        context.setObject(performance_now, forKeyedSubscript: "_performance_now" as NSString)
        context.evaluateScript("performance = {now: _performance_now };\n")
        
        // actual script execution:
        if let result = context.evaluateScript(javascript) {
            if (!result.isUndefined) {
                let string = result.toString()
                fputs(string, thread_stdout)
                fputs("\n", thread_stdout)
                fflush(thread_stdout)
                fflush(thread_stderr)
            }
        }
    }
    catch {
        fputs("Error executing JavaScript  file: " + command + ": \(error.localizedDescription) \n", thread_stderr)
        fflush(thread_stderr)
    }
    return 0
}



// As of April 14, 2023, JavaScriptCore does not support WebAssembly (new WebAssembly -> Can't find variable: WebAssembly).
// execute webAssembly:
@_cdecl("wasm")
public func wasm(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    guard let args = convertCArguments(argc: argc, argv: argv) else {
        fputs("Error: could not convert arguments\n", thread_stdout)
        fputs("Usage: wasm file.wasm\nExecutes webAssembly files using JavaScriptCore and WASI.", thread_stdout)
        return 0
    }
    
    let context = JSContext()!
    TimerJS.registerInto(jsContext: context) // for setTimeOut
    
    context.exceptionHandler = { context, exception in
        let line = exception!.objectForKeyedSubscript("line").toString()
        let column = exception!.objectForKeyedSubscript("column").toString()
        let stacktrace = exception!.objectForKeyedSubscript("stack").toString()
        let unknown = "<unknown>"
        fputs("jsc: Error ", thread_stderr)
        if let currentFilename = context?.evaluateScript("if (typeof __filename !== 'undefined') { __filename }") {
            if (!currentFilename.isUndefined) {
                let file = currentFilename.toString()
                fputs("in file " + (file ?? unknown) + " ", thread_stderr)
            }
        }
        fputs("at line " + (line ?? unknown), thread_stderr)
        fputs(", column: " + (column ?? unknown) + ": ", thread_stderr)
        fputs(exception!.toString() + "\n", thread_stderr)
        if (stacktrace != nil) {
            fputs("jsc: Full stack: " + stacktrace! + "\n", thread_stderr)
        }
    }
    // create basic variables
    context.evaluateScript(
        "const global = (() => this)();\n" +
        "global.jsc = { };\n" +
        "global.document = { baseURI: \"/\" };\n" +
        "self = this;\n")
    
    let gateway = context.objectForKeyedSubscript("jsc" as NSString)
    // Key functions: print, println, console.log:
    let print: @convention(block) (String) -> Void = { string in
        fputs(string, thread_stdout)
    }
    context.setObject(print, forKeyedSubscript: "print" as NSString)
    let println: @convention(block) (String) -> Void = { string in
        fputs(string + "\n", thread_stdout)
    }
    context.setObject(println, forKeyedSubscript: "println" as NSString)
    // console.log
    context.evaluateScript("var console = { log: function(message) { _consoleLog(message) } }")
    let consoleLog: @convention(block) (String) -> Void = { message in
        fputs("console.log: " + message + "\n", thread_stderr)
    }
    context.setObject(consoleLog, forKeyedSubscript: "_consoleLog" as NSString)
    // Add URL type using url-polyfill
    guard let urlUrl = Bundle.main.url(forResource: "url-polyfill", withExtension: "js") else {
        return -1
    }
    guard let urlData = try? Data(contentsOf: urlUrl) else {
        NSLog("could not read file url-polyfill.js")
        return -1
    }
    let urlContent = String(decoding: urlData, as: UTF8.self)
    context.evaluateScript(urlContent) // Now we have URL type
    
    context.evaluateScript("var location = new URL(\"" + Bundle.main.bundlePath + "/wasm.html\");")
    
    let readFile: @convention(block) (String) -> String = { string in
        do {
            let contentOfFile = try String(contentsOf: URL(fileURLWithPath: string), encoding: String.Encoding.utf8)
            return contentOfFile
        }
        catch {
            context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
        }
        return ""
    }
    gateway?.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
    
    // Load require:
    guard let requireUrl = Bundle.main.url(forResource: "require_jscore", withExtension: "js") else {
        return -1
    }
    guard let data = try? Data(contentsOf: requireUrl) else {
        NSLog("could not read file require_jscore.js")
        return -1
    }
    let content = String(decoding: data, as: UTF8.self)
    context.evaluateScript(content) // Now we should have require()
    
    // Extra things for WebAssembly:
    // We also need performance.now (returns float in milliseconds):
    let performance_now: @convention(block) () -> Double = {
        return Date().timeIntervalSince1970 * 1000.0
    }
    context.setObject(performance_now, forKeyedSubscript: "_performance_now" as NSString)
    context.evaluateScript("performance = {now: _performance_now };\n")
    
    // a-Shell WASI-libc communicates with the system using prompt("libc\n..."). Replacement here:
    let prompt: @convention(block) (String) -> String = { string in
        let arguments = string.components(separatedBy: "\n")
        let title = arguments[0]
        fputs(string, thread_stdout)
        fputs("\n", thread_stdout)
        fflush(thread_stdout)
        fflush(thread_stderr)
        return ""
    }
    context.setObject(prompt, forKeyedSubscript: "prompt" as NSString)
    
    guard let wasmUrl = Bundle.main.url(forResource: "wasm", withExtension: "js") else {
        return -1
    }
    guard let wasmData = try? Data(contentsOf: wasmUrl) else {
        NSLog("could not read file wasm.js")
        return -1
    }
    let wasmContent = String(decoding: wasmData, as: UTF8.self)
    context.evaluateScript(wasmContent) // Now we should have executeWebAssembly()
    
    // Parse the arguments:
    // let fileName = FileManager().currentDirectoryPath + "/" + command
    let command = args[1]
    var argumentString = "["
    for c in 1...args.count-1 {
        // replace quotes and backslashes in arguments:
        let sanitizedArgument = args[c] .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        argumentString = argumentString + " \"" +  sanitizedArgument + "\","
    }
    argumentString = argumentString + "]"
    // async functions don't work in WKWebView (so, no fetch, no WebAssembly.instantiateStreaming)
    // Instead, we load the file in swift and send the base64 version to JS
    let currentDirectory = FileManager().currentDirectoryPath
    let fileName = command.hasPrefix("/") ? command : currentDirectory + "/" + command
    guard let buffer = NSData(contentsOf: URL(fileURLWithPath: fileName)) else {
        fputs("wasm: file \(command) not found\n", thread_stderr)
        return -1
    }
    var environmentAsJSDictionary = "{"
    if let localEnvironment = environmentAsArray() {
        for variable in localEnvironment {
            if let envVar = variable as? String {
                // Let's not carry environment variables with quotes:
                if (envVar.contains("\"")) {
                    continue
                }
                let components = envVar.components(separatedBy:"=")
                if (components.count <= 1) {
                    continue
                }
                let name = components[0]
                var value = envVar
                if (value.count > name.count + 1) {
                    value.removeFirst(name.count + 1)
                } else {
                    continue
                }
                value = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
                // NSLog("envVar: \(envVar) name: \(name) value: \(value)")
                environmentAsJSDictionary += "\"" + name + "\"" + ":" + "\"" + value + "\",\n"
            }
        }
    }
    environmentAsJSDictionary += "}"
    let base64string = buffer.base64EncodedString()
    let javascript = "executeWebAssembly(\"\(base64string)\", " + argumentString + ", \"" + currentDirectory + "\", \(ios_isatty(STDIN_FILENO)), " + environmentAsJSDictionary + ")"
    
    // actual wasm execution:
    if let result = context.evaluateScript(javascript) {
        if (!result.isUndefined) {
            // Do I need these?
            let string = result.toString()
            fputs(string, thread_stdout)
            fputs("\n", thread_stdout)
            fflush(thread_stdout)
            fflush(thread_stderr)
        }
    }
    return 0
}

