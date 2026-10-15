import AppKit
import SwiftUI
import ZulipCoreBindings

/// A formula on its own line, laid out natively from the parsed TeX tree.
///
/// Fractions, roots, scripts, limits, matrices and stretchy delimiters are
/// placed by small `Layout`s that keep each part's text baseline, so a formula
/// lines up like typeset math. The formula centers when it fits and scrolls
/// sideways when it does not.
struct MathDisplayView: View {
    let tex: String
    let nodes: [MathNode]

    var body: some View {
        let size = 17 * InterfaceScale.shared.factor
        ViewThatFits(in: .horizontal) {
            MathRow(nodes: nodes, size: size)
                .frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                MathRow(nodes: nodes, size: size)
            }
        }
        .foregroundStyle(AppTheme.Colors.primaryText)
        .padding(.vertical, AppTheme.Spacing.small)
        .contextMenu {
            Button("Copy LaTeX") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tex, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Formula, \(tex)")
    }
}

// MARK: - Recursion

private func mathRow(_ nodes: [MathNode], _ size: CGFloat) -> AnyView {
    AnyView(MathRow(nodes: nodes, size: size))
}

private func scriptSize(_ size: CGFloat) -> CGFloat {
    max(size * 0.7, 8)
}

private struct MathRow: View {
    let nodes: [MathNode]
    let size: CGFloat

    var body: some View {
        MathRowLayout {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                MathNodeView(node: node, size: size)
            }
        }
    }
}

private struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat

    private func serif(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
    }

    @ViewBuilder
    var body: some View {
        switch node {
        case let .ident(value):
            Text(value).font(serif(size)).italic()

        case let .number(value):
            Text(value).font(serif(size))

        case let .text(value):
            Text(value).font(serif(size))

        case let .function(value):
            Text(value).font(serif(size))
                .padding(.trailing, size * 0.17)

        case let .symbol(value, spacing):
            symbol(value, spacing)

        case let .space(width):
            Color.clear.frame(width: size * CGFloat(width) / 18, height: 0)

        case let .group(children):
            mathRow(children, size)

        case let .fraction(numerator, denominator, rule):
            MathFractionLayout(size: size) {
                mathRow(numerator, size)
                mathRow(denominator, size)
                Rectangle()
                    .fill(.foreground)
                    .opacity(rule ? 1 : 0)
            }

        case let .root(index, radicand):
            root(index: index, radicand: radicand)

        case let .script(base, sub, sup, limits):
            MathScriptLayout(
                size: size,
                limits: limits,
                hasSup: !sup.isEmpty,
                hasSub: !sub.isEmpty
            ) {
                mathRow(base, size)
                if !sup.isEmpty {
                    mathRow(sup, scriptSize(size))
                }
                if !sub.isEmpty {
                    mathRow(sub, scriptSize(size))
                }
            }

        case let .fenced(opening, closing, inner):
            MathRowLayout {
                if !opening.isEmpty {
                    MathDelimiterView(glyph: opening, size: size).mathStretches()
                }
                mathRow(inner, size)
                if !closing.isEmpty {
                    MathDelimiterView(glyph: closing, size: size).mathStretches()
                }
            }

        case let .accent(kind, marked):
            accent(kind, marked)

        case let .matrix(columns, cells, opening, closing, alignment):
            MathRowLayout {
                if !opening.isEmpty {
                    MathDelimiterView(glyph: opening, size: size).mathStretches()
                }
                MathMatrixLayout(size: size, columns: columns, alignment: alignment) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        mathRow(cell, size)
                    }
                }
                if !closing.isEmpty {
                    MathDelimiterView(glyph: closing, size: size).mathStretches()
                }
            }
        }
    }

    @ViewBuilder
    private func symbol(_ value: String, _ spacing: MathSymbolClass) -> some View {
        switch spacing {
        case .binary:
            Text(value).font(serif(size)).padding(.horizontal, size * 0.22)
        case .relation:
            Text(value).font(serif(size)).padding(.horizontal, size * 0.28)
        case .punctuation:
            Text(value).font(serif(size)).padding(.trailing, size * 0.2)
        case .large:
            Text(value).font(serif(size * 1.45))
        case .ordinary, .opening, .closing:
            Text(value).font(serif(size))
        }
    }

    private func root(index: [MathNode], radicand: [MathNode]) -> some View {
        let signWidth = size * 0.75
        let radical = mathRow(radicand, size)
            .padding(.leading, signWidth)
            .padding(.top, size * 0.22)
            .padding(.trailing, size * 0.1)
            .background {
                RadicalShape(signWidth: signWidth)
                    .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.07), lineJoin: .round))
            }
        return HStack(alignment: .firstTextBaseline, spacing: -signWidth * 0.55) {
            if !index.isEmpty {
                mathRow(index, scriptSize(size))
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[.firstTextBaseline] + size * 0.6
                    }
            }
            radical
        }
    }

    private func accent(_ kind: MathAccentKind, _ marked: [MathNode]) -> some View {
        let content = mathRow(marked, size)
        let mark: String? = switch kind {
        case .hat: "ˆ"
        case .bar: "¯"
        case .vector: "→"
        case .dot: "˙"
        case .doubleDot: "¨"
        case .tilde: "˜"
        case .overline, .underline: nil
        }
        return content
            .padding(.top, kind == .underline ? 0 : size * 0.3)
            .padding(.bottom, kind == .underline ? size * 0.16 : 0)
            .overlay(alignment: kind == .underline ? .bottom : .top) {
                if let mark {
                    Text(mark)
                        .font(serif(kind == .vector ? size * 0.6 : size * 0.9))
                } else {
                    Rectangle()
                        .fill(.foreground)
                        .frame(height: max(1, size * 0.06))
                        .padding(.top, kind == .underline ? 0 : size * 0.2)
                }
            }
    }
}

