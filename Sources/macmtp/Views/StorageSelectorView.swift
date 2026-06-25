import SwiftUI

struct StorageSelectorView: View {
    let storages: [MTPStorageInfo]
    let selectedStorageId: UInt32?
    let onSelect: (UInt32) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(storages) { storage in
                let isSelected = selectedStorageId == storage.storageId
                
                Button(action: {
                    onSelect(storage.storageId)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: storage.storageType.iconName)
                            .font(.system(size: 16))
                            .foregroundColor(isSelected ? .white : .accentColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(storage.description)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? .white : .primary)
                            
                            Text("\(storage.formattedFree) free of \(storage.formattedTotal)")
                                .font(.system(size: 10))
                                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Divider(),
            alignment: .bottom
        )
    }
}
