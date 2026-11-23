import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Reading the device's photo library database (Photos.sqlite).

// MARK: - Photos.sqlite catalog

struct Catalog {
    var smart: [AlbumCategory] = []
    var user: [AlbumCategory] = []
    /// People named in the Photos app, from its own face recognition, most photographed first.
    var people: [AlbumCategory] = []
    var warnings: [String] = []
    var assetCount = 0
    var schemaLabel = ""
}

enum CatalogError: Error {
    case unreadable
    case unsupported(String)
}

enum CatalogReader {
    static func load(path: String) -> Result<Catalog, CatalogError> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return .failure(.unreadable)
        }
        defer { sqlite3_close(db) }

        let assetTable: String
        if tableExists(db, "ZASSET") { assetTable = "ZASSET" }
        else if tableExists(db, "ZGENERICASSET") { assetTable = "ZGENERICASSET" }
        else { return .failure(.unsupported("The photo database has no asset table this app recognises (ZASSET).")) }

        let cols = columns(db, assetTable)
        let missing = ["Z_PK", "ZDIRECTORY", "ZFILENAME"].filter { !cols.contains($0) }
        guard missing.isEmpty else {
            return .failure(.unsupported("The asset table is missing \(missing.joined(separator: ", ")), which this app needs to locate files."))
        }
        let hasAttr = tableExists(db, "ZADDITIONALASSETATTRIBUTES")
        let attrCols = hasAttr ? columns(db, "ZADDITIONALASSETATTRIBUTES") : []
        let joinAttr = hasAttr && attrCols.contains("ZASSET")

        var warnings: [String] = []
        func col(_ name: String, _ fallback: String, warn: String? = nil) -> String {
            if cols.contains(name) { return "COALESCE(a.\(name), \(fallback))" }
            if let warn { warnings.append(warn) }
            return fallback
        }
        let origExpr = (joinAttr && attrCols.contains("ZORIGINALFILENAME")) ? "COALESCE(attr.ZORIGINALFILENAME, a.ZFILENAME)" : "a.ZFILENAME"
        let sizeExpr: String
        if joinAttr && attrCols.contains("ZORIGINALFILESIZE") {
            sizeExpr = "COALESCE(attr.ZORIGINALFILESIZE, 0)"
        } else {
            sizeExpr = "0"
            warnings.append("File sizes are not available in this iOS version's photo database, so size sorting and size verification are limited.")
        }
        let hiddenExpr = col("ZHIDDEN", "0", warn: "This iOS version does not mark hidden items the way this app expects, so the Hidden album cannot be identified.")
        let trashedExpr = col("ZTRASHEDSTATE", "0")
        let screenshotExpr = cols.contains("ZISDETECTEDSCREENSHOT") ? "COALESCE(a.ZISDETECTEDSCREENSHOT, 0)"
            : (cols.contains("Z1_ISDETECTEDSCREENSHOT") ? "COALESCE(a.Z1_ISDETECTEDSCREENSHOT, 0)" : "0")
        let orderExpr = cols.contains("ZDATECREATED") ? "a.ZDATECREATED DESC" : "a.Z_PK DESC"

        let sql = """
        SELECT a.Z_PK, \(col("ZUUID", "''")), a.ZDIRECTORY, a.ZFILENAME, \(origExpr), \(sizeExpr),
               \(hiddenExpr), \(col("ZFAVORITE", "0")), \(trashedExpr), \(col("ZKIND", "0")),
               \(col("ZDATECREATED", "0")), \(col("ZWIDTH", "0")), \(col("ZHEIGHT", "0")),
               \(col("ZDURATION", "0.0")), \(screenshotExpr), \(col("ZCAMERACAPTUREDEVICE", "0")),
               \(col("ZKINDSUBTYPE", "0")), \(col("ZHASADJUSTMENTS", "0")),
               \(cols.contains("ZCLOUDLOCALSTATE") && cols.contains("ZCLOUDASSETGUID")
                  ? "CASE WHEN COALESCE(a.ZCLOUDASSETGUID, '') != '' AND COALESCE(a.ZCLOUDLOCALSTATE, 1) = 0 THEN 1 ELSE 0 END" : "0")
        FROM \(assetTable) a
        \(joinAttr ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES attr ON attr.ZASSET = a.Z_PK" : "")
        WHERE a.ZFILENAME IS NOT NULL AND a.ZDIRECTORY IS NOT NULL AND a.ZFILENAME != ''
        ORDER BY \(orderExpr);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            return .failure(.unsupported("The photo database could not be queried (\(msg))."))
        }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }

        var ordered: [PhotoAsset] = []
        var byPK: [Int64: PhotoAsset] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let dir = text(2), fn = text(3), orig = text(4)
            let ts = sqlite3_column_double(stmt, 10)
            let date: Date? = ts != 0 ? Date(timeIntervalSinceReferenceDate: ts) : nil
            let dateText = date.map { Fmt.date.string(from: $0) } ?? "—"
            let subtype = sqlite3_column_int(stmt, 16)
            let kind = sqlite3_column_int(stmt, 9)
            var asset = PhotoAsset(
                id: pk, uuid: text(1), directory: dir, filename: fn, originalFilename: orig,
                fileSize: sqlite3_column_int64(stmt, 5),
                width: Int(sqlite3_column_int(stmt, 11)), height: Int(sqlite3_column_int(stmt, 12)),
                duration: sqlite3_column_double(stmt, 13),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                isFavorite: sqlite3_column_int(stmt, 7) != 0,
                isTrashed: sqlite3_column_int(stmt, 8) != 0,
                isVideo: kind == 1,
                isScreenshot: sqlite3_column_int(stmt, 14) != 0 || subtype == 10,
                isSelfie: sqlite3_column_int(stmt, 15) == 1,
                isLivePhoto: kind == 0 && subtype == 2,
                dateCreated: date, dateText: dateText,
                searchKey: "\(fn) \(orig) \(dir) \(dateText)".lowercased()
            )
            asset.isEdited = sqlite3_column_int(stmt, 17) != 0
            asset.isCloudOnly = sqlite3_column_int(stmt, 18) != 0
            ordered.append(asset)
            byPK[pk] = asset
        }
        sqlite3_finalize(stmt)

        var user: [AlbumCategory] = []
        if tableExists(db, "ZGENERICALBUM") {
            let albumCols = columns(db, "ZGENERICALBUM")
            if albumCols.contains("ZTITLE") {
                let trashClause = albumCols.contains("ZTRASHEDSTATE") ? "AND COALESCE(alb.ZTRASHEDSTATE, 0) = 0" : ""
                for jt in joinTables(db) {
                    let jc = columns(db, jt)
                    guard let albumCol = jc.sorted().first(where: { $0.hasSuffix("ALBUMS") }),
                          let assetCol = jc.sorted().first(where: { $0.hasSuffix("ASSETS") && !$0.hasPrefix("Z_FOK") }) else { continue }
                    let q = """
                    SELECT alb.Z_PK, alb.ZTITLE, j.\(assetCol) FROM ZGENERICALBUM alb
                    INNER JOIN \(jt) j ON alb.Z_PK = j.\(albumCol)
                    WHERE alb.ZTITLE IS NOT NULL AND alb.ZTITLE != '' \(trashClause);
                    """
                    var s: OpaquePointer?
                    guard sqlite3_prepare_v2(db, q, -1, &s, nil) == SQLITE_OK else { continue }
                    var map: [Int64: (String, [PhotoAsset])] = [:]
                    while sqlite3_step(s) == SQLITE_ROW {
                        let apk = sqlite3_column_int64(s, 0)
                        guard let t = sqlite3_column_text(s, 1), let asset = byPK[sqlite3_column_int64(s, 2)],
                              !asset.isTrashed, !asset.isHidden else { continue }
                        map[apk, default: (String(cString: t), [])].1.append(asset)
                    }
                    sqlite3_finalize(s)
                    for (apk, v) in map where !v.1.isEmpty {
                        user.append(AlbumCategory(id: "album_\(apk)", title: v.0, icon: "rectangle.stack.fill", isSmart: false,
                                                  assets: v.1.sorted { $0.sortDate > $1.sortDate }))
                    }
                }
            }
        }
        user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        // People the person has named in Photos. Older and newer iOS name the face columns differently.
        var people: [AlbumCategory] = []
        if tableExists(db, "ZPERSON"), tableExists(db, "ZDETECTEDFACE") {
            let pc = columns(db, "ZPERSON"), fc = columns(db, "ZDETECTEDFACE")
            let names = ["ZDISPLAYNAME", "ZFULLNAME"].filter { pc.contains($0) }.map { "NULLIF(TRIM(p.\($0)), '')" }
            if let assetCol = ["ZASSETFORFACE", "ZASSET"].first(where: { fc.contains($0) }),
               let personCol = ["ZPERSONFORFACE", "ZPERSON"].first(where: { fc.contains($0) }), !names.isEmpty {
                let name = names.count == 1 ? names[0] : "COALESCE(\(names.joined(separator: ", ")))"
                var s: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT \(name), f.\(assetCol) FROM ZDETECTEDFACE f JOIN ZPERSON p ON p.Z_PK = f.\(personCol) WHERE \(name) IS NOT NULL;", -1, &s, nil) == SQLITE_OK {
                    var map: [String: (title: String, ids: Set<Int64>, list: [PhotoAsset])] = [:]
                    while sqlite3_step(s) == SQLITE_ROW {
                        guard let t = sqlite3_column_text(s, 0), let asset = byPK[sqlite3_column_int64(s, 1)], !asset.isTrashed, !asset.isHidden else { continue }
                        let title = String(cString: t)
                        let key = title.lowercased()
                        var entry = map[key] ?? (title, [], [])
                        if entry.title == entry.title.lowercased(), title != title.lowercased() { entry.title = title }   // prefer "Mum" to "mum"
                        if entry.ids.insert(asset.id).inserted { entry.list.append(asset) }
                        map[key] = entry
                    }
                    sqlite3_finalize(s)
                    // The same person can appear under two records (not yet merged in Photos); one name, one group.
                    for (key, v) in map {
                        people.append(AlbumCategory(id: "person:" + key, title: v.title, icon: "person.crop.circle.fill", isSmart: false,
                                                    assets: v.list.sorted { $0.sortDate > $1.sortDate }))
                    }
                }
            }
        }
        people.sort { $0.assets.count != $1.assets.count ? $0.assets.count > $1.assets.count : $0.title < $1.title }

        let live = ordered.filter { !$0.isTrashed }
        func smart(_ id: String, _ title: String, _ icon: String, _ items: [PhotoAsset]) -> AlbumCategory {
            AlbumCategory(id: id, title: title, icon: icon, isSmart: true, assets: items)
        }
        // Like the Photos app: a hidden item appears only in Hidden, never in other albums.
        let shown = live.filter { !$0.isHidden }
        var cat = Catalog()
        cat.smart = [
            smart("smart_hidden", "Hidden", "eye.slash.fill", live.filter { $0.isHidden }),
            smart("smart_all", "Library", "photo.on.rectangle.angled", shown),
            smart("smart_favorites", "Favorites", "heart.fill", shown.filter { $0.isFavorite }),
            smart("smart_videos", "Videos", "video.fill", shown.filter { $0.isVideo }),
            smart("smart_live", "Live Photos", "livephoto", shown.filter { $0.isLivePhoto }),
            smart("smart_screenshots", "Screenshots", "camera.viewfinder", shown.filter { $0.isScreenshot }),
            smart("smart_selfies", "Selfies", "person.crop.square.fill", shown.filter { $0.isSelfie }),
            smart("smart_trashed", "Recently Deleted", "trash.fill", ordered.filter { $0.isTrashed })
        ]
        cat.user = user
        cat.people = people
        cat.warnings = warnings
        cat.assetCount = ordered.count
        cat.schemaLabel = assetTable
        return .success(cat)
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var result = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { result.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    private static func joinTables(_ db: OpaquePointer) -> [String] {
        var list: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z\\_%ASSETS' ESCAPE '\\';", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: c)
                    if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { list.append(name) }
                }
            }
        }
        sqlite3_finalize(stmt)
        return list
    }
}