// MARK: - Layout values

private struct MathStretchKey: LayoutValueKey {
    static let defaultValue = false
}

private extension View {
    /// Marks a subview that takes the height of its row instead of setting it.
    func mathStretches() -> some View {
        layoutValue(key: MathStretchKey.self, value: true)
    }
}

// MARK: - Layouts

/// Places its subviews left to right on a shared text baseline. Subviews marked
/// with `mathStretches()` (delimiters) span the full height of the others.
private struct MathRowLayout: Layout {
    private struct Metrics {
        var sizes: [CGSize] = []
        var baselines: [CGFloat] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    private func measure(_ subviews: Subviews) -> Metrics {
        var result = Metrics()
        for subview in subviews {
            let dimensions = subview.dimensions(in: .unspecified)
            let baseline = dimensions[VerticalAlignment.firstTextBaseline]
            result.sizes.append(CGSize(width: dimensions.width, height: dimensions.height))
            result.baselines.append(baseline)
            result.width += dimensions.width
            if !subview[MathStretchKey.self] {
                result.ascent = max(result.ascent, baseline)
                result.descent = max(result.descent, dimensions.height - baseline)
            }
        }
        return result
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let metrics = measure(subviews)
        return CGSize(width: metrics.width, height: metrics.ascent + metrics.descent)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let metrics = measure(subviews)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let size = metrics.sizes[index]
            if subview[MathStretchKey.self] {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(
                        width: size.width,
                        height: metrics.ascent + metrics.descent
                    )
                )
            } else {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY + metrics.ascent - metrics.baselines[index]),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
            }
            x += size.width
        }
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else {
            return nil
        }
        return bounds.minY + measure(subviews).ascent
    }
}

/// Numerator, denominator and rule (in that order), centered, with the
/// baseline a quarter em below the rule like the math axis of a font.
private struct MathFractionLayout: Layout {
    let size: CGFloat

    private var gap: CGFloat { size * 0.14 }
    private var axis: CGFloat { size * 0.26 }

    private struct Geometry {
        var numerator: ViewDimensions
        var denominator: ViewDimensions
        var width: CGFloat
        var thickness: CGFloat
        var baseline: CGFloat
        var height: CGFloat
    }

