//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if canImport(AltKit) && !WITH_QEMU_TCI
import AltKit
#endif

@available(iOS 14, macOS 11, *)
struct AlertMessage: Identifiable {
    var message: String
    public var id: String {
        message
    }
    
    init(_ message: String) {
        self.message = message
    }
}

@available(iOS 14, macOS 11, *)
class UTMData: ObservableObject {
    
    /// Sandbox location for storing .utm bundles
    static var defaultStorageUrl: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// View: show VM settings
    @MainActor @Published var showSettingsModal: Bool
    
    /// View: show new VM wizard
    @MainActor @Published var showNewVMSheet: Bool
    
    /// View: show an alert message
    @MainActor @Published var alertMessage: AlertMessage?
    
    /// View: show busy spinner
    @MainActor @Published var busy: Bool
    
    /// View: currently selected VM
    @MainActor @Published var selectedVM: UTMVirtualMachine?
    
    /// View: all VMs listed, we save a bookmark to each when array is modified
    @MainActor @Published private(set) var virtualMachines: [UTMVirtualMachine] {
        didSet {
            listSaveToDefaults()
        }
    }
    
    /// View: all pending VMs listed (ZIP and IPSW downloads)
    @MainActor @Published private(set) var pendingVMs: [UTMPendingVirtualMachine]
    
    /// Temporary storage for QEMU removable drives settings
    private var qemuRemovableDrivesCache: [String: URL]
    
    /// Temporary storage for QEMU imported and created drives that haven't been saved yet
    private var qemuUnsavedImages: [URL]
    
    #if os(macOS)
    /// View controller for every VM currently active
    var vmWindows: [UTMVirtualMachine: VMDisplayWindowController] = [:]
    #else
    /// View controller for currently active VM
    var vmVC: VMDisplayViewController?
    #endif
    
    /// Shortcut for accessing FileManager.default
    private var fileManager: FileManager {
        FileManager.default
    }
    
    /// Shortcut for accessing storage URL from instance
    private var documentsURL: URL {
        UTMData.defaultStorageUrl
    }
    
    /// Queue to run `busyWork` tasks
    private var busyQueue: DispatchQueue
    
    @MainActor
    init() {
        self.busyQueue = DispatchQueue(label: "UTM Busy Queue", qos: .userInitiated)
        self.showSettingsModal = false
        self.showNewVMSheet = false
        self.busy = false
        self.virtualMachines = []
        self.qemuRemovableDrivesCache = [:]
        self.qemuUnsavedImages = []
        self.pendingVMs = []
        self.selectedVM = nil
        listLoadFromDefaults()
    }
    
    // MARK: - VM listing
    
