import SwiftUI

// MARK: - Submitted marker

/// What a "确定" / "提交" button turns into once the host accepted the answer: a quiet 48 pt outlined bar with a green
/// check, still easy to read (a disabled primary button would dim to 40 %).
struct SubmittedBar: View {
    var title = "已提交"

    var body: some View {
        Label(title, systemImage: "checkmark")
            .font(.system(.headline, weight: .semibold))
            .foregroundStyle(Color.success)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - choice_list

struct ChoiceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var card: Card

    @State private var sending = false
    @State private var successTick = 0
    @State private var failureTick = 0

    private var store: CardInteractionStore { .shared }

    var body: some View {
        let p = card.props
        let multi = p["multi"]?.bool ?? false
        let submitted = p["submitted"]?.bool == true || store.isSubmitted(card)
        let selected = store.selection(card)
        let options = p["options"]?.items ?? []
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    CardHeader(p["question"]?.string ?? "", symbol: "questionmark.bubble")
                    Text(multi ? "多选 · 选好后点「确定」提交" : "单选 · 点选后立即回复")
                        .font(.orbitMeta)
                        .foregroundStyle(Color.inkSecondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { HairlineRule() }
                        row(option, multi: multi, selected: selected, submitted: submitted)
                    }
                }
                if multi {
                    if submitted {
                        SubmittedBar()
                    } else {
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack(spacing: 6) {
                                if sending { ProgressView().controlSize(.small).tint(Color.onPrimary) }
                                Text("确定")
                            }
                        }
                        .buttonStyle(.orbit(.primary))
                        .disabled(selected.isEmpty || sending)
                    }
                } else if submitted {
                    Label("已提交", systemImage: "checkmark.circle.fill")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.success)
                        .transition(.opacity)
                }
            }
            .cardInsets()
        }
        .animation(MotionAware(reduce: reduceMotion).snappy, value: submitted)
        .sensoryFeedback(.selection, trigger: selected)
        .submitFeedback(success: successTick, failure: failureTick)
    }

    /// One option: a leading marker (hollow when open, a filled check when picked), the label and an optional detail.
    /// Rows are divided by hairlines; the picked one is bold. No tinted block, no outline.
    private func row(_ option: JSONValue, multi: Bool, selected: Set<String>, submitted: Bool) -> some View {
        let id = option["id"]?.string ?? ""
        let isOn = selected.contains(id)
        let symbol = multi ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "checkmark.circle.fill" : "circle")
        return Button {
            tap(id, multi: multi)
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Color.primaryFill : Color.inkSecondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option["label"]?.string ?? "")
                        .font(.orbitBody.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(Color.ink)
                    if let detail = option["detail"]?.string, !detail.isEmpty {
                        Text(detail).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        // Once answered, the options that were not picked step back (only when we know what was picked).
        .opacity(submitted && !selected.isEmpty && !isOn ? 0.55 : 1)
        .disabled(submitted || sending)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(multi ? "多选" : "单选")
    }

    private func tap(_ id: String, multi: Bool) {
        var ids = store.selection(card)
        if multi {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        } else {
            ids = [id]
        }
        withAnimation(MotionAware(reduce: reduceMotion).snappy) { store.setSelection(ids, for: card) }
        if !multi { Task { await submit() } }
    }

    private func submit() async {
        let ids = store.selection(card)
        guard !ids.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let accepted = await model.sendAction(cardId: card.id, actionId: "select", value: .array(ids.sorted().map(JSONValue.string)))
        if accepted {
            store.markSubmitted(card)
            successTick += 1
        } else {
            failureTick += 1
        }
    }
}

// MARK: - form