    private func arrange(_ subviews: Subviews) -> Geometry? {
        guard subviews.count == 3 else {
            return nil
        }
        let numerator = subviews[0].dimensions(in: .unspecified)
        let denominator = subviews[1].dimensions(in: .unspecified)
        let thickness = max(1, size * 0.06)
        let width = max(numerator.width, denominator.width) + size * 0.2
        let ruleCenter = numerator.height + gap + thickness / 2
        return Geometry(
            numerator: numerator,
            denominator: denominator,
            width: width,
            thickness: thickness,
            baseline: ruleCenter + axis,
            height: numerator.height + gap + thickness + gap + denominator.height
        )
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let geometry = arrange(subviews) else {
            return .zero
        }
        return CGSize(width: geometry.width, height: geometry.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let geometry = arrange(subviews) else {
            return
        }
        subviews[0].place(
            at: CGPoint(
                x: bounds.minX + (geometry.width - geometry.numerator.width) / 2,
                y: bounds.minY
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: geometry.numerator.width,
                height: geometry.numerator.height
            )
        )
        let ruleY = bounds.minY + geometry.numerator.height + gap
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: ruleY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: geometry.width, height: geometry.thickness)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + (geometry.width - geometry.denominator.width) / 2,
                y: ruleY + geometry.thickness + gap
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: geometry.denominator.width,
                height: geometry.denominator.height
            )
        )
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline,
              let geometry = arrange(subviews)
        else {
            return nil
        }
        return bounds.minY + geometry.baseline
    }
}

/// A base followed by an optional superscript and subscript (in that order),
/// either beside it or, for limits, above and below it.
private struct MathScriptLayout: Layout {
    let size: CGFloat
    let limits: Bool
    let hasSup: Bool
    let hasSub: Bool

    private struct Geometry {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var baseline: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews) -> Geometry {
        guard !subviews.isEmpty else {
            return Geometry()
        }
        let base = subviews[0].dimensions(in: .unspecified)
        var next = 1
        var sup: ViewDimensions?
        var sub: ViewDimensions?
        if hasSup, next < subviews.count {
            sup = subviews[next].dimensions(in: .unspecified)
            next += 1
        }
        if hasSub, next < subviews.count {
            sub = subviews[next].dimensions(in: .unspecified)
        }
        let baseAscent = base.firstTextBaselineValue
        let baseDescent = base.height - baseAscent
        var result = Geometry()
        result.sizes = [CGSize(width: base.width, height: base.height)]
        if let sup {
            result.sizes.append(CGSize(width: sup.width, height: sup.height))
        }
        if let sub {
            result.sizes.append(CGSize(width: sub.width, height: sub.height))
        }

        if limits {
            let gap = size * 0.1
            let width = max(base.width, sup?.width ?? 0, sub?.width ?? 0)
            let top = sup.map { $0.height + gap } ?? 0
            result.origins.append(CGPoint(x: (width - base.width) / 2, y: top))
            if let sup {
                result.origins.append(CGPoint(x: (width - sup.width) / 2, y: 0))
            }
            if let sub {
                result.origins.append(
                    CGPoint(x: (width - sub.width) / 2, y: top + base.height + gap)
                )
            }
            result.width = width
            result.height = top + base.height + (sub.map { gap + $0.height } ?? 0)
            result.baseline = top + baseAscent
            return result
        }

