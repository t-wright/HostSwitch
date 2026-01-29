import SwiftUI
import Foundation
import AppKit

struct HostEntry: Identifiable {
    let id = UUID()
    var ipAddress: String
    var hostname: String
    var isEnabled: Bool
    var comment: String
    
    var displayText: String {
        if isEnabled {
            return "\(ipAddress)\t\(hostname)\(comment.isEmpty ? "" : " # \(comment)")"
        } else {
            return "# \(ipAddress)\t\(hostname)\(comment.isEmpty ? "" : " # \(comment)")"
        }
    }
}

class HostSwitchManager: ObservableObject {
    @Published var hostEntries: [HostEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    
    private let hostsFilePath = "/etc/hosts"
    private let sectionStart = "####### HostSwitchStart"
    private let sectionEnd = "####### HostSwitchEnd"
    private var cachedHostsContent: String = ""
    
    init() {
        loadHostsFile()
    }
    
    func loadHostsFile() {
        isLoading = true
        errorMessage = nil
        
        do {
            let content = try String(contentsOfFile: hostsFilePath)
            cachedHostsContent = content
            parseHostsContent(content)
        } catch {
            errorMessage = "Failed to read hosts file: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    private func parseHostsContent(_ content: String) {
        hostEntries.removeAll()
        
        let lines = content.components(separatedBy: .newlines)
        var inManagedSection = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            if trimmedLine.contains(sectionStart) {
                inManagedSection = true
                continue
            }
            
            if trimmedLine.contains(sectionEnd) {
                inManagedSection = false
                continue
            }
            
            if !inManagedSection {
                continue
            }
            
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("##") {
                continue
            }
            
            var isEnabled = true
            var workingLine = trimmedLine
            
            if trimmedLine.hasPrefix("#") {
                isEnabled = false
                workingLine = String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            
            let components = workingLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            
            if components.count >= 2 {
                let ipAddress = components[0]
                let hostname = components[1]
                
                var comment = ""
                if let commentIndex = workingLine.firstIndex(of: "#") {
                    let commentStart = workingLine.index(commentIndex, offsetBy: 1)
                    comment = String(workingLine[commentStart...]).trimmingCharacters(in: .whitespaces)
                }
                
                if isValidIPAddress(ipAddress) || isValidHostname(hostname) {
                    let entry = HostEntry(
                        ipAddress: ipAddress,
                        hostname: hostname,
                        isEnabled: isEnabled,
                        comment: comment
                    )
                    hostEntries.append(entry)
                }
            }
        }
    }
    
    private func isValidIPAddress(_ ip: String) -> Bool {
        let ipv4Pattern = "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
        let ipv6Pattern = "^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$|^::1$|^::$"
        
        return ip.range(of: ipv4Pattern, options: .regularExpression) != nil ||
               ip.range(of: ipv6Pattern, options: .regularExpression) != nil
    }
    
    private func isValidHostname(_ hostname: String) -> Bool {
        return !hostname.isEmpty && hostname != "#"
    }
    
    func toggleHostEntry(_ entry: HostEntry) {
        if let index = hostEntries.firstIndex(where: { $0.id == entry.id }) {
            hostEntries[index].isEnabled.toggle()
            saveHostsFileWithAdmin()
        }
    }
    
    func saveHostsFileWithAdmin() {
        errorMessage = nil
        statusMessage = "Updating hosts file..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let originalContent = try String(contentsOfFile: self.hostsFilePath)
                let newContent = self.updateManagedSection(in: originalContent)
                
                // Use authopen - integrates with Authorization Services and shows Touch ID
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
                process.arguments = ["-c", "-w", self.hostsFilePath]
                
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                
                try process.run()
                inputPipe.fileHandleForWriting.write(newContent.data(using: .utf8)!)
                try inputPipe.fileHandleForWriting.close()
                process.waitUntilExit()
                
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        self.cachedHostsContent = newContent
                        self.statusMessage = "Hosts file updated successfully!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.statusMessage = nil
                        }
                        self.loadHostsFile()
                    } else {
                        self.statusMessage = nil
                        self.errorMessage = "Authorization failed or was cancelled."
                        self.loadHostsFile()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = nil
                    self.errorMessage = "Failed to prepare hosts file: \(error.localizedDescription)"
                }
            }
        }
    }
    
    
    
    private func updateManagedSection(in content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var result: [String] = []
        var inManagedSection = false
        var foundManagedSection = false
        
        // SAFETY: Only modify content within our managed section markers
        // This ensures we NEVER touch system or other manual entries
        
        for line in lines {
            if line.contains(sectionStart) {
                foundManagedSection = true
                inManagedSection = true
                result.append(line)
                
                // Add our managed entries
                for entry in hostEntries {
                    result.append(entry.displayText)
                }
                continue
            }
            
            if line.contains(sectionEnd) {
                inManagedSection = false
                result.append(line)
                continue
            }
            
            // CRITICAL: Preserve ALL lines outside our managed section
            if !inManagedSection {
                result.append(line)
            }
            // Lines inside managed section are replaced with our entries (added above)
        }
        
        // If no managed section exists, create it at the end
        if !foundManagedSection {
            result.append("")
            result.append("# Managed by HostSwitch - Do not edit manually")
            result.append(sectionStart)
            for entry in hostEntries {
                result.append(entry.displayText)
            }
            result.append(sectionEnd)
        }
        
        return result.joined(separator: "\n")
    }
    
    
    func addHostEntry(ip: String, hostname: String, comment: String = "") {
        let newEntry = HostEntry(
            ipAddress: ip,
            hostname: hostname,
            isEnabled: true,
            comment: comment
        )
        hostEntries.append(newEntry)
        saveHostsFileWithAdmin()
    }
    
    private func isSystemEntry(_ entry: HostEntry) -> Bool {
        let systemHosts = ["localhost", "broadcasthost"]
        return systemHosts.contains(entry.hostname) || 
               (entry.ipAddress == "127.0.0.1" && entry.hostname == "localhost") ||
               (entry.ipAddress == "::1" && entry.hostname == "localhost") ||
               (entry.ipAddress == "255.255.255.255" && entry.hostname == "broadcasthost")
    }
}

class MenuBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem!
    private var hostSwitchManager = HostSwitchManager()
    private var popover: NSPopover!
    
    override init() {
        super.init()
        setupMenuBar()
        setupPopover()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "HostSwitch")
            button.action = #selector(showMenu)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: MenuBarView(hostSwitchManager: hostSwitchManager))
        popover.behavior = .transient
    }
    
    @objc private func showMenu() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.becomeKey()
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var hostSwitchManager: HostSwitchManager
    @State private var showingAddForm = false
    @State private var newIP = ""
    @State private var newHostname = ""
    @State private var newComment = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HostSwitch")
                    .font(.headline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: { hostSwitchManager.loadHostsFile() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.top)
            
            if hostSwitchManager.hostEntries.isEmpty {
                VStack {
                    Text("No managed hosts found")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text("Add entries to your /etc/hosts file within the managed section")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(hostSwitchManager.hostEntries) { entry in
                            MenuBarHostRow(entry: entry, hostSwitchManager: hostSwitchManager)
                                .padding(.horizontal)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            
            Divider()
            
            if showingAddForm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add New Host Entry")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    TextField("IP Address", text: $newIP)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    TextField("Hostname", text: $newHostname)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    TextField("Comment (optional)", text: $newComment)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    HStack {
                        Button("Cancel") {
                            showingAddForm = false
                            clearForm()
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        
                        Spacer()
                        
                        Button("Add") {
                            hostSwitchManager.addHostEntry(ip: newIP, hostname: newHostname, comment: newComment)
                            showingAddForm = false
                            clearForm()
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .disabled(newIP.isEmpty || newHostname.isEmpty)
                    }
                }
                .padding()
            } else {
                HStack {
                    Button("Add Host") {
                        showingAddForm = true
                    }
                    .buttonStyle(DefaultButtonStyle())
                    
                    Spacer()
                    
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding()
            }
            
            if let statusMessage = hostSwitchManager.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            
            if let errorMessage = hostSwitchManager.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .frame(width: 350)
    }
    
    private func clearForm() {
        newIP = ""
        newHostname = ""
        newComment = ""
    }
}

struct MenuBarHostRow: View {
    let entry: HostEntry
    let hostSwitchManager: HostSwitchManager
    
    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                hostSwitchManager.toggleHostEntry(entry)
            }) {
                Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(entry.isEnabled ? .green : .red)
                    .font(.system(size: 16))
            }
            .buttonStyle(PlainButtonStyle())
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.hostname)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(entry.isEnabled ? .primary : .secondary)
                    
                    Spacer()
                    
                    Text(entry.ipAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(entry.isEnabled ? .blue : .gray)
                }
                
                if !entry.comment.isEmpty {
                    Text(entry.comment)
                        .font(.caption2)
                        .foregroundColor(entry.isEnabled ? .gray : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.isEnabled ? 1.0 : 0.4)
        .background(entry.isEnabled ? Color.clear : Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}