struct FormCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var card: Card

    @State private var sending = false
    @State private var successTick = 0
    @State private var failureTick = 0

    private var store: CardInteractionStore { .shared }

    var body: some View {
        let p = card.props
        let fields = p["fields"]?.items ?? []
        let submitted = p["submitted"]?.bool == true || store.isSubmitted(card)
        let values = currentValues(fields)
        let problem = firstProblem(fields, values)
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: Space.l) {
                if let title = p["title"]?.string, !title.isEmpty {
                    CardHeader(title, symbol: "square.and.pencil")
                }
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 { HairlineRule() }
                        fieldRow(field, values: values)
                    }
                }
                .disabled(submitted)

                VStack(alignment: .leading, spacing: Space.s) {
                    if submitted {
                        SubmittedBar()
                    } else {
                        Button {
                            Task { await submit(fields) }
                        } label: {
                            HStack(spacing: 6) {
                                if sending { ProgressView().controlSize(.small).tint(Color.onPrimary) }
                                Text(p["submitLabel"]?.string ?? "提交")
                            }
                        }
                        .buttonStyle(.orbit(.primary))
                        .disabled(problem != nil || sending)
                        if let problem {
                            Text(problem).font(.orbitMeta).foregroundStyle(Color.warning)
                        }
                    }
                }
            }
            .cardInsets()
        }
        .submitFeedback(success: successTick, failure: failureTick)
    }

    // MARK: Values

    /// What the form holds right now: the user's typing, or the fields' own initial values before anything was typed.
    private func currentValues(_ fields: [JSONValue]) -> [String: JSONValue] {
        store.values(of: card) ?? Self.initialValues(fields)
    }

    /// Numbers are held as the text being typed ("1." must stay "1." while the next digit comes) and turned into
    /// numbers when sending.
    private static func initialValues(_ fields: [JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for f in fields {
            guard let key = f["key"]?.string else { continue }
            let type = f["type"]?.string ?? "text"
            if let v = f["value"], !v.isNull {
                out[key] = type == "number" ? .string(v.displayString) : v
            } else if type == "toggle" {
                out[key] = false
            }
        }
        return out
    }

    private func set(_ key: String, _ value: JSONValue?, fields: [JSONValue]) {
        var values = store.values(of: card) ?? Self.initialValues(fields)
        values[key] = value
        store.setValues(values, for: card)
    }

    // MARK: Validation

    private func isMissing(_ field: JSONValue, _ values: [String: JSONValue]) -> Bool {
        guard field["required"]?.bool == true, let key = field["key"]?.string else { return false }
        guard let v = values[key], !v.isNull else { return true }
        return v.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
    }

    private func isMalformedNumber(_ field: JSONValue, _ values: [String: JSONValue]) -> Bool {
        guard field["type"]?.string == "number", let key = field["key"]?.string,
              let text = values[key]?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return false }
        return Double(text) == nil
    }

    /// Why the submit button is off: a required field is empty, or a number is not a number.
    private func firstProblem(_ fields: [JSONValue], _ values: [String: JSONValue]) -> String? {
        let missing = fields.filter { isMissing($0, values) }.compactMap { $0["label"]?.string ?? $0["key"]?.string }
        if !missing.isEmpty { return "请先填写：" + missing.joined(separator: "、") }
        if let bad = fields.first(where: { isMalformedNumber($0, values) }) {
            return "「\(bad["label"]?.string ?? bad["key"]?.string ?? "")」需要填数字"
        }
        return nil
    }

    private func submit(_ fields: [JSONValue]) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        var payload: [String: JSONValue] = [:]
        for (key, value) in currentValues(fields) {
            let isNumber = fields.first { $0["key"]?.string == key }?["type"]?.string == "number"
            if isNumber {
                let text = value.string?.trimmingCharacters(in: .whitespaces) ?? ""
                payload[key] = text.isEmpty ? .null : (Double(text).map(JSONValue.number) ?? .string(text))
            } else {
                payload[key] = value
            }
        }
        let accepted = await model.sendAction(cardId: card.id, actionId: "submit", value: .object(payload))
        if accepted {
            store.markSubmitted(card)
            successTick += 1
        } else {
            failureTick += 1
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func fieldRow(_ f: JSONValue, values: [String: JSONValue]) -> some View {
        let fields = card.props["fields"]?.items ?? []
        let key = f["key"]?.string ?? ""
        let label = f["label"]?.string ?? key
        let placeholder = f["placeholder"]?.string ?? ""
        let missing = isMissing(f, values)
        let required = f["required"]?.bool == true
        switch f["type"]?.string ?? "text" {
        case "number":
            stacked(label, required: required, missing: missing) {
                TextField(placeholder, text: textBinding(key, fields))
            }
        case "date":
            inline(label, required: required, missing: missing) {
                dateControl(key, fields: fields, values: values, components: .date, format: "yyyy-MM-dd", prompt: "选择日期")
            }
        case "time":
            inline(label, required: required, missing: missing) {
                dateControl(key, fields: fields, values: values, components: .hourAndMinute, format: "HH:mm", prompt: "选择时间")
            }
        case "select":
            inline(label, required: required, missing: missing) {
                selectControl(f, key: key, fields: fields, values: values)
            }
        case "toggle":
            inline(label, required: required, missing: missing) {
                Toggle(label, isOn: Binding {
                    currentValues(fields)[key]?.bool ?? false
                } set: {
                    set(key, .bool($0), fields: fields)
                })
                .labelsHidden()
                .tint(Color.accentText)
            }
        default:
            stacked(label, required: required, missing: missing) {
                TextField(placeholder, text: textBinding(key, fields), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    private func labelView(_ label: String, required: Bool, missing: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.orbitSecondary).foregroundStyle(Color.inkSecondary)
            if required {
                Text("必填")
                    .font(.orbitMeta)
                    .foregroundStyle(missing ? Color.warning : Color.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Label above, a text-like control below (text and number fields).
    private func stacked(_ label: String, required: Bool, missing: Bool, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labelView(label, required: required, missing: missing)
            control()
                .font(.orbitBody)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    /// Label on the left, the control on the right (toggle, date, time, select). Stacks at accessibility text sizes.
    @ViewBuilder
    private func inline(_ label: String, required: Bool, missing: Bool, @ViewBuilder control: () -> some View) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.s) {
                labelView(label, required: required, missing: missing)
                control()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: Space.m) {
                labelView(label, required: required, missing: missing)
                Spacer(minLength: Space.s)
                control()
            }
            .frame(minHeight: 44)
        }
    }

    private func textBinding(_ key: String, _ fields: [JSONValue]) -> Binding<String> {
        Binding {
            currentValues(fields)[key]?.displayString ?? ""
        } set: {
            set(key, .string($0), fields: fields)
        }
    }

    // MARK: Date, time

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    /// An unset date or time shows "选择…"; picking it sets today / now, then the real picker takes over.
    @ViewBuilder
    private func dateControl(_ key: String, fields: [JSONValue], values: [String: JSONValue],
                             components: DatePickerComponents, format: String, prompt: String) -> some View {
        let formatter = Self.formatter(format)
        if let text = values[key]?.string, let date = formatter.date(from: text) {
            DatePicker(prompt, selection: Binding {
                date
            } set: {
                set(key, .string(formatter.string(from: $0)), fields: fields)
            }, displayedComponents: components)
            .labelsHidden()
            .environment(\.locale, CardFormat.locale)
        } else {
            Button(prompt) {
                set(key, .string(formatter.string(from: Date())), fields: fields)
            }
            .buttonStyle(.orbit(.plain, size: .mini))
        }
    }

    // MARK: Select

    /// Options are plain strings, or `{value | id, label}` objects.
    private func selectOptions(_ f: JSONValue) -> [(value: String, label: String)] {
        (f["options"]?.items ?? []).map { o in
            let value = o.string ?? o["value"]?.string ?? o["id"]?.string ?? o.displayString
            let label = o.string ?? o["label"]?.string ?? value
            return (value, label)
        }
    }

    private func selectControl(_ f: JSONValue, key: String, fields: [JSONValue], values: [String: JSONValue]) -> some View {
        let options = selectOptions(f)
        let current = values[key]?.string ?? ""
        let shown = options.first { $0.value == current }?.label
        return Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    set(key, .string(option.value), fields: fields)
                } label: {
                    if option.value == current {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shown ?? "请选择")
                    .font(.orbitBody)
                    .foregroundStyle(shown == nil ? Color.inkSecondary : Color.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
    }
}

// MARK: - comparison

/// Options on rows, like a price list: name (the recommended one in semibold with an Accent "推荐"), a line of facts
/// under it, the price on the right in tabular digits, and "选这家" under the price. Rows are divided by hairlines;
/// under the last one a hairline and a line of key points. No tinted block, no thumbnail placeholder.
/// "选这家" sends `ui.action { actionId: "select", value: [itemId] }`; afterwards the card remembers the choice, shows
/// "已选择" on it and drops the other buttons. No chat bubble is invented for the choice.
struct ComparisonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var card: Card

    @State private var sendingId: String?
    @State private var successTick = 0
    @State private var failureTick = 0

    private var store: CardInteractionStore { .shared }

    var body: some View {
        let p = card.props
        let items = p["items"]?.items ?? []
        let recommendedId = p["recommendedId"]?.string
        let chosen = store.selection(card)
        let answered = p["submitted"]?.bool == true || store.isSubmitted(card)
        let points = Self.keyPoints(items, recommendedId: recommendedId)
        CardShell(card: card) {
            VStack(alignment: .leading, spacing: 0) {
                if let title = p["title"]?.string, !title.isEmpty {
                    Text(title)
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Color.inkSecondary)
                        .padding(.bottom, Space.s)
                        .accessibilityAddTraits(.isHeader)
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let id = item["id"]?.string ?? ""
                        if index > 0 { HairlineRule() }
                        ComparisonRow(item: item,
                                      recommended: id == recommendedId,
                                      state: rowState(id: id, chosen: chosen, answered: answered),
                                      sending: sendingId == id,
                                      locked: sendingId != nil) {
                            Task { await select(id) }
                        }
                        .padding(.top, index == 0 ? 0 : 10)
                        .padding(.bottom, index == items.count - 1 ? 0 : 10)
                    }
                }
                if !points.isEmpty {
                    HairlineRule().padding(.top, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(points.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.orbitMeta)
                                .foregroundStyle(Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Answered, but this phone does not know which one (the choice was made elsewhere or before a relaunch).
                if answered, chosen.isEmpty {
                    HairlineRule().padding(.top, 10)
                    StatusChip(kind: .ok, text: "已选择").padding(.top, 10)
                }
            }
            .cardInsets()
        }
        .animation(MotionAware(reduce: reduceMotion).spring, value: answered)
        .submitFeedback(success: successTick, failure: failureTick)
    }

    private func rowState(id: String, chosen: Set<String>, answered: Bool) -> ComparisonRow.Choice {
        guard answered || !chosen.isEmpty else { return .open }
        if chosen.isEmpty { return .closed }
        return chosen.contains(id) ? .chosen : .passed
    }

    /// The key points under the rows, one line per option that has any: "璞丽酒店：最划算，安静，离客户近；不足：无江景".
    /// The recommended option comes first, the others keep their order.
    static func keyPoints(_ items: [JSONValue], recommendedId: String?) -> [String] {
        func texts(_ value: JSONValue?) -> [String] {
            (value?.items ?? []).map(\.displayString).filter { !$0.isEmpty }
        }
        var first: [String] = []
        var rest: [String] = []
        for item in items {
            let title = item["title"]?.string ?? ""
            var good: [String] = []
            if let highlight = item["highlight"]?.string, !highlight.isEmpty { good.append(highlight) }
            good += texts(item["pros"])
            let bad = texts(item["cons"])
            var body = good.joined(separator: "，")
            if !bad.isEmpty { body += (body.isEmpty ? "" : "；") + "不足：" + bad.joined(separator: "、") }
            guard !body.isEmpty else { continue }
            let line = title.isEmpty ? body : "\(title)：\(body)"
            if let recommendedId, item["id"]?.string == recommendedId { first.append(line) } else { rest.append(line) }
        }
        return first + rest
    }

    private func select(_ id: String) async {
        guard sendingId == nil, !id.isEmpty else { return }
        sendingId = id
        defer { sendingId = nil }
        let accepted = await model.sendAction(cardId: card.id, actionId: "select", value: .array([.string(id)]))
        if accepted {
            withAnimation(MotionAware(reduce: reduceMotion).spring) {
                store.setSelection([id], for: card)
                store.markSubmitted(card)
            }
            successTick += 1
        } else {
            failureTick += 1
        }
    }
}

private struct ComparisonRow: View {
    /// Where the row is in the choice: still open, picked by the user, passed over, or answered without us knowing which.
    enum Choice { case open, chosen, passed, closed }

    var item: JSONValue
    var recommended: Bool
    var state: Choice
    var sending: Bool
    var locked: Bool
    var onSelect: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            HStack(alignment: .top, spacing: 12) {
                thumb
                info
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .opacity(state == .passed ? 0.6 : 1)
    }

    // MARK: Pieces

    /// The picture of the option, when it has one. Without one there is nothing in its place.
    @ViewBuilder
    private var thumb: some View {
        if let image = item["imageUrl"]?.pictureString {
            CardImage(source: image, ratio: 1)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: Radius.small, style: .continuous))
        }
    }

    /// Name (+ "推荐") and, under it, the facts line.
    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item["title"]?.string ?? "")
                    .font(.orbitBody.weight(recommended || state == .chosen ? .semibold : .regular))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if recommended {
                    Text("推荐")
                        .font(.orbitChip)
                        .foregroundStyle(Color.accentText)
                }
            }
            if let facts = facts, !facts.isEmpty {
                Text(facts)
                    .font(.orbitMeta)
                    .monospacedDigit()
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "静安 · 4.8 分": the subtitle, plus the option's own highlight when it is not the recommended one (the recommended
    /// one's highlight goes into the key points under the rows).
    private var facts: String? {
        var parts: [String] = []
        if let subtitle = item["subtitle"]?.string, !subtitle.isEmpty { parts.append(subtitle) }
        if !recommended, let highlight = item["highlight"]?.string, !highlight.isEmpty { parts.append(highlight) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Price on the right (tabular digits) and the choice control under it.
    private var trailing: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            if let price = item["price"]?.displayString, !price.isEmpty {
                priceText(price)
                    .foregroundStyle(Color.ink)
                    .accessibilityLabel(price)
            }
            control
        }
    }

    /// "¥880/晚": the amount in 17 pt, the unit after the slash in 13 pt InkSecondary.
    private func priceText(_ price: String) -> Text {
        guard let slash = price.firstIndex(of: "/") else {
            return Text(verbatim: price).font(.orbitBody).monospacedDigit()
        }
        let amount = Text(verbatim: String(price[..<slash])).font(.orbitBody).monospacedDigit()
        let unit = Text(verbatim: String(price[slash...])).font(.orbitMeta).foregroundStyle(Color.inkSecondary)
        return Text("\(amount)\(unit)")
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .open:
            Button(action: onSelect) {
                Text("选这家")
                    .opacity(sending ? 0 : 1)
                    .overlay { if sending { ProgressView().controlSize(.small) } }
            }
            .buttonStyle(.orbit(.plain, size: .mini))
            .disabled(locked)
            .accessibilityLabel("选这家：\(item["title"]?.string ?? "")")
        case .chosen:
            StatusChip(kind: .ok, text: "已选择")
        case .passed, .closed:
            EmptyView()
        }
    }
}

// MARK: - memory_saved

/// A one-line hint: "已记住：…" with a "撤销" text button (`ui.action { actionId: "undo" }`), no icon block. The host
/// patches `undone` when it took effect: the line then reads "已撤销：…" with the memory struck through and no button.
struct MemorySavedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var card: Card

    @State private var sending = false
    @State private var successTick = 0
    @State private var failureTick = 0

    var body: some View {
        let undone = card.props["undone"]?.bool ?? false
        let memory = card.props["text"]?.string ?? ""
        let label = undone
            ? Text("\(Text(verbatim: "已撤销："))\(Text(verbatim: memory).strikethrough(true, color: Color.inkSecondary))")
            : Text(verbatim: "已记住：" + memory)
        HintRow(label) {
            if !undone {
                Button {
                    Task { await undo() }
                } label: {
                    Text("撤销")
                        .opacity(sending ? 0 : 1)
                        .overlay { if sending { ProgressView().controlSize(.small) } }
                }
                .buttonStyle(.orbit(.plain, size: .mini))
                .disabled(sending)
                .transition(.opacity)
            }
        }
        .animation(MotionAware(reduce: reduceMotion).snappy, value: undone)
        .submitFeedback(success: successTick, failure: failureTick)
    }

    private func undo() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        if await model.sendAction(cardId: card.id, actionId: "undo") {
            successTick += 1
        } else {
            failureTick += 1
        }
    }
}
