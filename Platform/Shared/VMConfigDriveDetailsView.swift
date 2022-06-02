//
// Copyright © 2020 osy. All rights reserved.
// Copyright © 2020 Stewart Smith
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

import SwiftUI

@available(iOS 14, macOS 11, *)
struct VMConfigDriveDetailsView: View {
    private let mibToGib = 1024
    @EnvironmentObject private var data: UTMData
    @ObservedObject private var config: UTMQemuConfiguration
    @Binding private var removable: Bool
    @Binding private var name: String?
    @Binding private var imageTypeString: String?
    @Binding private var interface: String?
    @State private var virtualSize : Int = 0
    @State private var origVirtualSize : Int = 0
    @State private var isGiB: Bool = true
    let onDelete: (() -> Void)?
    
    let helpMessage: LocalizedStringKey = "Reclaim disk space by re-converting the disk image."
    let confirmMessage: LocalizedStringKey = "Would you like to re-convert this disk image to reclaim unused space? Note this will require enough temporary space to perform the conversion. You are strongly encouraged to back-up this VM before proceeding."
    @State private var isConfirmConvertShown: Bool = false
    
    let resizeHelpMessage: LocalizedStringKey = "Resize disk image"
    let resizeConfirmMessage: LocalizedStringKey = "Would you like to resize the image? If shrinking you WILL LOSE DATA if you have not used OS tools to resize the disks appropriately."
    @State private var isConfirmResizeShown: Bool = false
    
    var imageType: UTMDiskImageType {
        get {
            UTMDiskImageType.enumFromString(imageTypeString)
        }
        
        set {
            imageTypeString = newValue.description
        }
    }
    
    init(config: UTMQemuConfiguration, index: Int, onDelete: (() -> Void)?) {
        self.onDelete = onDelete
        self.config = config // for observing updates
        self._removable = Binding<Bool> {
            return config.driveRemovable(for: index)
        } set: {
            config.setDriveRemovable($0, for: index)
        }
        self._name = Binding<String?> {
            return config.driveImagePath(for: index)
        } set: {
            if let name = $0 {
                config.setImagePath(name, for: index)
            }
        }
        self._imageTypeString = Binding<String?> {
            return config.driveImageType(for: index).description
        } set: {
            config.setDrive(UTMDiskImageType.enumFromString($0), for: index)
        }
        self._interface = Binding<String?> {
            return config.driveInterfaceType(for: index)
        } set: {
            if let interface = $0 {
                config.setDriveInterfaceType(interface, for: index)
            }
        }
    }
    
    var body: some View {
        Form {
            Toggle(isOn: $removable.animation(), label: {
                Text("Removable Drive")
            }).disabled(true)
            if !removable {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(name ?? "")
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
            }
            VMConfigStringPicker("Image Type", selection: $imageTypeString, rawValues: UTMQemuConfiguration.supportedImageTypes(), displayValues: UTMQemuConfiguration.supportedImageTypesPretty())
            if imageType == .disk || imageType == .CD {
                VMConfigStringPicker("Interface", selection: $interface, rawValues: UTMQemuConfiguration.supportedDriveInterfaces(), displayValues: UTMQemuConfiguration.supportedDriveInterfacesPretty())
            }
            if let name = name, let imageUrl = config.imagesPath.appendingPathComponent(name), let fileSize = data.computeSize(for: imageUrl) {
                VStack {
                    HStack {
                        NumberTextField("Size", number: Binding<NSNumber?>(get: {
                            NSNumber(value: convertToDisplay(fromSizeMib: virtualSize))
                        }, set: {
                            virtualSize = convertToMib(fromSize: $0?.intValue ?? 0)
                        }), onEditingChanged: validateSize).onAppear {
                            Task {
                                origVirtualSize = Int(await data.driveSize(for: imageUrl)/(1024*1024))
                                virtualSize = origVirtualSize
                            }
                        }
                        Button(action: { isGiB.toggle() }, label: {
                            Text(isGiB ? "GB" : "MB")
                                .foregroundColor(.blue)
                        }).buttonStyle(.plain)
                        if #available(macOS 12, *) {
                            Button(action: { isConfirmResizeShown.toggle() }) {
                                Label("Resize", systemImage: "arrow.3.trianglepath")
                            }.help(resizeHelpMessage)
                                .alert(resizeConfirmMessage, isPresented: $isConfirmResizeShown) {
                                    Button("Cancel", role: .cancel) {}
                                    Button("Resize", role: .destructive) { resizeDrive(for: imageUrl, sizeInMib: virtualSize) }
                                }
                        } else {
                            Button(action: { isConfirmResizeShown.toggle() }) {
                                Label("Resize", systemImage: "arrow.3.trianglepath")
                            }.help(resizeHelpMessage)
                                .alert(isPresented: $isConfirmResizeShown) {
                                    Alert(title: Text(resizeConfirmMessage), primaryButton: .cancel(), secondaryButton: .destructive(Text("Resize")) { resizeDrive(for: imageUrl, sizeInMib: virtualSize) })
                                }
                        }
                    }
                    DefaultTextField("Size on disk", text: .constant(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))).disabled(true)
                }
            }

