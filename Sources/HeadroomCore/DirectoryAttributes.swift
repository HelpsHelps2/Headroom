import Darwin

/// Reads regular-file metadata in batches for inventory scans. Directories and
/// other entry types still use the descriptor-relative stat and traversal path.
enum DirectoryAttributes {
    struct Entry {
        var name: String
        var file: RegularFile? = nil
    }

    struct RegularFile {
        var device: dev_t
        var modified: timespec
        var bytes: Int64
    }

    private static let nameAttributes = ATTR_CMN_RETURNED_ATTRS | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME)
    private static let common = nameAttributes | UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME)
    private static let file = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

    /// Nil means the filesystem could not provide a complete listing.
    static func read(_ directory: Int32) -> [Entry]? {
        var attributes = attrlist(bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0,
                                  commonattr: common, volattr: 0, dirattr: 0, fileattr: file, forkattr: 0)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 32 * 1024, alignment: 8)
        defer { buffer.deallocate() }
        var entries: [Entry] = []
        while true {
            let count = getattrlistbulk(directory, &attributes, buffer.baseAddress!, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count == 0 { return entries }
            guard count > 0 else { return nil }
            var offset = 0
            for _ in 0..<count {
                guard offset <= buffer.count - MemoryLayout<UInt32>.size else { return nil }
                let size = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard size > 0, size <= buffer.count - offset,
                      let entry = parse(UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + size)]))
                else { return nil }
                if entry.name != "." && entry.name != ".." { entries.append(entry) }
                offset += size
            }
        }
    }

    private static func parse(_ record: UnsafeRawBufferPointer) -> Entry? {
        // Darwin packs fields on four-byte boundaries. Returned attributes and
        // the error precede the fields in ascending attribute-bit order.
        let returnedOffset = MemoryLayout<UInt32>.size
        let errorOffset = returnedOffset + MemoryLayout<attribute_set_t>.size
        let nameOffset = errorOffset + MemoryLayout<UInt32>.size
        let deviceOffset = nameOffset + MemoryLayout<attrreference_t>.size
        let typeOffset = deviceOffset + MemoryLayout<dev_t>.size
        let modifiedOffset = typeOffset + MemoryLayout<fsobj_type_t>.size
        let linksOffset = modifiedOffset + MemoryLayout<timespec>.size
        let bytesOffset = linksOffset + MemoryLayout<UInt32>.size
        let fileFieldsEnd = bytesOffset + MemoryLayout<off_t>.size

        guard record.count >= deviceOffset else { return nil }
        let returned = record.loadUnaligned(fromByteOffset: returnedOffset, as: attribute_set_t.self)
        guard returned.commonattr & nameAttributes == nameAttributes else { return nil }
        let reference = record.loadUnaligned(fromByteOffset: nameOffset, as: attrreference_t.self)
        let start = nameOffset + Int(reference.attr_dataoffset), length = Int(reference.attr_length)
        guard start >= deviceOffset, start < record.count, length > 1, length <= record.count - start,
              record[start + length - 1] == 0,
              let name = String(validatingCString: record.baseAddress!.advanced(by: start).assumingMemoryBound(to: CChar.self))
        else { return nil }

        let error = record.loadUnaligned(fromByteOffset: errorOffset, as: UInt32.self)
        guard error == 0, returned.commonattr & common == common, returned.fileattr & file == file,
              start >= fileFieldsEnd, record.loadUnaligned(fromByteOffset: typeOffset, as: fsobj_type_t.self) == VREG.rawValue
        else { return Entry(name: name) }

        let bytes = record.loadUnaligned(fromByteOffset: bytesOffset, as: off_t.self)
        guard bytes >= 0, bytes % 512 == 0 else { return Entry(name: name) }
        let links = record.loadUnaligned(fromByteOffset: linksOffset, as: UInt32.self)
        let device = record.loadUnaligned(fromByteOffset: deviceOffset, as: dev_t.self)
        let modified = record.loadUnaligned(fromByteOffset: modifiedOffset, as: timespec.self)
        return Entry(name: name, file: RegularFile(device: device, modified: modified, bytes: links <= 1 ? bytes : 0))
    }
}