        // Side scripts, measured from the base's baseline with y pointing down.
        let raise = max(size * 0.4, baseAscent - size * 0.75)
        var drop = max(size * 0.22, baseDescent - size * 0.2)
        let supTop: CGFloat? = sup.map { -(raise + $0.firstTextBaselineValue) }
        let supBottom: CGFloat? = supTop.flatMap { top in sup.map { top + $0.height } }
        if let sub, let supBottom {
            let subTop = drop - sub.firstTextBaselineValue
            let clearance = subTop - supBottom
            if clearance < size * 0.15 {
                drop += size * 0.15 - clearance
            }
        }
        let subTop: CGFloat? = sub.map { drop - $0.firstTextBaselineValue }
        let subBottom: CGFloat? = subTop.flatMap { top in sub.map { top + $0.height } }
        let top = min(-baseAscent, supTop ?? 0)
        let bottom = max(baseDescent, subBottom ?? 0)
        let scriptX = base.width + size * 0.03
        result.origins.append(CGPoint(x: 0, y: -baseAscent - top))
        if let supTop {
            result.origins.append(CGPoint(x: scriptX, y: supTop - top))
        }
        if let subTop {
            result.origins.append(CGPoint(x: scriptX, y: subTop - top))
        }
        result.width = scriptX + max(sup?.width ?? 0, sub?.width ?? 0)
        result.height = bottom - top
        result.baseline = -top
        return result
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let geometry = arrange(subviews)
        return CGSize(width: geometry.width, height: geometry.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let geometry = arrange(subviews)
        for (index, subview) in subviews.enumerated()
        where index < geometry.origins.count && index < geometry.sizes.count {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + geometry.origins[index].x,
                    y: bounds.minY + geometry.origins[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(geometry.sizes[index])
            )
        }
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else {
            return nil
        }
        return bounds.minY + arrange(subviews).baseline
    }
}

/// Cells in row-major order on a grid; the block is centered on the math axis.
private struct MathMatrixLayout: Layout {
    let size: CGFloat
    let columns: Int
    let alignment: MathMatrixAlignment

    private struct Geometry {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private var columnCount: Int { max(columns, 1) }

    private func gap(after column: Int) -> CGFloat {
        switch alignment {
        case .equations:
            column % 2 == 0 ? size * 0.1 : size * 1.6
        case .centered, .leading:
            size * 1.0
        }
    }

    private func arrange(_ subviews: Subviews) -> Geometry {
        let count = subviews.count
        guard count > 0 else {
            return Geometry()
        }
        let rows = (count + columnCount - 1) / columnCount
        var widths = [CGFloat](repeating: 0, count: columnCount)
        var ascents = [CGFloat](repeating: 0, count: rows)
        var descents = [CGFloat](repeating: 0, count: rows)
        var dimensions: [ViewDimensions] = []
        for (index, subview) in subviews.enumerated() {
            let cell = subview.dimensions(in: .unspecified)
            dimensions.append(cell)
            let row = index / columnCount
            let column = index % columnCount
            widths[column] = max(widths[column], cell.width)
            let baseline = cell.firstTextBaselineValue
            ascents[row] = max(ascents[row], baseline)
            descents[row] = max(descents[row], cell.height - baseline)
        }
        let rowGap = size * 0.35
        var columnX = [CGFloat](repeating: 0, count: columnCount)
        var x: CGFloat = 0
        for column in 0..<columnCount {
            columnX[column] = x
            x += widths[column] + (column < columnCount - 1 ? gap(after: column) : 0)
        }
        var rowY = [CGFloat](repeating: 0, count: rows)
        var y: CGFloat = 0
        for row in 0..<rows {
            rowY[row] = y
            y += ascents[row] + descents[row] + (row < rows - 1 ? rowGap : 0)
        }
        var result = Geometry(width: x, height: y)
        for (index, cell) in dimensions.enumerated() {
            let row = index / columnCount
            let column = index % columnCount
            let slack = widths[column] - cell.width
            let offset: CGFloat = switch alignment {
            case .centered: slack / 2
            case .leading: 0
            case .equations: column % 2 == 0 ? slack : 0
            }
            result.sizes.append(CGSize(width: cell.width, height: cell.height))
            result.origins.append(
                CGPoint(
                    x: columnX[column] + offset,
                    y: rowY[row] + ascents[row] - cell.firstTextBaselineValue
                )
            )
        }
        return result
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let geometry = arrange(subviews)
        return CGSize(width: geometry.width, height: geometry.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let geometry = arrange(subviews)
        for (index, subview) in subviews.enumerated() where index < geometry.origins.count {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + geometry.origins[index].x,
                    y: bounds.minY + geometry.origins[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(geometry.sizes[index])
            )
        }
    }

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else {
            return nil
        }
        return bounds.minY + arrange(subviews).height / 2 + size * 0.26
    }
}

private extension ViewDimensions {
    /// Distance from the view's top to its first text baseline.
    var firstTextBaselineValue: CGFloat {
        self[VerticalAlignment.firstTextBaseline]
    }
}

// MARK: - Shapes

/// A square-root sign and the bar over the radicand.
private struct RadicalShape: Shape {
    let signWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + signWidth * 0.2, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + signWidth * 0.5, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + signWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// A bracket-like delimiter that grows with the formula it surrounds.
private struct MathDelimiterView: View {
    let glyph: String
    let size: CGFloat