    /// Re-loads UTM bundles from default path
    ///
    /// This removes stale entries (deleted/not accessible) and duplicate entries
    func listRefresh() async {
        // wrap stale VMs
        var list = await virtualMachines
        for i in list.indices.reversed() {
            let vm = list[i]
            if !fileManager.fileExists(atPath: vm.path!.path) {
                if let wrappedVM = UTMWrappedVirtualMachine(placeholderFor: vm) {
                    list[i] = wrappedVM
                } else {
                    // we cannot even make a placeholder, then remove the element
                    list.remove(at: i)
                }
            }
        }
        // now look for and add new VMs in default storage
        do {
            let files = try fileManager.contentsOfDirectory(at: UTMData.defaultStorageUrl, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            let newFiles = files.filter { newFile in
                !list.contains { existingVM in
                    existingVM.path?.standardizedFileURL == newFile.standardizedFileURL
                }
            }
            for file in newFiles {
                guard try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false else {
                    continue
                }
                guard UTMVirtualMachine.isVirtualMachine(url: file) else {
                    continue
                }
                let vm = UTMVirtualMachine(url: file)
                if vm != nil {
                    list.insert(vm!, at: 0)
                } else {
                    logger.error("Failed to create object for \(file)")
                }
            }
        } catch {
            logger.error("\(error.localizedDescription)")
        }
        // replace the VM list with our new one
        if await virtualMachines != list {
            await listReplace(with: list)
        }
    }
    
    /// Load VM list (and order) from persistent storage
    @MainActor private func listLoadFromDefaults() {
        let defaults = UserDefaults.standard
        // legacy path list
        if let files = defaults.array(forKey: "VMList") as? [String] {
            virtualMachines = files.uniqued().compactMap({ file in
                let url = documentsURL.appendingPathComponent(file, isDirectory: true)
                return UTMVirtualMachine(url: url)
            })
        }
        // bookmark list
        if let list = defaults.array(forKey: "VMList") {
            virtualMachines = list.compactMap { item in
                var wrappedVM: UTMWrappedVirtualMachine?
                if let bookmark = item as? Data {
                    wrappedVM = UTMWrappedVirtualMachine(bookmark: bookmark)
                } else if let dict = item as? [String: Any] {
                    wrappedVM = UTMWrappedVirtualMachine(from: dict)
                }
                if let vm = wrappedVM?.unwrap() {
                    #if os(macOS)
                    // FIXME: we do not support Apple VM shortcuts because we cannot access the drives
                    if let appleVM = vm as? UTMAppleVirtualMachine, appleVM.isShortcut {
                        return nil
                    } else {
                        return vm
                    }
                    #else
                    return vm
                    #endif
                } else {
                    return wrappedVM
                }
            }
        }
    }
    
    /// Save VM list (and order) to persistent storage
    @MainActor private func listSaveToDefaults() {
        let defaults = UserDefaults.standard
        let wrappedVMs = virtualMachines.compactMap { vm -> [String: Any]? in
            UTMWrappedVirtualMachine(placeholderFor: vm)?.serialized
        }
        defaults.set(wrappedVMs, forKey: "VMList")
    }
    
    @MainActor private func listReplace(with vms: [UTMVirtualMachine]) {
        virtualMachines = vms
    }
    
    /// Add VM to list
    /// - Parameter vm: VM to add
    /// - Parameter at: Optional index to add to, otherwise will be added to the end
    @MainActor private func listAdd(vm: UTMVirtualMachine, at index: Int? = nil) {
        if let index = index {
            virtualMachines.insert(vm, at: index)
        } else {
            virtualMachines.append(vm)
        }
    }
    
    /// Select VM in list
    /// - Parameter vm: VM to select
    @MainActor public func listSelect(vm: UTMVirtualMachine) {
        selectedVM = vm
    }
    
    /// Remove a VM from list
    /// - Parameter vm: VM to remove
    /// - Returns: Index of item removed or nil if already removed
    @MainActor @discardableResult public func listRemove(vm: UTMVirtualMachine) -> Int? {
        let index = virtualMachines.firstIndex(of: vm)
        if let index = index {
            virtualMachines.remove(at: index)
        }
        if vm == selectedVM {
            selectedVM = nil
        }
        vm.isDeleted = true // alert views to update
        return index
    }
    
    /// Add pending VM to list
    /// - Parameter pendingVM: Pending VM to add
    /// - Parameter at: Optional index to add to, otherwise will be added to the end
    @MainActor private func listAdd(pendingVM: UTMPendingVirtualMachine, at index: Int? = nil) {
        if let index = index {
            pendingVMs.insert(pendingVM, at: index)
        } else {
            pendingVMs.append(pendingVM)
        }
    }
    
    /// Remove pending VM from list
    /// - Parameter pendingVM: Pending VM to remove
    /// - Returns: Index of item removed or nil if already removed
    @MainActor @discardableResult private func listRemove(pendingVM: UTMPendingVirtualMachine) -> Int? {
        let index = pendingVMs.firstIndex(where: { $0.id == pendingVM.id })
        if let index = index {
            pendingVMs.remove(at: index)
        }
        return index
    }
    
    /// Move items in VM list
    /// - Parameters:
    ///   - fromOffsets: Offsets from move from
    ///   - toOffset: Offsets to move to
    @MainActor func listMove(fromOffsets: IndexSet, toOffset: Int) {
        virtualMachines.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }
    
    // MARK: - New name
    
    /// Generate a unique VM name
    /// - Parameter base: Base name
    /// - Returns: Unique name for a non-existing item in the default storage path
    func newDefaultVMName(base: String = "Virtual Machine") -> String {
        let nameForId = { (i: Int) in i <= 1 ? base : "\(base) \(i)" }
        for i in 1..<1000 {
            let name = nameForId(i)
            let file = UTMVirtualMachine.virtualMachinePath(name, inParentURL: documentsURL)
            if !fileManager.fileExists(atPath: file.path) {
                return name
            }
        }
        return ProcessInfo.processInfo.globallyUniqueString
    }
    
    /// Generate a unique drive name for QEMU
    /// - Parameters:
    ///   - type: Image type
    ///   - ext: Image extension
    ///   - forConfig: UTM QEMU configuration that will hold this drive
    /// - Returns: Unique name for a non-existing item in the .utm data path
    private func newDefaultDrivePath(type: UTMDiskImageType, extension ext: String, forConfig: UTMQemuConfiguration) -> String {
        let nameForId = { (i: Int) in "\(type.description)-\(i).\(ext)" }
        for i in 0..<1000 {
            let name = nameForId(i)
            let file = forConfig.imagesPath.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: file.path) {
                return name
            }
        }
        return UUID().uuidString
    }
    
