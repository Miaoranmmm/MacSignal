import AppKit
import XCTest
@testable import MacSignal

final class ProcessMenuRowTests: XCTestCase {
    func testValuesRenderAllGlyphsAtBothDisplayScales() throws {
        for scale in [1, 2] {
            for text in ["0.7%", "3.9%", "19.3%", "100.0%", "18.05 GB", "1.72 GB", "913.4 MB", "1,019.9 MB"] {
                let row = ProcessMenuRow()
                row.update(name: "", value: text)
                let value = try XCTUnwrap(row.subviews.last as? NSTextField)
                let referenceView = NSView(frame: row.bounds)
                let reference = NSTextField(labelWithString: text)
                reference.font = value.font
                reference.textColor = value.textColor
                reference.alignment = .right
                reference.usesSingleLineMode = value.usesSingleLineMode
                let x = MenuStyle.titleX - 2
                reference.frame = NSRect(x: x, y: 3, width: row.bounds.width - x - 16, height: 18)
                referenceView.addSubview(reference)
                let actualPixels = try alphaPixels(row, scale: scale)
                let referencePixels = try alphaPixels(referenceView, scale: scale)
                XCTAssertGreaterThan(referencePixels.filter { $0 > 0 }.count, 20,
                                     "Reference must contain visible text")
                let differences = zip(actualPixels, referencePixels).filter { $0 != $1 }.count
                XCTAssertEqual(differences, 0, "Clipped or shifted glyphs: \(text) at \(scale)x")
            }
        }
    }

    private func alphaPixels(_ view: NSView, scale: Int) throws -> [UInt8] {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.appearance = NSAppearance(named: .darkAqua)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in bytes[y * bitmap.bytesPerRow + x * 4 + 3] }
        }
    }

    func testShortValuesGiveUnusedSpaceBackToProcessName() throws {
        let row = ProcessMenuRow()
        let name = try XCTUnwrap(row.subviews.first as? NSTextField)
        let value = try XCTUnwrap(row.subviews.last as? NSTextField)
        row.update(name: "BackgroundShortcutRunner", value: "1,019.9 MB")
        let memoryNameWidth = name.frame.width
        let valueRight = value.frame.maxX
        let rowWidth = row.frame.width
        XCTAssertGreaterThanOrEqual(value.frame.width, try XCTUnwrap(value.cell).cellSize.width)

        row.update(name: "BackgroundShortcutRunner", value: "1.2%")
        XCTAssertGreaterThan(name.frame.width, memoryNameWidth)
        XCTAssertEqual(row.frame.width, rowWidth)
        XCTAssertEqual(value.frame.maxX, valueRight)
        XCTAssertGreaterThanOrEqual(value.frame.width, try XCTUnwrap(value.cell).cellSize.width)
        XCTAssertGreaterThanOrEqual(value.frame.minX - name.frame.maxX, 4)
        XCTAssertLessThanOrEqual(value.frame.minX - name.frame.maxX, 8)
    }
}
