import Foundation

// Top-level entry point. Dispatch is intentionally thin: MCP.swift and CLI.swift
// own the behaviour.
exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