    /// Generate a default drive name for QEMU
    /// - Parameter config: UTM QEMU configuration that will use the drive
    /// - Returns: Unique name for the new drive
    private func newDefaultDriveName(for config: UTMQemuConfiguration) -> String {
        let nameForId = { (i: Int) in "drive\(i)" }
        for i in 0..<1000 {
            let name = nameForId(i)
            var free: Bool = true
            for j in 0..<config.countDrives {
                guard let taken = config.driveName(for: j) else {
                    continue
                }
                if taken == name {
                    free = false
                    break
                }
            }
            if free {
                return name
            }
        }
        return UUID().uuidString
    }
    
    /// Generate a filename for an imported file, avoiding duplicate names
    /// - Parameters:
    ///   - imagesUrl: Destination directory to test for file existance
    ///   - filename: The filename of the existing image being imported
    ///   - withExtension: Optionally change the file extension
    /// - Returns: Unique filename that is not used in the imagesUrl
    func newImportedImage(at imagesUrl: URL, filename: String, withExtension: String? = nil) -> String {
        let baseUrl = imagesUrl.appendingPathComponent(filename)
        let name = baseUrl.deletingPathExtension().lastPathComponent
        let ext = withExtension ?? baseUrl.pathExtension
        let strFromInt = { (i: Int) in i == 1 ? "" : "-\(i)" }
        for i in 1..<1000 {
            let attempt = "\(name)\(strFromInt(i))"
            let attemptUrl = imagesUrl.appendingPathComponent(attempt).appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: attemptUrl.path) {
                return attemptUrl.lastPathComponent
            }
        }
        return UUID().uuidString
    }
    
    // MARK: - Other view states
    
    @MainActor private func setBusyIndicator(_ busy: Bool) {
        self.busy = busy
    }
    
    @MainActor private func showErrorAlert(message: String) {
        alertMessage = AlertMessage(message)
    }
    
    @MainActor func newVM() {
        showSettingsModal = false
        showNewVMSheet = true
    }
    
    @MainActor func showSettingsForCurrentVM() {
        #if os(iOS)
        // SwiftUI bug: cannot show modal at the same time as changing selected VM or it breaks
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.showSettingsModal = true
        }
        #else
        showSettingsModal = true
        #endif
    }
    
    // MARK: - VM operations
    
    /// Save an existing VM to disk
    /// - Parameter vm: VM to save
    func save(vm: UTMVirtualMachine) async throws {
        do {
            try await vm.saveUTM()
            if let qemuVM = vm as? UTMQemuVirtualMachine {
                try commitRemovableDriveImages(for: qemuVM)
                qemuUnsavedImages.removeAll()
            }
        } catch {
            // refresh the VM object as it is now stale
            do {
                try discardChanges(for: vm)
            } catch {
                // if we can't discard changes, recreate the VM from scratch
                guard let path = vm.path else {
                    logger.error("Attempting to refresh unsaved VM \(vm.detailsTitleLabel)")
                    return
                }
                guard let newVM = UTMVirtualMachine(url: path) else {
                    logger.debug("Cannot create new object for \(path.path)")
                    return
                }
                let index = await listRemove(vm: vm)
                await listAdd(vm: newVM, at: index)
                await listSelect(vm: newVM)
            }
            throw error
        }
    }
    
    /// Discard changes to VM configuration
    /// - Parameter vm: VM configuration to discard
    func discardChanges(for vm: UTMVirtualMachine? = nil) throws {
        let config: UTMQemuConfiguration
        if let vm = vm, vm.path != nil {
            try vm.reloadConfiguration()
            guard let qemuConfig = vm.config as? UTMQemuConfiguration else {
                // FIXME: non-qemu orphaned drives
                return
            }
            config = qemuConfig
        } else {
            // create a tmp empty config so we can get orphanedDrives for tmp path
            config = UTMQemuConfiguration()
        }
        // delete unsaved drives
        for url in qemuUnsavedImages {
            try? fileManager.removeItem(at: url)
        }
        qemuUnsavedImages.removeAll()
    }
    
    /// Save a new VM to disk
    /// - Parameters:
    ///   - config: New VM configuration
    func create(config: UTMConfigurable) async throws -> UTMVirtualMachine {
        guard await !virtualMachines.contains(where: { !$0.isShortcut && $0.config.name == config.name }) else {
            throw NSLocalizedString("An existing virtual machine already exists with this name.", comment: "UTMData")
        }
        let vm = UTMVirtualMachine(configuration: config, withDestinationURL: documentsURL)
        try await save(vm: vm)
        if let qemuVM = vm as? UTMQemuVirtualMachine {
            try commitRemovableDriveImages(for: qemuVM)
        }
        await listAdd(vm: vm)
        await listSelect(vm: vm)
        return vm
    }
    
    /// Delete a VM from disk
    /// - Parameter vm: VM to delete
    /// - Returns: Index of item removed in VM list or nil if not in list
    @discardableResult func delete(vm: UTMVirtualMachine) async throws -> Int? {
        if let _ = vm as? UTMWrappedVirtualMachine {
        } else {
            try fileManager.removeItem(at: vm.path!)
        }
        
        return await listRemove(vm: vm)
    }
    
    /// Save a copy of the VM and all data to default storage location
    /// - Parameter vm: VM to clone
    func clone(vm: UTMVirtualMachine) async throws {
        let newName: String = newDefaultVMName(base: vm.detailsTitleLabel)
        let newPath = UTMVirtualMachine.virtualMachinePath(newName, inParentURL: documentsURL)
        
        try fileManager.copyItem(at: vm.path!, to: newPath)
        guard let newVM = UTMVirtualMachine(url: newPath) else {
            throw NSLocalizedString("Failed to clone VM.", comment: "UTMData")
        }
        var index = await virtualMachines.firstIndex(of: vm)
        if index != nil {
            index! += 1
        }
        await listAdd(vm: newVM, at: index)
        await listSelect(vm: newVM)
    }
    
    /// Save a copy of the VM and all data to arbitary location
    /// - Parameters:
    ///   - vm: VM to copy
    ///   - url: Location to copy to (must be writable)
    func export(vm: UTMVirtualMachine, to url: URL) throws {
        let sourceUrl = vm.path!
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.copyItem(at: sourceUrl, to: url)
    }
    
    /// Save a copy of the VM and all data to arbitary location and delete the original data
    /// - Parameters:
    ///   - vm: VM to move
    ///   - url: Location to move to (must be writable)
    func move(vm: UTMVirtualMachine, to url: URL) async throws {
        try export(vm: vm, to: url)
        guard let newVM = UTMVirtualMachine(url: url) else {
            throw NSLocalizedString("Unable to add a shortcut to the new location.", comment: "UTMData")
        }
        newVM.isShortcut = true
        try await newVM.accessShortcut()
        
        let oldSelected = await selectedVM
        let index = try await delete(vm: vm)
        await listAdd(vm: newVM, at: index)
        if oldSelected == vm {
            await listSelect(vm: newVM)
        }
        #if os(macOS)
        if let _ = newVM as? UTMAppleVirtualMachine {
            throw NSLocalizedString("Shortcuts to Apple virtual machines cannot be stored. You must open the .utm bundle from Finder each time UTM is launched.", comment: "UTMData")
        }
        #endif
    }
    
    /// Open settings modal
    /// - Parameter vm: VM to edit settings
    @MainActor func edit(vm: UTMVirtualMachine) {
        // show orphans for proper removal
        if let config = vm.config as? UTMQemuConfiguration {
            config.recoverOrphanedDrives()
        }
        listSelect(vm: vm)
        showNewVMSheet = false
        showSettingsForCurrentVM()
    }
    
    /// Copy configuration but not data from existing VM to a new VM
    /// - Parameter vm: Existing VM to copy configuration from
    @MainActor func template(vm: UTMVirtualMachine) async throws {
        let copy = try await Task.detached { () -> UTMConfigurable in
            if let qemuConfig = vm.config as? UTMQemuConfiguration {
                let copy = qemuConfig.copy() as! UTMQemuConfiguration
                copy.systemUUID = UUID().uuidString // re-generate UUID
                for _ in 0..<copy.countDrives {
                    copy.removeDrive(at: 0) // remove existing drives
                }
                return copy
            }
            throw NSLocalizedString("This virtual machine does not support templating.", comment: "UTMData")
        }.value
        copy.name = newDefaultVMName(base: copy.name)
        if vm.config.iconCustom {
            // save copy of custom icon
            copy.selectedCustomIconPath = vm.config.iconUrl
        }
        _ = try await create(config: copy)
        showSettingsForCurrentVM()
    }
    
    // MARK: - File I/O related
    
    /// Calculate total size of VM and data
    /// - Parameter vm: VM to calculate size
    /// - Returns: Size in bytes
    func computeSize(for vm: UTMVirtualMachine) -> Int64 {
        guard let path = vm.path else {
            logger.error("invalid path for vm")
            return 0
        }
        guard let enumerator = fileManager.enumerator(at: path, includingPropertiesForKeys: [.totalFileSizeKey]) else {
            logger.error("failed to create enumerator for \(path)")
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey]), let size = resourceValues.totalFileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
    
    /// Calculate size of a single file URL
    /// - Parameter url: File URL
    /// - Returns: Size in bytes
    func computeSize(for url: URL) -> Int64 {
        if let resourceValues = try? url.resourceValues(forKeys: [.totalFileSizeKey]), let size = resourceValues.totalFileSize {
            return Int64(size)
        } else {
            return 0
        }
    }
    
    /// Handles UTM file URLs
    ///
    /// If .utm is already in the list, select it
    /// If .utm is in the Inbox directory, move it to the default storage
    /// Otherwise we create a shortcut (default for macOS) or a copy (default for iOS)
    /// - Parameter url: File URL to read from
    /// - Parameter asShortcut: Create a shortcut rather than a copy
    func importUTM(from url: URL, asShortcut: Bool = true) async throws {
        guard url.isFileURL else { return }
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        
        logger.info("importing: \(url)")
        let fileBasePath = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let dest = documentsURL.appendingPathComponent(fileName, isDirectory: true)
        if let vm = await virtualMachines.first(where: { vm -> Bool in
            guard let vmPath = vm.path else {
                return false
            }
            return vmPath.standardizedFileURL == url.standardizedFileURL
        }) {
            logger.info("found existing vm!")
            if let wrappedVM = vm as? UTMWrappedVirtualMachine {
                logger.info("existing vm is wrapped")
                if let unwrappedVM = wrappedVM.unwrap() {
                    let index = await listRemove(vm: wrappedVM)
                    await listAdd(vm: unwrappedVM, at: index)
                    await listSelect(vm: unwrappedVM)
                }
            } else {
                logger.info("existing vm is not wrapped")
                await listSelect(vm: vm)
            }
            return
        }
        // check if VM is valid
        guard let _ = UTMVirtualMachine(url: url) else {
            throw NSLocalizedString("Cannot import this VM. Either the configuration is invalid, created in a newer version of UTM, or on a platform that is incompatible with this version of UTM.", comment: "UTMData")
        }
        let vm: UTMVirtualMachine?
        if (fileBasePath.resolvingSymlinksInPath().path == documentsURL.appendingPathComponent("Inbox", isDirectory: true).path) {
            logger.info("moving from Inbox")
            try fileManager.moveItem(at: url, to: dest)
            vm = UTMVirtualMachine(url: dest)
        } else if asShortcut {
            logger.info("loading as a shortcut")
            vm = UTMVirtualMachine(url: url)
            vm?.isShortcut = true
            try await vm?.accessShortcut()
        } else {
            logger.info("copying to Documents")
            try fileManager.copyItem(at: url, to: dest)
            vm = UTMVirtualMachine(url: dest)
        }
        guard let vm = vm else {
            throw NSLocalizedString("Failed to parse imported VM.", comment: "UTMData")
        }
        await listAdd(vm: vm)
        await listSelect(vm: vm)
    }
    
    // MARK: - Downloading VMs
    
    #if os(macOS) && arch(arm64)
    /// Create a new VM using configuration and downloaded IPSW
    /// - Parameter config: Apple VM configuration
    @available(macOS 12, *)
    @MainActor func downloadIPSW(using config: UTMAppleConfiguration) {
        let task = UTMDownloadIPSWTask(for: config)
        guard !virtualMachines.contains(where: { !$0.isShortcut && $0.config.name == config.name }) else {
            showErrorAlert(message: NSLocalizedString("An existing virtual machine already exists with this name.", comment: "UTMData"))
            return
        }
        listAdd(pendingVM: task.pendingVM)
        Task {
            do {
                if let vm = try await task.download() {
                    try await self.save(vm: vm)
                    listAdd(vm: vm)
                }
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
            listRemove(pendingVM: task.pendingVM)
        }
    }
    #endif

    /// Create a new VM by downloading a .zip and extracting it
    /// - Parameter components: Download URL components
    @MainActor func downloadUTMZip(from components: URLComponents) {
        guard let urlParameter = components.queryItems?.first(where: { $0.name == "url" })?.value,
           let url = URL(string: urlParameter) else {
               showErrorAlert(message: NSLocalizedString("Failed to parse download URL.", comment: "UTMData"))
               return
        }
        let task = UTMDownloadVMTask(for: url)
        listAdd(pendingVM: task.pendingVM)
        Task {
            do {
                if let vm = try await task.download() {
                    listAdd(vm: vm)
                }
            } catch {
                showErrorAlert(message: error.localizedDescription)
            }
            listRemove(pendingVM: task.pendingVM)
        }
    }
    
    /// Cancel a download and discard any data
    /// - Parameter pendingVM: Pending VM to cancel
    func cancelDownload(for pendingVM: UTMPendingVirtualMachine) {
        pendingVM.cancel()
    }
    
    // MARK: - QEMU Disk drive I/O handling
    
    /// Import an existing drive image
    /// - Parameters:
    ///   - drive: File URL to drive
    ///   - config: QEMU configuration to add to
    ///   - imageType: Disk image type
    ///   - interface: Interface to add to
    ///   - raw: If false, convert to QCOW2
    ///   - copy: Make a copy of the file (if false, file will be moved)
    func importDrive(_ drive: URL, for config: UTMQemuConfiguration, imageType: UTMDiskImageType, on interface: String, raw: Bool, copy: Bool) async throws {
        _ = drive.startAccessingSecurityScopedResource()
        defer { drive.stopAccessingSecurityScopedResource() }
        
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: drive.path, isDirectory: &isDir), !isDir.boolValue else {
            if drive.pathExtension == "utm" {
                throw NSLocalizedString("You cannot import a .utm package as a drive. Did you mean to open the package with UTM?", comment: "UTMData")
            } else {
                throw NSLocalizedString("You cannot import a directory as a drive.", comment: "UTMData")
            }
        }
        
        let imagesPath = config.imagesPath
        var filename = newImportedImage(at: imagesPath, filename: drive.lastPathComponent)
        var dstPath = imagesPath.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: imagesPath.path) {
            try fileManager.createDirectory(at: imagesPath, withIntermediateDirectories: false, attributes: nil)
        }
        if copy {
            #if os(macOS)
            if !raw {
                filename = newImportedImage(at: imagesPath, filename: drive.lastPathComponent, withExtension: "qcow2")
                dstPath = imagesPath.appendingPathComponent(filename)
                try await UTMQemuImage.convert(from: drive, toQcow2: dstPath)
            } else {
                try fileManager.copyItem(at: drive, to: dstPath)
            }
            #else
            assert(raw) // currently do not support QCOW2 conversion
            try fileManager.copyItem(at: drive, to: dstPath)
            #endif
        } else {
            try fileManager.moveItem(at: drive, to: dstPath)
        }
        qemuUnsavedImages.append(dstPath)
        let newPath = filename
        await MainActor.run {
            let name = self.newDefaultDriveName(for: config)
            config.newDrive(name, path: newPath, type: imageType, interface: interface)
        }
    }
    
    func importDrive(_ drive: URL, for config: UTMQemuConfiguration, copy: Bool = true) async throws {
        let imageType: UTMDiskImageType = drive.pathExtension.lowercased() == "iso" ? .CD : .disk
        let interface: String
        if let target = config.systemTarget, let arch = config.systemArchitecture {
            interface = UTMQemuConfiguration.defaultDriveInterface(forTarget: target, architecture: arch, type: imageType)
        } else {
            interface = "none"
        }
        try await importDrive(drive, for: config, imageType: imageType, on: interface, raw: true, copy: copy)
    }
    
    /// Create a new QCOW2 disk image
    /// - Parameters:
    ///   - drive: Create parameters
    ///   - config: QEMU configuration to add to
    ///   - driveImage: Disk image type
    func createDrive(_ drive: VMDriveImage, for config: UTMQemuConfiguration, with driveImage: URL? = nil) async throws {
        var path: String = ""
        if !drive.removable {
            assert(driveImage == nil, "Cannot call createDrive with a driveImage!")
            guard drive.size > 0 else {
                throw NSLocalizedString("Invalid drive size.", comment: "UTMData")
            }
            path = newDefaultDrivePath(type: drive.imageType, extension: drive.isRawImage ? "raw" : "qcow2", forConfig: config)
            let imagesPath = config.imagesPath
            let dstPath = imagesPath.appendingPathComponent(path)
            if !fileManager.fileExists(atPath: imagesPath.path) {
                try fileManager.createDirectory(at: imagesPath, withIntermediateDirectories: false, attributes: nil)
            }
            
            // create drive
            try await Task.detached {
                if drive.isRawImage {
                    try self.generateNewRawDrive(at: dstPath, sizeInMib: drive.size)
                } else if !GenerateDefaultQcow2File(dstPath as CFURL, drive.size) {
                    throw NSLocalizedString("Disk creation failed.", comment: "UTMData")
                }
            }.value
            
            qemuUnsavedImages.append(dstPath)
        }
        
        let name = self.newDefaultDriveName(for: config)
        if let url = driveImage {
            qemuRemovableDrivesCache[name] = url
        }
        let newPath = path
        await MainActor.run {
            let interface = drive.interface ?? "none"
            if drive.removable {
                config.newRemovableDrive(name, type: drive.imageType, interface: interface)
            } else {
                config.newDrive(name, path: newPath, type: drive.imageType, interface: interface)
            }
        }
    }
    
    /// Delete a drive image data and settings from a QEMU configuration
    /// - Parameters:
    ///   - index: Index of drive in configuration
    ///   - config: QEMU configuration
    func removeDrive(at index: Int, for config: UTMQemuConfiguration) async throws {
        if let path = config.driveImagePath(for: index) {
            let fullPath = config.imagesPath.appendingPathComponent(path);
            qemuUnsavedImages.removeAll(where: { $0 == fullPath })
            if fileManager.fileExists(atPath: fullPath.path) {
                try fileManager.removeItem(at: fullPath)
            }
        }
        if let name = config.driveName(for: index) {
            qemuRemovableDrivesCache.removeValue(forKey: name)
        }
        await MainActor.run {
            config.removeDrive(at: index)
        }
    }
    
    /// Perform removable drive changes for cached items
    ///
    /// We do not store removable drive bookmarks in config.plist so we cache the removable drives until the VM is saved.
    /// - Parameter vm: QEMU VM that will take the cached images
    private func commitRemovableDriveImages(for vm: UTMQemuVirtualMachine) throws {
        let drives = vm.drives
        defer {
            qemuRemovableDrivesCache.removeAll()
        }
        try qemuRemovableDrivesCache.forEach { name, url in
            let drive = drives.first { drive in
                drive.name == name
            }
            if let drive = drive {
                try vm.changeMedium(for: drive, url: url)
            }
        }
    }
    
    /// Create a new raw disk image
    /// - Parameters:
    ///   - url: Destination of the drive image
    ///   - sizeInMib: Size of the drive image in MiB
    private func generateNewRawDrive(at url: URL, sizeInMib: Int) throws {
        let bytesInMib = 1048576
        guard fileManager.createFile(atPath: url.path, contents: nil, attributes: nil) else {
            throw NSLocalizedString("Cannot create disk iamge.", comment: "UTMData")
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeInMib * bytesInMib))
        try handle.close()
    }
    
    #if os(macOS)
    /// Reclaim empty space in a file by (re)-converting it to QCOW2
    ///
    /// This will overwrite driveUrl with the converted file on success!
    /// - Parameter driveUrl: Original drive to convert
    /// - Parameter isCompressed: Compress existing data
    func reclaimSpace(for driveUrl: URL, withCompression isCompressed: Bool = false) async throws {
        let baseUrl = driveUrl.deletingLastPathComponent()
        let filename = driveUrl.lastPathComponent
        let newName = newImportedImage(at: baseUrl, filename: filename, withExtension: "qcow2")
        let dstUrl = baseUrl.appendingPathComponent(newName)
        try await UTMQemuImage.convert(from: driveUrl, toQcow2: dstUrl, withCompression: isCompressed)
        do {
            try fileManager.replaceItem(at: driveUrl, withItemAt: dstUrl, backupItemName: nil, resultingItemURL: nil)
        } catch {
            // on failure delete the converted file
            try? fileManager.removeItem(at: dstUrl)
            throw error
        }
    }
    #endif
    
    func driveSize(for driveUrl: URL) async -> Int64 {
        let r = Task {
            return try? await UTMQemuImage.size(image: driveUrl)
        }
        do { return await r.value ?? 0 } catch { return 0 }
    }
    
    func resizeDrive(for driveUrl: URL, sizeInMib: Int) async throws {
        let bytesinMib = 1048576
        try await UTMQemuImage.resize(image: driveUrl, size: UInt64(sizeInMib * bytesinMib))
    }
    
    // MARK: - Other utility functions
    
    /// In some regions, iOS will prompt the user for network access
    func triggeriOSNetworkAccessPrompt() {
        let task = URLSession.shared.dataTask(with: URL(string: "http://captive.apple.com")!)
        task.resume()
    }
    
    /// Execute a task with spinning progress indicator
    /// - Parameter work: Function to execute
    func busyWork(_ work: @escaping () throws -> Void) {
        busyQueue.async {
            DispatchQueue.main.async {
                self.busy = true
            }
            defer {
                DispatchQueue.main.async {
                    self.busy = false
                }
            }
            do {
                try work()
            } catch {
                logger.error("\(error)")
                DispatchQueue.main.async {
                    self.alertMessage = AlertMessage(error.localizedDescription)
                }
            }
        }
    }
    
    /// Execute a task with spinning progress indicator (Swift concurrency version)
    /// - Parameter work: Function to execute
    func busyWorkAsync(_ work: @escaping @Sendable () async throws -> Void) {
        Task.detached(priority: .userInitiated) {
            await self.setBusyIndicator(true)
            do {
                try await work()
            } catch {
                logger.error("\(error)")
                await self.showErrorAlert(message: error.localizedDescription)
            }
            await self.setBusyIndicator(false)
        }
    }
    
    // MARK: - Automation Features
    
    /// Send text as keyboard input to VM
    /// - Parameters:
    ///   - vm: VM to send text to
    ///   - components: Data (see UTM Wiki for details)
    func automationSendText(to vm: UTMVirtualMachine, urlComponents components: URLComponents) {
        guard let qemuVm = vm as? UTMQemuVirtualMachine else { return } // FIXME: implement for Apple VM
        guard let queryItems = components.queryItems else { return }
        guard let text = queryItems.first(where: { $0.name == "text" })?.value else { return }
        #if os(macOS)
        trySendTextSpice(vm: qemuVm, text: text)
        #else
        trySendTextSpice(text)
        #endif
    }
    
    /// Send mouse/tablet coordinates to VM
    /// - Parameters:
    ///   - vm: VM to send mouse/tablet coordinates to
    ///   - components: Data (see UTM Wiki for details)
    func automationSendMouse(to vm: UTMVirtualMachine, urlComponents components: URLComponents) {
        guard let qemuVm = vm as? UTMQemuVirtualMachine else { return } // FIXME: implement for Apple VM
        guard !qemuVm.qemuConfig.displayConsoleOnly else { return }
        guard let queryItems = components.queryItems else { return }
        /// Parse targeted position
        var x: CGFloat? = nil
        var y: CGFloat? = nil
        let nf = NumberFormatter()
        nf.allowsFloats = false
        if let xStr = components.queryItems?.first(where: { item in
            item.name == "x"
        })?.value {
            x = nf.number(from: xStr) as? CGFloat
        }
        if let yStr = components.queryItems?.first(where: { item in
            item.name == "y"
        })?.value {
            y = nf.number(from: yStr) as? CGFloat
        }
        guard let xPos = x, let yPos = y else { return }
        let point = CGPoint(x: xPos, y: yPos)
        /// Parse which button should be clicked
        var button: CSInputButton = .left
        if let buttonStr = queryItems.first(where: { $0.name == "button"})?.value {
            switch buttonStr {
            case "middle":
                button = .middle
                break
            case "right":
                button = .right
                break
            default:
                break
            }
        }
        /// All parameters parsed, perform the click
        #if os(macOS)
        tryClickAtPoint(vm: qemuVm, point: point, button: button)
        #else
        tryClickAtPoint(point: point, button: button)
        #endif
    }

    // MARK: - AltKit
    
