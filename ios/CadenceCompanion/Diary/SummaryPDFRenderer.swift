import CoreGraphics
import CoreText
import Foundation

/// Draws a `SummaryReport` as a US Letter PDF with CoreText, so the same code
/// runs on the phone and in the Mac test suite. Large, high-contrast type;
/// text flows onto as many pages as it needs.
public struct SummaryPDFRenderer {
    private let pageSize = CGSize(width: 612, height: 792)
    private let margin: CGFloat = 54

    public init() {}

    public func render(_ report: SummaryReport) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(
                consumer: consumer,
                mediaBox: &mediaBox,
                [kCGPDFContextTitle as String: report.title, kCGPDFContextCreator as String: "Cadence"] as CFDictionary
              ) else {
            return Data()
        }

        let text = document(for: report)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        // The footer (disclaimer and page number) sits below the text on every page.
        let footerHeight: CGFloat = 64
        let textRect = CGRect(
            x: margin, y: margin + footerHeight,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2 - footerHeight
        )
        var start = 0
        var page = 1
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, context)
            drawFooter(page: page, in: context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            start += visible.length
            page += 1
        } while start < text.length
        context.closePDF()
        return data as Data
    }

    /// Writes the PDF where the Share sheet can pick it up.
    public func writeTemporaryFile(_ report: SummaryReport) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CadenceSummaries", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Cadence summary \(report.fileDateStamp).pdf")
        try render(report).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Layout

    private func document(for report: SummaryReport) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ style: Style) {
            out.append(NSAttributedString(string: string + "\n", attributes: style.attributes))
        }

        add(report.title, .title)
        add(report.rangeText, .subtitle)
        add("", .gap)

        if report.isEmpty {
            add(SummaryReport.nothingLogged, .body)
        } else {
            add("What happened", .heading)
            for count in report.counts {
                add("\(count.label): \(count.value)", .body)
            }
            add("", .gap)

            add(report.range == .lastDay ? "Through the day" : "Day by day", .heading)
            for day in report.days {
                if report.range == .lastDay {
                    if day.entries.isEmpty { add("Nothing logged", .body) }
                    for entry in day.entries {
                        let detail = entry.detail.isEmpty ? "" : " — \(entry.detail)"
                        add("\(entry.time)   \(entry.word)\(detail)", .body)
                    }
                } else {
                    add("\(day.heading): \(day.countsLine)", .body)
                }
            }

            if !report.motorChecks.isEmpty {
                add("", .gap)
                add("Motor checks", .heading)
                for check in report.motorChecks {
                    add(check.heading, .bodyBold)
                    for line in check.lines { add(line, .body) }
                }
            }

            if !report.meals.isEmpty {
                add("", .gap)
                add("Meals noted", .heading)
                for meal in report.meals { add("\(meal.time)   \(meal.text)", .body) }
            }
        }

        return out
    }

    private func drawFooter(page: Int, in context: CGContext) {
        let note = NSAttributedString(
            string: SummaryReport.disclaimer + "\nPage \(page)",
            attributes: Style.note.attributes
        )
        let framesetter = CTFramesetterCreateWithAttributedString(note as CFAttributedString)
        let rect = CGRect(x: margin, y: margin / 2, width: pageSize.width - margin * 2, height: 64)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private enum Style {
        case title, subtitle, heading, body, bodyBold, note, gap

        var attributes: [NSAttributedString.Key: Any] {
            let (size, weight, gray): (CGFloat, CTFontUIFontType, CGFloat) = {
                switch self {
                case .title: return (24, .emphasizedSystem, 0.05)
                case .subtitle: return (14, .system, 0.30)
                case .heading: return (16, .emphasizedSystem, 0.05)
                case .body: return (13, .system, 0.10)
                case .bodyBold: return (13, .emphasizedSystem, 0.10)
                case .note: return (11, .system, 0.35)
                case .gap: return (8, .system, 0.0)
                }
            }()
            let font = CTFontCreateUIFontForLanguage(weight, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            var spacing: CGFloat = self == .heading ? 4 : 2
            // CTParagraphStyleCreate copies the setting, so the pointer only
            // needs to live for the call.
            let paragraph: CTParagraphStyle = withUnsafeMutablePointer(to: &spacing) { pointer in
                var setting = CTParagraphStyleSetting(
                    spec: .paragraphSpacing,
                    valueSize: MemoryLayout<CGFloat>.size,
                    value: pointer
                )
                return CTParagraphStyleCreate(&setting, 1)
            }
            return [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ]
        }
    }
}