    private static let closing: Set<String> = [")", "]", "}", "⟩", "⌋", "⌉"]

    private var width: CGFloat? {
        switch glyph {
        case "(", ")": size * 0.38
        case "[", "]", "⌊", "⌋", "⌈", "⌉": size * 0.34
        case "{", "}": size * 0.5
        case "|": size * 0.2
        case "‖": size * 0.32
        case "⟨", "⟩": size * 0.4
        default: nil
        }
    }

    var body: some View {
        if let width {
            DelimiterShape(glyph: glyph, flipped: Self.closing.contains(glyph))
                .stroke(style: StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round, lineJoin: .round))
                .frame(width: width)
                .padding(.vertical, size * 0.04)
        } else {
            Text(glyph).font(.system(size: size, design: .serif))
        }
    }
}

private struct DelimiterShape: Shape {
    let glyph: String
    let flipped: Bool

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: flipped ? rect.maxX - (x - rect.minX) : x, y: y)
        }
        let inset = rect.width * 0.25
        var path = Path()
        switch glyph {
        case "(", ")":
            path.move(to: point(rect.maxX, rect.minY))
            path.addQuadCurve(
                to: point(rect.maxX, rect.maxY),
                control: point(rect.minX - rect.width, rect.midY)
            )
        case "[", "]":
            path.move(to: point(rect.maxX, rect.minY))
            path.addLine(to: point(rect.minX + inset, rect.minY))
            path.addLine(to: point(rect.minX + inset, rect.maxY))
            path.addLine(to: point(rect.maxX, rect.maxY))
        case "⌊", "⌋":
            path.move(to: point(rect.minX + inset, rect.minY))
            path.addLine(to: point(rect.minX + inset, rect.maxY))
            path.addLine(to: point(rect.maxX, rect.maxY))
        case "⌈", "⌉":
            path.move(to: point(rect.minX + inset, rect.maxY))
            path.addLine(to: point(rect.minX + inset, rect.minY))
            path.addLine(to: point(rect.maxX, rect.minY))
        case "{", "}":
            let rise = rect.height * 0.18
            path.move(to: point(rect.maxX, rect.minY))
            path.addQuadCurve(
                to: point(rect.midX, rect.minY + rise),
                control: point(rect.midX, rect.minY)
            )
            path.addLine(to: point(rect.midX, rect.midY - rise * 0.6))
            path.addQuadCurve(
                to: point(rect.minX, rect.midY),
                control: point(rect.midX, rect.midY)
            )
            path.addQuadCurve(
                to: point(rect.midX, rect.midY + rise * 0.6),
                control: point(rect.midX, rect.midY)
            )
            path.addLine(to: point(rect.midX, rect.maxY - rise))
            path.addQuadCurve(
                to: point(rect.maxX, rect.maxY),
                control: point(rect.midX, rect.maxY)
            )
        case "|":
            path.move(to: point(rect.midX, rect.minY))
            path.addLine(to: point(rect.midX, rect.maxY))
        case "‖":
            let left = rect.midX - rect.width * 0.22
            let right = rect.midX + rect.width * 0.22
            path.move(to: point(left, rect.minY))
            path.addLine(to: point(left, rect.maxY))
            path.move(to: point(right, rect.minY))
            path.addLine(to: point(right, rect.maxY))
        case "⟨", "⟩":
            path.move(to: point(rect.maxX, rect.minY))
            path.addLine(to: point(rect.minX + inset, rect.midY))
            path.addLine(to: point(rect.maxX, rect.maxY))
        default:
            break
        }
        return path
    }
}