#if canImport(AltKit) && !WITH_QEMU_TCI
    /// Detect if we are installed from AltStore and can use AltJIT
    var isAltServerCompatible: Bool {
        guard let _ = Bundle.main.infoDictionary?["ALTServerID"] else {
            return false
        }
        guard let _ = Bundle.main.infoDictionary?["ALTDeviceID"] else {
            return false
        }
        return true
    }
    
    /// Find and run AltJIT to enable JIT
    func startAltJIT() throws {
        let event = DispatchSemaphore(value: 0)
        var connectError: Error?
        DispatchQueue.main.async {
            ServerManager.shared.autoconnect { result in
                switch result
                {
                case .failure(let error):
                    logger.error("Could not auto-connect to server. \(error.localizedDescription)")
                    connectError = error
                    event.signal()
                case .success(let connection):
                    connection.enableUnsignedCodeExecution { result in
                        switch result
                        {
                        case .failure(let error):
                            logger.error("Could not enable JIT compilation. \(error.localizedDescription)")
                            connectError = error
                        case .success:
                            logger.debug("Successfully enabled JIT compilation!")
                        }
                        
                        connection.disconnect()
                        event.signal()
                    }
                }
            }
            ServerManager.shared.startDiscovering()
        }
        defer {
            ServerManager.shared.stopDiscovering()
        }
        if event.wait(timeout: .now() + 10) == .timedOut {
            throw NSLocalizedString("Cannot find AltServer for JIT enable. You cannot run VMs until JIT is enabled.", comment: "UTMData")
        } else if let error = connectError {
            throw NSLocalizedString("AltJIT error: \(error.localizedDescription)", comment: "UTMData")
        }
    }
#endif
}