            HStack {
                if let onDelete = onDelete {
                    Button(action: onDelete) {
                        Label("Delete Drive", systemImage: "externaldrive.badge.minus")
                            .foregroundColor(.red)
                    }.help("Delete this drive.")
                }
                
                #if os(macOS)
                if let name = name, let imageUrl = config.imagesPath.appendingPathComponent(name), FileManager.default.fileExists(atPath: imageUrl.path) {
                    if #available(macOS 12, *) {
                        Button(action: { isConfirmConvertShown.toggle() }) {
                            Label("Reclaim Space", systemImage: "arrow.3.trianglepath")
                        }.help(helpMessage)
                        .alert(confirmMessage, isPresented: $isConfirmConvertShown) {
                            Button("Cancel", role: .cancel) {}
                            Button("Reclaim", role: .destructive) { reclaimSpace(for: imageUrl, withCompression: false) }
                            Button("Reclaim and Compress", role: .destructive) { reclaimSpace(for: imageUrl, withCompression: true) }
                        }
                    } else {
                        Button(action: { isConfirmConvertShown.toggle() }) {
                            Label("Reclaim Space", systemImage: "arrow.3.trianglepath")
                        }.help(helpMessage)
                        .alert(isPresented: $isConfirmConvertShown) {
                            Alert(title: Text(confirmMessage), primaryButton: .cancel(), secondaryButton: .destructive(Text("Reclaim")) { reclaimSpace(for: imageUrl, withCompression: false) })
                        }
                    }
                }
                #endif
            }
        }
    }

    private func driveSize(for driveUrl: URL, sizeInMib: Int) {
        data.busyWorkAsync {
            try await data.driveSize(for: driveUrl)
        }
    }
    
    private func resizeDrive(for driveUrl: URL, sizeInMib: Int) {
        data.busyWorkAsync {
            try await data.resizeDrive(for: driveUrl, sizeInMib: sizeInMib)
        }
    }
    
    #if os(macOS)
    private func reclaimSpace(for driveUrl: URL, withCompression isCompressed: Bool) {
        data.busyWorkAsync {
            try await data.reclaimSpace(for: driveUrl, withCompression: isCompressed)
        }
    }
    #endif
    
    private func validateSize(editing: Bool) {
        guard !editing else {
            return
        }
        if virtualSize < origVirtualSize {
            virtualSize = origVirtualSize
        }
    }
    
    private func convertToMib(fromSize size: Int) -> Int {
        if isGiB {
            return size * mibToGib
        } else {
            return size
        }
    }
    
    private func convertToDisplay(fromSizeMib sizeMib: Int) -> Int {
        if isGiB {
            return sizeMib / mibToGib
        } else {
            return sizeMib
        }
    }
}
